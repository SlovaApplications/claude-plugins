#!/usr/bin/env node
// Cross-platform test harness for the context-memory hooks (Node port).
//
// The hooks use Node's built-in fetch, so the network is mocked with a local
// HTTP server (CONTEXT_MEMORY_API_URL) rather than a curl stub. Run:
//   node tests/run.mjs

import { spawn } from 'node:child_process';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';

const TESTS_DIR = dirname(fileURLToPath(import.meta.url));
const HOOKS = join(TESTS_DIR, '..', 'hooks');
const FIX = join(TESTS_DIR, 'fixtures');

let pass = 0;
let fail = 0;
function check(name, cond, detail = '') {
  if (cond) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`);
  }
}

// In-process mock backend; each test sets `mock` to the handler it needs.
let mock = (req, res) => {
  res.writeHead(404);
  res.end('{}');
};
const server = http.createServer(async (req, res) => {
  let body = '';
  for await (const c of req) body += c;
  req.body = body;
  mock(req, res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const MOCK_URL = `http://127.0.0.1:${server.address().port}`;
const json = (res, obj, status = 200) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
};

function runHook(file, { payload = '', env = {}, cwd } = {}) {
  return new Promise((resolve) => {
    const childEnv = { ...process.env, ...env };
    for (const k of Object.keys(childEnv)) if (childEnv[k] === undefined) delete childEnv[k];
    const ps = spawn(process.execPath, [join(HOOKS, file)], { env: childEnv, cwd });
    let out = '';
    let err = '';
    ps.stdout.on('data', (d) => (out += d));
    ps.stderr.on('data', (d) => (err += d));
    ps.on('close', (code) => resolve({ out, err, code }));
    ps.stdin.end(payload);
  });
}
const decisionOf = (out) => {
  if (!out) return 'allow';
  try {
    return JSON.parse(out).decision || 'allow';
  } catch {
    return 'allow';
  }
};
const KEY = { CONTEXT_MEMORY_API_KEY: 'cm_test', CONTEXT_MEMORY_API_URL: MOCK_URL };

// ---- post-bash-nudge ----------------------------------------------------
console.log('post-bash-nudge.mjs');
{
  const r1 = await runHook('post-bash-nudge.mjs', {
    payload: JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'git commit -m x' } })
  });
  check('commit emits a save_context hint', r1.out.includes('save_context') && r1.code === 0);
  const r2 = await runHook('post-bash-nudge.mjs', {
    payload: JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'ls -la' } })
  });
  check('non-meaningful Bash emits nothing', r2.out === '' && r2.code === 0);
  const r3 = await runHook('post-bash-nudge.mjs', {
    payload: JSON.stringify({ tool_name: 'Read', tool_input: {} })
  });
  check('non-Bash tool emits nothing', r3.out === '' && r3.code === 0);
}

// ---- stop-nudge (reuses fixtures + the original test's expectations) -----
console.log('stop-nudge.mjs');
{
  const cases = [
    ['meaningful_no_save.jsonl', false, 'block'],
    ['meaningful_with_save.jsonl', false, 'allow'],
    ['meaningful_with_supersede.jsonl', false, 'allow'],
    ['single_edit_no_save.jsonl', false, 'block'],
    ['qa_only.jsonl', false, 'allow'],
    ['meaningful_no_save.jsonl', true, 'allow'],
    ['false_positive_user_text.jsonl', false, 'block'],
    ['parallel_edits.jsonl', false, 'block'],
    ['non_meaningful_bash.jsonl', false, 'allow'],
    ['bookkeeping_issue_close.jsonl', false, 'allow'],
    ['false_substring_git_commit.jsonl', false, 'allow'],
    ['empty.jsonl', false, 'allow']
  ];
  for (const [fixture, stopActive, expect] of cases) {
    const r = await runHook('stop-nudge.mjs', {
      payload: JSON.stringify({ transcript_path: join(FIX, fixture), stop_hook_active: stopActive })
    });
    check(`${fixture}${stopActive ? ' (stop_active)' : ''} → ${expect}`, decisionOf(r.out) === expect);
  }
  const miss = await runHook('stop-nudge.mjs', {
    payload: JSON.stringify({ transcript_path: join(FIX, '__missing__.jsonl'), stop_hook_active: false })
  });
  check('missing transcript → allow', decisionOf(miss.out) === 'allow' && miss.code === 0);
}

// ---- prefetch -----------------------------------------------------------
console.log('prefetch.mjs');
{
  const noKey = await runHook('prefetch.mjs', {
    payload: JSON.stringify({ prompt: 'hi' }),
    env: { CONTEXT_MEMORY_API_KEY: undefined }
  });
  check('missing key → exit 2 + setup guidance', noKey.code === 2 && noKey.err.includes('CONTEXT_MEMORY_API_KEY is not set'));

  const noPrompt = await runHook('prefetch.mjs', { payload: '{}', env: KEY });
  check('empty prompt fails open (exit 0)', noPrompt.code === 0 && noPrompt.out === '');

  const badUrl = await runHook('prefetch.mjs', {
    payload: JSON.stringify({ prompt: 'hi' }),
    env: { CONTEXT_MEMORY_API_KEY: 'cm_test', CONTEXT_MEMORY_API_URL: 'http://evil.example' }
  });
  check('non-https URL → exit 2', badUrl.code === 2 && badUrl.err.includes('non-HTTPS'));

  mock = (req, res) => json(res, { detail: 'no' }, 401);
  const authFail = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: 'hi' }), env: KEY });
  check('401 → exit 2 + auth guidance', authFail.code === 2 && authFail.err.includes('authentication failed'));

  mock = (req, res) =>
    json(res, [
      { type: 'topic', title: 'My Topic', overview: 'Overview', load_bearing_tier: 'proven', tags: ['x'] },
      { type: 'context', body: '# Heading\nbody', tags: ['z'] }
    ]);
  const happy = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: 'q' }), env: KEY });
  check(
    'happy path renders header + Topic + Context',
    happy.code === 0 &&
      happy.out.includes('2 relevant result(s)') &&
      happy.out.includes('### [Topic · proven] My Topic') &&
      happy.out.includes('### [Context] Heading') &&
      happy.out.includes('how to use the results above')
  );

  mock = (req, res) =>
    json(res, [
      { type: 'context', body: '# A\n1', tags: [] },
      { type: 'context', body: '# B\n2', tags: [] }
    ]);
  const nudge = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: 'q' }), env: KEY });
  check('two Contexts + no Topic → synthesis nudge', nudge.out.includes('consider calling create_topic'));
}

// ---- topic-stop ---------------------------------------------------------
console.log('topic-stop.mjs');
{
  const noKey = await runHook('topic-stop.mjs', {
    payload: JSON.stringify({ stop_hook_active: false }),
    env: { CONTEXT_MEMORY_API_KEY: undefined }
  });
  check('missing key → allow (fail open)', decisionOf(noKey.out) === 'allow' && noKey.code === 0);

  mock = (req, res) =>
    json(res, { clusters: [{ tag: 'auth', context_count: 3, context_ids: ['a', 'b', 'c'] }] });
  const stopActive = await runHook('topic-stop.mjs', {
    payload: JSON.stringify({ stop_hook_active: true }),
    env: KEY
  });
  check('stop_hook_active=true → allow (no loop)', decisionOf(stopActive.out) === 'allow');

  const blocked = await runHook('topic-stop.mjs', {
    payload: JSON.stringify({ stop_hook_active: false }),
    env: KEY
  });
  check('clusters present → block with tag detail', decisionOf(blocked.out) === 'block' && blocked.out.includes('tag \\"auth\\"'));
}

// ---- session-recall -----------------------------------------------------
console.log('session-recall.mjs');
{
  const noRepo = mkdtempSync(join(tmpdir(), 'cm-norepo-'));
  const outside = await runHook('session-recall.mjs', {
    payload: JSON.stringify({ cwd: noRepo, session_id: 's1' }),
    env: KEY
  });
  check('outside a git repo → emits nothing', outside.out === '' && outside.code === 0);

  // Inside this repo, mock the three context fetches by tag / session_id.
  mock = (req, res) => {
    const url = new URL(req.url, 'http://x');
    const tag = url.searchParams.get('tag');
    const sid = url.searchParams.get('session_id');
    if (tag === 'session-summary' && sid) return json(res, { items: sid === 'RESUME' ? [{ id: 'own-1', body: 'OWN BODY' }] : [] });
    if (tag === 'session-summary') return json(res, { items: [{ id: 'latest-1', body: 'LATEST BODY' }] });
    if (tag === 'orientation') return json(res, { items: [{ body: 'fact one' }, { body: 'fact two' }] });
    return json(res, { items: [] });
  };
  const fresh = await runHook('session-recall.mjs', {
    payload: JSON.stringify({ cwd: TESTS_DIR, session_id: 'FRESH' }),
    env: KEY
  });
  const freshCtx = (() => {
    try {
      return JSON.parse(fresh.out).hookSpecificOutput.additionalContext;
    } catch {
      return '';
    }
  })();
  check(
    'fresh session → previous-session block + 2 facts (no banner)',
    !freshCtx.includes('session-start banner') &&
      freshCtx.includes('Where you left off (previous session)') &&
      freshCtx.includes('LATEST BODY') &&
      freshCtx.includes('- fact one') &&
      freshCtx.includes('session_id="FRESH"')
  );

  const resume = await runHook('session-recall.mjs', {
    payload: JSON.stringify({ cwd: TESTS_DIR, session_id: 'RESUME' }),
    env: KEY
  });
  const resumeCtx = (() => {
    try {
      return JSON.parse(resume.out).hookSpecificOutput.additionalContext;
    } catch {
      return '';
    }
  })();
  check(
    'resumed session → "Resuming this session" + own id',
    resumeCtx.includes('## Resuming this session') &&
      resumeCtx.includes('OWN BODY') &&
      resumeCtx.includes('context_id="own-1"')
  );
}

console.log(`\nsummary: ${pass} passed, ${fail} failed`);
server.close();
process.exit(fail === 0 ? 0 : 1);
