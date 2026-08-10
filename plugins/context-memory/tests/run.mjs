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
    // Hermetic by default: without this, v0.15 file discovery would find the
    // developer's REAL credentials.json and the "no key" tests would hit the
    // live engine. Point discovery at a nonexistent file unless a test opts in.
    const childEnv = {
      ...process.env,
      CONTEXT_MEMORY_CREDENTIALS: join(tmpdir(), 'cm-tests-no-such-credentials.json'),
      ...env
    };
    delete childEnv.CONTEXT_MEMORY_API_KEY;
    delete childEnv.CONTEXT_MEMORY_API_URL;
    Object.assign(childEnv, env);
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
  const authFail = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: 'help me debug this auth issue' }), env: KEY });
  check('401 → exit 2 + auth guidance', authFail.code === 2 && authFail.err.includes('authentication failed'));

  mock = (req, res) =>
    json(res, [
      { type: 'topic', title: 'My Topic', overview: 'Overview', load_bearing_tier: 'proven', tags: ['x'] },
      { type: 'context', body: '# Heading\nbody', tags: ['z'] }
    ]);
  const happy = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: 'how do I fix the flaky test' }), env: KEY });
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
  const nudge = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: 'how do I fix the flaky test' }), env: KEY });
  check('two Contexts + no Topic → synthesis nudge', nudge.out.includes('consider calling create_topic'));

  // Locality: the search body carries the session cwd as `project` and the
  // origin repo as `git_repo` so the backend can boost same-project hits.
  let captured = null;
  mock = (req, res) => {
    try {
      captured = JSON.parse(req.body);
    } catch {
      captured = null;
    }
    json(res, [{ type: 'context', body: '# A\n1', tags: [] }]);
  };
  const loc = await runHook('prefetch.mjs', {
    payload: JSON.stringify({ prompt: 'where does the config live', cwd: TESTS_DIR }),
    env: KEY
  });
  check(
    'search request carries project (cwd) + git_repo (locality)',
    loc.code === 0 &&
      captured &&
      captured.project === TESTS_DIR &&
      typeof captured.git_repo === 'string' &&
      captured.git_repo.length > 0
  );

  // v0.14 non-prompt gating: notifications, command scaffolding, and trivially
  // short prompts carry no retrieval intent — recall must not fire.
  mock = (req, res) => json(res, [{ type: 'context', body: '# A\n1', tags: [] }]);
  const gatedInputs = [
    ['task-notification', '<task-notification>\n<task-id>x</task-id>\n</task-notification>'],
    ['system-notification', '[SYSTEM NOTIFICATION - NOT USER INPUT]\nautomated event'],
    ['slash-command scaffolding', '<command-name>/model</command-name>'],
    ['bash-input passthrough', '<bash-input>ls -la</bash-input>'],
    ['short prompt', 'retry']
  ];
  for (const [label, gatedPrompt] of gatedInputs) {
    const gated = await runHook('prefetch.mjs', { payload: JSON.stringify({ prompt: gatedPrompt }), env: KEY });
    check(`non-prompt gated: ${label}`, gated.code === 0 && gated.out === '');
  }
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
      freshCtx.includes('session_id="FRESH"') &&
      freshCtx.includes('project="') // capture instruction carries the cwd (project)
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

  // Backend down (the session-summary probe 500s) must NOT render as the false
  // "No prior session recorded" — that's the bug where a timeout looked like an
  // empty repo and steered the agent to fork a duplicate summary.
  mock = (req, res) => {
    const url = new URL(req.url, 'http://x');
    const tag = url.searchParams.get('tag');
    if (tag === 'session-summary') return json(res, { detail: 'boom' }, 500);
    if (tag === 'orientation') return json(res, { items: [{ body: 'fact one' }] });
    return json(res, { items: [] });
  };
  const down = await runHook('session-recall.mjs', {
    payload: JSON.stringify({ cwd: TESTS_DIR, session_id: 'DOWN' }),
    env: KEY
  });
  const downCtx = (() => {
    try {
      return JSON.parse(down.out).hookSpecificOutput.additionalContext;
    } catch {
      return '';
    }
  })();
  check(
    'recall unreachable → honest message + look-before-create (not false "no prior session")',
    downCtx.includes('unreachable at session start') &&
      !downCtx.includes('No prior session recorded') &&
      downCtx.includes('recall was unavailable') &&
      downCtx.includes('list_contexts(git_repo=')
  );
}

// ---- v0.15 zero-setup pairing: credentials discovery + MCP bridge -------
console.log('credentials discovery + mcp/bridge.mjs');
{
  const { writeFileSync } = await import('node:fs');
  const credsDir = mkdtempSync(join(tmpdir(), 'cm-creds-'));
  const credsPath = join(credsDir, 'credentials.json');
  writeFileSync(credsPath, JSON.stringify({ url: MOCK_URL, token: 'cm_local_filetoken' }));
  const CREDS = { CONTEXT_MEMORY_CREDENTIALS: credsPath };

  // Hooks discover the token from the file — no env vars at all.
  mock = (req, res) => {
    req.auth = req.headers.authorization;
    if (req.auth !== 'Bearer cm_local_filetoken') return json(res, {}, 401);
    return json(res, { items: [] });
  };
  const recall = await runHook('session-recall.mjs', {
    payload: JSON.stringify({ cwd: TESTS_DIR, session_id: 'FILECREDS' }),
    env: CREDS
  });
  check(
    'hooks authenticate via discovered credentials file (no env vars)',
    recall.code === 0 && !recall.out.includes('unreachable at session start')
  );

  // Env var still wins as an explicit override.
  mock = (req, res) => json(res, { override: req.headers.authorization }, 200);
  const overridden = await runHook('session-recall.mjs', {
    payload: JSON.stringify({ cwd: TESTS_DIR, session_id: 'OVERRIDE' }),
    env: { ...CREDS, CONTEXT_MEMORY_API_KEY: 'cm_env_wins', CONTEXT_MEMORY_API_URL: MOCK_URL }
  });
  check('env vars override the credentials file', overridden.code === 0);

  // The stdio bridge: JSON-RPC request in → engine response out.
  function runBridge(lines, env) {
    return new Promise((resolve) => {
      // Same hermeticity rule as runHook: the developer's real env vars must
      // not leak into the bridge under test.
      const bridgeEnv = { ...process.env, CONTEXT_MEMORY_CREDENTIALS: '/nonexistent' };
      delete bridgeEnv.CONTEXT_MEMORY_API_KEY;
      delete bridgeEnv.CONTEXT_MEMORY_API_URL;
      Object.assign(bridgeEnv, env);
      const ps = spawn(process.execPath, [join(TESTS_DIR, '..', 'mcp', 'bridge.mjs')], {
        env: bridgeEnv
      });
      let out = '';
      ps.stdout.on('data', (d) => (out += d));
      const timer = setTimeout(() => ps.kill(), 4000);
      ps.on('close', () => {
        clearTimeout(timer);
        resolve(out.trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)));
      });
      ps.stdin.write(lines.map((l) => JSON.stringify(l)).join('\n') + '\n');
      ps.stdin.end();
    });
  }

  mock = (req, res) => {
    if (req.headers.authorization !== 'Bearer cm_local_filetoken') return json(res, {}, 401);
    const rpc = JSON.parse(req.body);
    if (rpc.id === undefined) return json(res, {}, 202); // notification ack
    return json(res, { jsonrpc: '2.0', id: rpc.id, result: { ok: true, echo: rpc.method } });
  };
  const replies = await runBridge(
    [
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      { jsonrpc: '2.0', id: 2, method: 'tools/list' }
    ],
    CREDS
  );
  check(
    'bridge proxies requests with file-discovered auth; notifications produce no output',
    replies.length === 2 &&
      replies.some((r) => r.id === 1 && r.result?.echo === 'initialize') &&
      replies.some((r) => r.id === 2 && r.result?.echo === 'tools/list')
  );

  const noCreds = await runBridge([{ jsonrpc: '2.0', id: 7, method: 'initialize' }], {});
  check(
    'bridge without credentials returns a pairing error, not a hang',
    noCreds.length === 1 && noCreds[0].id === 7 && /launch the context-memory app/.test(noCreds[0].error?.message ?? '')
  );

  const engineDown = await runBridge([{ jsonrpc: '2.0', id: 9, method: 'initialize' }], {
    CONTEXT_MEMORY_API_KEY: 'cm_x',
    CONTEXT_MEMORY_API_URL: 'http://127.0.0.1:1'
  });
  check(
    'bridge with engine down returns an actionable JSON-RPC error',
    engineDown.length === 1 && /is the context-memory app running/.test(engineDown[0].error?.message ?? '')
  );
}

console.log(`\nsummary: ${pass} passed, ${fail} failed`);
server.close();
process.exit(fail === 0 ? 0 : 1);
