#!/usr/bin/env node
// Tests for the /bootstrap-memory extractor + idempotency helpers.
//
// The extraction logic is pure (string in, data out), so these import the
// functions and exercise them directly — no spawning, no network. Run:
//   node tests/run-bootstrap.mjs

import {
  extractDigest,
  isSubstantive,
  renderDigest,
  cleanUser,
  encodeProjectDir,
  sessionsToProcess,
  MAX_TEXT_BLOCK
} from '../commands/scripts/bootstrap-extract.mjs';

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

// Build a JSONL transcript from record objects.
const jsonl = (...records) => records.map((r) => JSON.stringify(r)).join('\n');
const userMsg = (text, extra = {}) => ({
  type: 'user',
  sessionId: 's-1',
  cwd: '/home/x/proj',
  gitBranch: 'main',
  timestamp: '2026-06-01T00:00:00Z',
  message: { role: 'user', content: text },
  ...extra
});
const asstMsg = (content, extra = {}) => ({
  type: 'assistant',
  sessionId: 's-1',
  timestamp: '2026-06-01T00:01:00Z',
  message: { role: 'assistant', content },
  ...extra
});

// ---- cleanUser ----------------------------------------------------------
console.log('cleanUser');
{
  check('plain text passes through', cleanUser('fix the bug') === 'fix the bug');
  check('empty -> null', cleanUser('   ') === null);
  check('local-command echo -> null', cleanUser('<local-command-stdout>x</local-command-stdout>') === null);
  check('Caveat -> null', cleanUser('Caveat: the messages below...') === null);
  check('command-name -> null', cleanUser('<command-name>/foo</command-name>') === null);
  check(
    'system-reminder stripped, real prompt kept',
    cleanUser('<system-reminder>noise</system-reminder>\nreal ask') === 'real ask'
  );
  check('interrupted -> null', cleanUser('[Request interrupted by user]') === null);
}

// ---- encodeProjectDir ---------------------------------------------------
console.log('encodeProjectDir');
{
  check('non-alnum runs -> dashes', encodeProjectDir('/Users/a/Dropbox (X)/proj') === '-Users-a-Dropbox--X--proj');
  check('alnum preserved', encodeProjectDir('abc123') === 'abc123');
}

// ---- extractDigest ------------------------------------------------------
console.log('extractDigest');
{
  const text = jsonl(
    { type: 'ai-title', aiTitle: 'My Session', sessionId: 's-1' },
    { type: 'pr-link', prUrl: 'https://gh/pr/1', prNumber: 1 },
    userMsg('do the thing'),
    asstMsg([
      { type: 'text', text: 'On it.' },
      { type: 'tool_use', name: 'Edit', input: { file_path: '/proj/a.py' } },
      { type: 'tool_use', name: 'Bash', input: { command: 'git commit -m x' } },
      { type: 'tool_use', name: 'Bash', input: { command: 'ls -la' } }
    ]),
    asstMsg('Done.'),
    'this is not json{{{',
    userMsg('ignored meta', { isMeta: true }),
    asstMsg('sidechain', { isSidechain: true })
  );
  const d = extractDigest(text);
  check('title from aiTitle', d.title === 'My Session');
  check('pr captured', d.prs.has('https://gh/pr/1'));
  check('sessionId/repo/branch from first turn', d.sessionId === 's-1' && d.repo === '/home/x/proj' && d.gitBranch === 'main');
  check('user turns counted', d.userTurns === 1);
  check('assistant turns counted (text blocks only)', d.assistantTurns === 2);
  check('Edit file_path captured', d.filesTouched.has('/proj/a.py'));
  check('durable Bash kept', d.commands.includes('git commit -m x'));
  check('noise Bash (ls) excluded', !d.commands.some((c) => c.startsWith('ls')));
  check('malformed JSON line skipped (no throw)', d.userTurns === 1);
  check('isMeta excluded', !d.turns.some(([, t]) => t === 'ignored meta'));
  check('isSidechain excluded', !d.turns.some(([, t]) => t === 'sidechain'));
  check('span start/end set', d.started === '2026-06-01T00:00:00Z' && d.ended === '2026-06-01T00:01:00Z');
}
{
  const big = 'x'.repeat(MAX_TEXT_BLOCK + 500);
  const d = extractDigest(jsonl(userMsg(big), asstMsg('a'), asstMsg('b')));
  check('text block truncated to MAX_TEXT_BLOCK', d.turns[0][1].length === MAX_TEXT_BLOCK);
}

// ---- isSubstantive ------------------------------------------------------
console.log('isSubstantive');
{
  const trivial = extractDigest(jsonl(userMsg('<command-name>/x</command-name>'), asstMsg('hi')));
  check('command-only session is not substantive', isSubstantive(trivial) === false);
  const real = extractDigest(jsonl(userMsg('q'), asstMsg('a1'), asstMsg('a2')));
  check('real back-and-forth is substantive', isSubstantive(real) === true);
  check('empty transcript not substantive', isSubstantive(extractDigest('')) === false);
}

// ---- renderDigest -------------------------------------------------------
console.log('renderDigest');
{
  const d = extractDigest(
    jsonl(
      { type: 'ai-title', aiTitle: 'T', sessionId: 's-1' },
      { type: 'pr-link', prUrl: 'https://gh/pr/9' },
      userMsg('ask'),
      asstMsg([
        { type: 'text', text: 'reply' },
        { type: 'tool_use', name: 'Write', input: { file_path: '/p/f.ts' } },
        { type: 'tool_use', name: 'Bash', input: { command: 'make test' } }
      ]),
      asstMsg('more')
    )
  );
  const md = renderDigest(d);
  check('renders title', md.includes('# Session digest: T'));
  check('renders session_id (idempotency key)', md.includes('- session_id: s-1'));
  check('renders turn counts', md.includes('1 user / 2 assistant'));
  check('renders files touched', md.includes('/p/f.ts'));
  check('renders PRs', md.includes('https://gh/pr/9'));
  check('renders durable command', md.includes('$ make test'));
  check('renders transcript sections', md.includes('### user\nask') && md.includes('### assistant\nreply'));
}

// ---- sessionsToProcess (idempotency) ------------------------------------
console.log('sessionsToProcess');
{
  check('filters already-processed', JSON.stringify(sessionsToProcess(['a', 'b', 'c'], ['b'])) === JSON.stringify(['a', 'c']));
  check('all processed -> empty (run-twice no-op)', sessionsToProcess(['a', 'b'], ['a', 'b']).length === 0);
  check('none processed -> all', sessionsToProcess(['a', 'b'], []).length === 2);
  check('dedups repeated ids', JSON.stringify(sessionsToProcess(['a', 'a', 'b'], [])) === JSON.stringify(['a', 'b']));
  check('drops empty ids', sessionsToProcess(['', null, 'a'], []).length === 1);
  check('preserves input order', JSON.stringify(sessionsToProcess(['c', 'a', 'b'], [])) === JSON.stringify(['c', 'a', 'b']));
}

console.log(`\nsummary: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
