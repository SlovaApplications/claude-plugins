#!/usr/bin/env node
// Deterministic extraction for the /bootstrap-memory command.
//
// Node, not bash/jq, so it runs identically on macOS/Linux/Windows (Claude Code
// always has `node` on PATH). Turns Claude Code session transcripts
// (~/.claude/projects/<encoded-cwd>/<id>.jsonl) into compact, signal-only
// digests that Claude then distills into Contexts/Topics. This file does ONLY
// the mechanical, testable parts — read, filter, summarize, and decide which
// sessions still need processing (idempotency). The judgement (distill + dedup
// + write via MCP) is done by Claude reading these digests.
//
// Exports are pure and dependency-free so the test harness can exercise them
// directly; the CLI entry at the bottom wires them to the filesystem.

import { readFileSync, readdirSync, existsSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

export const MAX_TEXT_BLOCK = 4000; // cap one prose block so a dump can't dominate

const SKIP_USER_PREFIXES = [
  '<local-command',
  'Caveat:',
  '<command-name>',
  '<command-message>',
  '[Request interrupted'
];

// Claude Code encodes a project's cwd into its transcript dir name by replacing
// every non-alphanumeric run with '-' and prefixing '-'. We only ever decode by
// matching the directory back to a known cwd, so the encoder is all we need.
export function encodeProjectDir(cwd) {
  return cwd.replace(/[^a-zA-Z0-9]/g, '-');
}

export function projectsRoot() {
  return join(homedir(), '.claude', 'projects');
}

// Pull the plain text out of a message `content` (string or block array).
function textFromContent(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && typeof b === 'object' && b.type === 'text')
      .map((b) => b.text || '')
      .join('\n');
  }
  return '';
}

// Drop harness/hook noise and command echoes; return the real user text or null.
export function cleanUser(text) {
  let t = (text || '').trim();
  if (!t) return null;
  for (const p of SKIP_USER_PREFIXES) if (t.startsWith(p)) return null;
  if (t.includes('<command-name>')) return null;
  // Strip injected system-reminder / hook blocks that wrap the real prompt.
  t = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
  return t || null;
}

const DURABLE_CMD = /^(git|gh|terraform|make|aws|alembic|docker|npm run|pytest|python -m)\b/;

// Parse one transcript's JSONL text into a structured digest object. Pure: takes
// the raw file contents, returns data — no I/O, so tests pass fixture strings.
export function extractDigest(jsonlText) {
  const d = {
    sessionId: '',
    repo: '',
    gitBranch: '',
    title: '',
    started: '',
    ended: '',
    userTurns: 0,
    assistantTurns: 0,
    turns: [],
    filesTouched: new Set(),
    commands: [],
    prs: new Set()
  };
  for (const line of jsonlText.split('\n')) {
    if (!line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const t = o.type;
    if (t === 'ai-title') {
      d.title = o.aiTitle || o.title || d.title;
      continue;
    }
    if (t === 'pr-link') {
      if (o.prUrl) d.prs.add(o.prUrl);
      continue;
    }
    if (t !== 'user' && t !== 'assistant') continue;
    if (o.isMeta || o.isSidechain) continue;
    if (!d.sessionId) {
      d.sessionId = o.sessionId || '';
      d.repo = o.cwd || '';
      d.gitBranch = o.gitBranch || '';
    }
    if (o.timestamp) {
      if (!d.started) d.started = o.timestamp;
      d.ended = o.timestamp;
    }
    const content = o.message && o.message.content;
    if (t === 'user') {
      const text = cleanUser(textFromContent(content));
      if (text) {
        d.userTurns++;
        d.turns.push(['user', text.slice(0, MAX_TEXT_BLOCK)]);
      }
    } else {
      if (Array.isArray(content)) {
        for (const b of content) {
          if (!b || b.type !== 'tool_use') continue;
          const inp = b.input || {};
          if (['Edit', 'Write', 'NotebookEdit'].includes(b.name) && inp.file_path) {
            d.filesTouched.add(inp.file_path);
          } else if (b.name === 'Bash') {
            const cmd = (inp.command || '').trim();
            if (DURABLE_CMD.test(cmd)) d.commands.push(cmd.slice(0, 200));
          }
        }
      }
      const text = textFromContent(content);
      if (text.trim()) {
        d.assistantTurns++;
        d.turns.push(['assistant', text.slice(0, MAX_TEXT_BLOCK)]);
      }
    }
  }
  return d;
}

// A session worth distilling has real back-and-forth, not a single /command.
export function isSubstantive(d) {
  return d.userTurns >= 1 && d.assistantTurns >= 2;
}

// Render a digest to the markdown Claude reads.
export function renderDigest(d) {
  const out = [];
  out.push(`# Session digest: ${d.title || d.sessionId}`);
  out.push(`- session_id: ${d.sessionId}`);
  out.push(`- repo: ${d.repo}`);
  out.push(`- branch: ${d.gitBranch}`);
  out.push(`- span: ${d.started} -> ${d.ended}`);
  out.push(`- turns: ${d.userTurns} user / ${d.assistantTurns} assistant`);
  if (d.filesTouched.size) out.push(`- files touched: ${[...d.filesTouched].sort().join(', ')}`);
  if (d.prs.size) out.push(`- PRs: ${[...d.prs].sort().join(', ')}`);
  if (d.commands.length) {
    out.push('- commands of record:');
    for (const c of d.commands.slice(0, 25)) out.push(`    $ ${c}`);
  }
  out.push('\n## Transcript (signal only)\n');
  for (const [role, text] of d.turns) out.push(`### ${role}\n${text}\n`);
  return out.join('\n');
}

// --- Idempotency ----------------------------------------------------------
// "Run twice = no-op" is gated at the SESSION level: every bootstrap write
// carries session_id=<historical session id> and source_type=session-history,
// so the set of already-processed session ids is recoverable from the KB via
// GET /contexts?source_type=session-history. This pure helper decides what is
// left to do; the command supplies `alreadyProcessed` from that query.
export function sessionsToProcess(allSessionIds, alreadyProcessed) {
  const done = new Set(alreadyProcessed);
  const seen = new Set();
  const todo = [];
  for (const id of allSessionIds) {
    if (!id || done.has(id) || seen.has(id)) continue;
    seen.add(id);
    todo.push(id);
  }
  return todo;
}

// --- repo attribution -----------------------------------------------------
// Parse a git remote URL into `owner/repo` — the form contexts are tagged with
// (git_repo). Pure (no I/O) so it's unit-testable; handles ssh + https + .git +
// trailing slash. Returns null if it doesn't look like an owner/repo remote.
export function parseGitRemote(url) {
  if (!url) return null;
  const m = String(url).trim().match(/[:/]([^/:]+\/[^/]+?)(?:\.git)?\/?$/);
  return m ? m[1] : null;
}

// Derive `owner/repo` for a working directory by asking git. Returns null if the
// path is gone / not a git repo / has no origin (the all-repos run then falls
// back to leaving git_repo unset for that session).
function deriveGitRepo(cwd) {
  if (!cwd) return null;
  try {
    const url = execFileSync('git', ['-C', cwd, 'remote', 'get-url', 'origin'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    return parseGitRemote(url);
  } catch {
    return null;
  }
}

// --- CLI ------------------------------------------------------------------
// Usage:
//   bootstrap-extract.mjs list <cwd>      -> substantive sessions for one repo
//   bootstrap-extract.mjs list-all        -> sessions across ALL ~/.claude/projects,
//                                            each tagged with its cwd + gitRepo
//   bootstrap-extract.mjs digest <file>   -> the signal-only digest for one session
function sessionsInDir(dir, gitRepo, cwd) {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.jsonl'))
    .map((f) => {
      const d = extractDigest(readFileSync(join(dir, f), 'utf8'));
      return {
        file: join(dir, f),
        sessionId: d.sessionId,
        title: d.title,
        userTurns: d.userTurns,
        assistantTurns: d.assistantTurns,
        substantive: isSubstantive(d),
        cwd: cwd ?? d.repo,
        gitRepo: gitRepo ?? null
      };
    })
    .filter((s) => s.sessionId);
}

function listSessions(cwd) {
  const dir = join(projectsRoot(), encodeProjectDir(cwd));
  if (!existsSync(dir)) return [];
  return sessionsInDir(dir, deriveGitRepo(cwd), cwd);
}

// Every project under ~/.claude/projects. Each dir maps to one cwd (stored in
// its transcripts); derive cwd+gitRepo ONCE per dir, then tag every session.
function listAllSessions() {
  const root = projectsRoot();
  if (!existsSync(root)) return [];
  const out = [];
  for (const dirName of readdirSync(root)) {
    const dir = join(root, dirName);
    let files;
    try {
      files = readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
    } catch {
      continue; // not a directory / unreadable
    }
    if (!files.length) continue;
    // cwd is the same for every session in the dir — read it from the first
    // parseable transcript, then derive the repo once.
    let cwd = '';
    for (const f of files) {
      const d = extractDigest(readFileSync(join(dir, f), 'utf8'));
      if (d.repo) {
        cwd = d.repo;
        break;
      }
    }
    out.push(...sessionsInDir(dir, deriveGitRepo(cwd), cwd));
  }
  return out;
}

// Robust "is this the entry script?" check: comparing import.meta.url to a
// hand-built file:// string breaks when the path has spaces (URL-encoded as
// %20) — common on macOS. Decode the URL and resolve both through realpath.
function isMainModule() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

if (isMainModule()) {
  const [cmd, arg] = process.argv.slice(2);
  if (cmd === 'list') {
    process.stdout.write(JSON.stringify(listSessions(arg || process.cwd()), null, 2));
  } else if (cmd === 'list-all') {
    process.stdout.write(JSON.stringify(listAllSessions(), null, 2));
  } else if (cmd === 'digest') {
    process.stdout.write(renderDigest(extractDigest(readFileSync(arg, 'utf8'))));
  } else {
    process.stderr.write(
      'usage: bootstrap-extract.mjs list <cwd> | list-all | digest <file.jsonl>\n'
    );
    process.exit(2);
  }
}
