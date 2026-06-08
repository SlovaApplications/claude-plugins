#!/usr/bin/env node
// UserPromptSubmit hook: search context-memory for prior contexts relevant to
// the user's prompt and inject the top hits as additional context for Claude.
//
// Hard-fails (exit 2) if CONTEXT_MEMORY_API_KEY is unset — the plugin can't do
// anything useful without it, and a silent no-op hides the misconfiguration.
// All other failures (network error, malformed response) still fail open: the
// script prints nothing and exits 0 so the prompt passes through.

import { execFileSync } from 'node:child_process';
import {
  API_KEY,
  API_URL,
  apiUrlIsSafe,
  apiRequest,
  is2xx,
  readStdin,
  parseJson,
  envNum,
  clipBytes,
  clipChars
} from './lib.mjs';

// Canonical repo id = owner/repo from the origin remote (stable across
// https/ssh forms) — the same derivation session-recall.mjs uses, so the
// `git_repo` we boost on matches what capture writes. Best-effort: any
// failure (no git, no remote, detached dir) yields '' and locality simply
// isn't applied. Never throws — prefetch must stay fail-open.
function originRepo(cwd) {
  try {
    const remote = execFileSync('git', ['-C', cwd, 'remote', 'get-url', 'origin'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();
    if (!remote) return '';
    return remote
      .replace(/^git@[^:]+:/, '')
      .replace(/^[a-z]+:\/\/[^/]+\//, '')
      .replace(/\.git$/, '');
  } catch {
    return '';
  }
}

const TIMEOUT = envNum('CONTEXT_MEMORY_PREFETCH_TIMEOUT', 1.5);
// Backend SearchRequest caps limit at 20 (422 otherwise, which would fail the
// hook open and silently disable prefetch for every prompt). Clamp here.
const LIMIT = Math.min(20, envNum('CONTEXT_MEMORY_PREFETCH_LIMIT', 5));
const MAX_OUTPUT_BYTES = envNum('CONTEXT_MEMORY_PREFETCH_MAX_BYTES', 2000);

if (!API_KEY) {
  process.stderr.write(`context-memory: CONTEXT_MEMORY_API_KEY is not set.

Fix this by either:

  1. Setting an API key (get one at https://context-memory.slova.app).

     macOS / Linux (bash, zsh):

       export CONTEXT_MEMORY_API_KEY=cm_...

     Add the line to ~/.zshrc or ~/.bashrc to persist across sessions.

     Windows (PowerShell), persistent for the current user:

       [Environment]::SetEnvironmentVariable("CONTEXT_MEMORY_API_KEY", "cm_...", "User")

     Or session-only:

       $env:CONTEXT_MEMORY_API_KEY = "cm_..."

     Windows (cmd.exe), persistent — takes effect in NEW shells only:

       setx CONTEXT_MEMORY_API_KEY cm_...

  2. Disabling the plugin:

       /plugin                                   (interactive)
       claude plugin remove context-memory@slova (one-shot)
`);
  process.exit(2);
}

// Refuse to send the API key over a cleartext connection. Anything that isn't
// https or a local backend is a misconfiguration that would leak the key —
// surface it loudly (same posture as a missing key), don't no-op.
if (!apiUrlIsSafe()) {
  process.stderr.write(`context-memory: refusing to send your API key to a non-HTTPS URL.

CONTEXT_MEMORY_API_URL is set to:
  ${API_URL}

Over a non-TLS connection the API key travels in cleartext. Use an
https:// URL, or point at a local backend (http://localhost or
http://127.0.0.1) for development.
`);
  process.exit(2);
}

try {
  const input = parseJson(await readStdin());
  const prompt = input?.prompt || '';
  if (!prompt) process.exit(0);

  // Cap query length so we don't ship a 10KB prompt as a search query.
  const query = clipBytes(prompt, 500);

  // Locality hints: the session's cwd (project) and origin repo. The backend
  // treats these as a soft boost, not a filter, so the current project's
  // context ranks above cross-project hits without dropping cross-cutting
  // ones. cwd matches what capture writes as `project`. Older backends ignore
  // unknown body fields, so sending these is safe even pre-upgrade.
  const cwd = input?.cwd || process.cwd();
  const gitRepo = originRepo(cwd);
  const searchBody = { query, limit: LIMIT, project: cwd };
  if (gitRepo) searchBody.git_repo = gitRepo;

  const res = await apiRequest('/api/v1/contexts/search', {
    method: 'POST',
    body: searchBody,
    timeoutSec: TIMEOUT
  });
  if (!res) process.exit(0);

  // 401/403 = the key is set but the server rejected it. Surface loudly (it's
  // almost always a persistent misconfiguration). Other non-2xx (5xx, 429) are
  // likely transient and fall through to fail-open.
  if (res.status === 401 || res.status === 403) {
    process.stderr.write(`context-memory: authentication failed (HTTP ${res.status}).

Your CONTEXT_MEMORY_API_KEY is set but the server rejected it. The key
is most likely expired, revoked, or malformed.

Fix this by either:

  1. Issuing a new API key at https://context-memory.slova.app and
     replacing the value in your shell config (see the missing-key
     error message for per-OS instructions).

  2. Disabling the plugin:

       /plugin                                   (interactive)
       claude plugin remove context-memory@slova (one-shot)
`);
    process.exit(2);
  }

  if (!is2xx(res.status)) process.exit(0);

  const results = Array.isArray(res.json) ? res.json : null;
  if (!results || results.length === 0) process.exit(0);

  const count = results.length;
  const topics = results.filter((r) => r?.type === 'topic');
  const contexts = results.filter((r) => r?.type !== 'topic');

  // Derived load-bearing tier (#68): "proven"/"established" render as
  // "[Context · proven]"; the bottom tier is null/absent and renders nothing,
  // so new-but-relevant content reads as neutral. Tolerates a missing field.
  const tiermark = (item) => {
    const tier = item?.load_bearing_tier || '';
    return tier !== '' ? ' · ' + tier : '';
  };

  const renderItem = (item) => {
    let block;
    if (item?.type === 'topic') {
      block =
        '### [Topic' + tiermark(item) + '] ' + clipChars(item.title || '(untitled topic)', 120) +
        '\n' + clipChars(item.overview || '', 280);
    } else {
      const lines = String(item?.body || '').split('\n');
      const head = (lines[0] || '').replace(/^#+\s*/, '');
      const title = /\S/.test(head) ? clipChars(head, 120) : '(untitled context)';
      block =
        '### [Context' + tiermark(item) + '] ' + title +
        '\n' + clipChars(lines.slice(1).join('\n'), 280);
    }
    const tags = Array.isArray(item?.tags) ? item.tags : [];
    if (tags.length > 0) block += '\ntags: ' + tags.join(', ');
    return block + '\n';
  };

  // Topics first (compiled understanding), then Contexts (the supporting
  // source notes); relevance order preserved within each group.
  // jq -r in the original prints a newline after each streamed item, on top of
  // each block's own trailing "\n" — so items are separated by a blank line.
  const body =
    `[context-memory: ${count} relevant result(s) from prior sessions]\n\n` +
    [...topics, ...contexts].map((r) => renderItem(r) + '\n').join('');

  process.stdout.write(clipBytes(body, MAX_OUTPUT_BYTES));

  // Usage guidance — printed OUTSIDE the byte cap so a long result list can
  // never truncate away the instructions, and unconditional on any result.
  process.stdout.write(
    '\n[context-memory — how to use the results above: if a Topic covers your task, prefer it and drill into its source Contexts (get_context) for detail; if nothing here matches, do the work, then save_context what you learned. Do not proceed as if no prior knowledge exists.]\n'
  );

  // Synthesis nudge: several Contexts, no Topic tying them together.
  if (contexts.length >= 2 && topics.length === 0) {
    process.stdout.write(
      `\n[context-memory: ${contexts.length} related Contexts surfaced and no Topic synthesizes them. If they cohere around one subject, consider calling create_topic to compile them into a durable synthesis.]\n`
    );
  }
} catch {
  // fail open
}
process.exit(0);
