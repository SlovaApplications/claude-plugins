#!/usr/bin/env node
// SessionStart hook: inject this repo's "where you left off" memory at the start
// of a session, and stand up the capture instruction so the agent keeps that
// memory current.
//
// The rolling session-summary is scoped PER SESSION × repo, not per repo. Each
// session owns its own rolling doc (keyed by the Claude Code session_id); a new
// session does NOT supersede a previous session's summary — it reads it for
// continuity and writes its own. See context-memory docs/DATA_MODEL.md.
//
// Posture: unlike prefetch.mjs, this hook FAILS OPEN on everything — including a
// missing API key. Blocking or erroring at session start is bad UX, and the
// missing-key case is already surfaced loudly by prefetch on the first prompt.
// Any problem → emit nothing, exit 0.

import { execFileSync } from 'node:child_process';
import { basename } from 'node:path';
import {
  API_KEY,
  apiUrlIsSafe,
  apiRequest,
  is2xx,
  readStdin,
  parseJson,
  envNum,
  clipBytes,
  emit
} from './lib.mjs';

const TIMEOUT = envNum('CONTEXT_MEMORY_RECALL_TIMEOUT', 2);
const ORIENTATION_LIMIT = envNum('CONTEXT_MEMORY_ORIENTATION_LIMIT', 25);
const MAX_OUTPUT_BYTES = envNum('CONTEXT_MEMORY_RECALL_MAX_BYTES', 4000);

let gitMissing = false;
function git(cwd, args) {
  try {
    return execFileSync('git', ['-C', cwd, ...args], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();
  } catch (e) {
    if (e && e.code === 'ENOENT') gitMissing = true; // git not installed
    return '';
  }
}

try {
  const input = parseJson(await readStdin());

  if (!API_KEY) process.exit(0);
  if (!apiUrlIsSafe()) process.exit(0); // same cleartext-key guard, fail open

  const cwd = input?.cwd || process.cwd();

  // The Claude Code session id scopes the rolling summary to this session.
  // Empty is tolerated (older clients): we fall back to repo-only behavior.
  const sessionId = input?.session_id || '';

  // Canonical repo id = owner/repo from the origin remote (stable across
  // https/ssh forms). Fallback: working-tree basename. MUST match what the
  // capture instruction tells the agent to write, or the term-filter misses.
  const remote = git(cwd, ['remote', 'get-url', 'origin']);
  if (gitMissing) process.exit(0);
  let repo = '';
  if (remote) {
    repo = remote
      .replace(/^git@[^:]+:/, '')
      .replace(/^[a-z]+:\/\/[^/]+\//, '')
      .replace(/\.git$/, '');
  } else {
    const top = git(cwd, ['rev-parse', '--show-toplevel']);
    if (gitMissing) process.exit(0);
    if (top) repo = basename(top);
  }
  if (!repo) process.exit(0); // no repo → nothing to scope recall/capture to

  // GET /api/v1/contexts?git_repo&tag&limit[&session_id], recency-ordered.
  // Returns the parsed body on success, null on any transport/non-2xx failure.
  async function fetchContexts(tag, limit, sid) {
    const query = { git_repo: repo, tag, limit };
    if (sid) query.session_id = sid;
    const res = await apiRequest('/api/v1/contexts', { query, timeoutSec: TIMEOUT });
    if (!res || !is2xx(res.status)) return null;
    return res.json;
  }

  // Fetch the three recall sources concurrently. They're independent, and run
  // sequentially they could spend up to 3×TIMEOUT — over the SessionStart hook's
  // budget on a cold backend, killing recall when it's most needed.
  //   - own: this session's own rolling summary (resume case), if any
  //   - latest: the most recent summary for this repo across all sessions
  //     ("where you left off" on a fresh session)
  //   - orientation: durable project facts
  const [own, latest, orientation] = await Promise.all([
    sessionId ? fetchContexts('session-summary', 1, sessionId) : Promise.resolve(null),
    fetchContexts('session-summary', 1),
    fetchContexts('orientation', ORIENTATION_LIMIT)
  ]);
  const ownId = own?.items?.[0]?.id || '';
  const ownBody = own?.items?.[0]?.body || '';
  const latestBody = latest?.items?.[0]?.body || '';
  const latestId = latest?.items?.[0]?.id || '';
  const orientationItems = Array.isArray(orientation?.items) ? orientation.items : [];
  const orientationBodies = orientationItems
    .map((i) => '- ' + String(i?.body || '').replace(/\n/g, ' '))
    .join('\n');

  // Build the surfaced memory (byte-capped); the capture instruction is
  // appended unconditionally outside the cap so a long summary can never
  // truncate away the thing that keeps memory flowing.
  let surface = `[context-memory · session recall for ${repo}]\n\n`;
  if (ownId) {
    surface += `## Resuming this session\n${ownBody}\n\n`;
  } else if (latestBody) {
    surface += `## Where you left off (previous session)\n${latestBody}\n\n`;
  } else {
    surface += `## Where you left off\nNo prior session recorded for this repo yet.\n\n`;
  }
  if (orientationBodies) {
    surface += `## Project facts\n${orientationBodies}\n`;
  }
  // The bash original built SURFACE in a command substitution, which strips
  // trailing newlines; replicate that so the spacing before the instruction
  // block matches exactly.
  surface = clipBytes(surface, MAX_OUTPUT_BYTES).replace(/\n+$/, '');

  // The rolling-summary instruction depends on the session's state.
  let rollingLine;
  if (ownId) {
    rollingLine = `• ROLLING SESSION STATE — you are resuming this session (${sessionId}). Keep its summary current by superseding it after each substantive turn (don't start a new one):
  supersede_context(context_id="${ownId}", body="<where things stand>\\n\\n## Open items\\n- …", tags=["session-summary"], git_repo="${repo}")
  Use the new id it returns for the next update this session (session_id carries over automatically).`;
  } else if (sessionId) {
    rollingLine = `• ROLLING SESSION STATE — the summary above (if any) is the PREVIOUS session's, for context only; do NOT supersede it. Start THIS session's own rolling summary, scoped to this session, then keep it current by superseding it after each substantive turn:
  save_context(body="<where things stand>\\n\\n## Open items\\n- …", tags=["session-summary"], git_repo="${repo}", session_id="${sessionId}")
  Then supersede the id it returns after each update (session_id carries over automatically).`;
  } else if (latestId) {
    rollingLine = `• ROLLING SESSION STATE — keep one summary current so an interrupted session resumes. After each substantive turn, SUPERSEDE it (don't append a new one):
  supersede_context(context_id="${latestId}", body="<where things stand>\\n\\n## Open items\\n- …", tags=["session-summary"], git_repo="${repo}")
  Use the new id it returns for the next update this session.`;
  } else {
    rollingLine = `• ROLLING SESSION STATE — no rolling summary exists yet. Create one now, then keep it current by superseding it after each substantive turn:
  save_context(body="<where things stand>\\n\\n## Open items\\n- …", tags=["session-summary"], git_repo="${repo}")`;
  }

  const instruction = `

---
[context-memory — keep this repo's memory current (git_repo="${repo}"):
${rollingLine}
• When the user states a durable project fact (how it's wired, where things live), capture it once:
  save_context(body="<the fact>", tags=["orientation"], git_repo="${repo}")
Pass git_repo="${repo}" exactly as written so recall and capture stay aligned.]`;

  const additionalContext = surface + instruction;

  emit({
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext
    }
  });
} catch {
  // fail open
}
process.exit(0);
