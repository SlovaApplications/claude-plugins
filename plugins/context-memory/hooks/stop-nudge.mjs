#!/usr/bin/env node
// Stop hook: when a turn advanced the work but didn't checkpoint session state,
// block once and nudge Claude to refresh the rolling session-summary (so an
// interrupted session resumes where it left off) — and to capture any novel
// lesson while it's there.
//
// Satisfied by EITHER save_context OR supersede_context this turn (the rolling
// update supersedes the current session-summary; see session-recall.mjs).
//
// Scope: only events after the LAST user PROMPT (not tool_result wrapper).
// In Claude Code transcripts, tool_result blocks are also stored as
// "type":"user" entries — distinguished by the presence of "tool_use_id" —
// so we filter those out when locating the turn boundary.
//
// Once Claude is asked to continue (stop_hook_active=true), exit 0 to avoid
// an infinite loop. Fails open: any error → exit 0 → Claude is allowed to stop.

import { readFileSync } from 'node:fs';
import { readStdin, parseJson, emit } from './lib.mjs';

try {
  const input = parseJson(await readStdin());
  if (!input) process.exit(0);

  if (input.stop_hook_active === true || input.stop_hook_active === 'true') process.exit(0);

  const transcriptPath = input.transcript_path || '';
  if (!transcriptPath) process.exit(0);

  let transcript;
  try {
    transcript = readFileSync(transcriptPath, 'utf8');
  } catch {
    process.exit(0);
  }

  const lines = transcript.split('\n');

  // Locate the last real user PROMPT: a "type":"user" line that is NOT a
  // tool_result wrapper (those also serialize as "type":"user" but carry a
  // "tool_use_id").
  let lastUserIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('"type":"user"') && !lines[i].includes('tool_use_id')) {
      lastUserIdx = i;
    }
  }
  if (lastUserIdx < 0) process.exit(0);

  const turn = lines.slice(lastUserIdx);
  const toolUses = turn.filter((l) => l.includes('"type":"tool_use"'));
  const toolUsesText = toolUses.join('\n');

  // A save OR a rolling-summary supersede this turn satisfies the checkpoint.
  // Match the tool name prefix-agnostically: a plugin-provided MCP server is
  // namespaced by Claude Code as `mcp__plugin_<plugin>_<server>__<tool>` (e.g.
  // mcp__plugin_context-memory_context-memory__save_context), while a directly
  // configured server is `mcp__<server>__<tool>`. `[^"]*` around `context-memory`
  // accepts both without crossing the JSON string boundary.
  if (/"name":"mcp__[^"]*context-memory[^"]*__(save_context|supersede_context)"/.test(toolUsesText)) {
    process.exit(0);
  }

  let substantive = false;

  // Mutating work that advances the session and is worth a checkpoint: code
  // edits (>=1), commits/pushes, PR/issue creation. Deliberately excludes
  // read-only and bookkeeping/communication ops.
  if (
    toolUses
      .filter((l) => l.includes('"name":"Bash"'))
      .some((l) => /git commit[ "]|git push[ "]|gh pr create[ "]|gh issue create[ "]/.test(l))
  ) {
    substantive = true;
  }

  // Count occurrences (not lines) — an assistant message can contain multiple
  // parallel tool_use blocks on a single JSONL line.
  const editCount = (toolUsesText.match(/"name":"(Edit|Write|NotebookEdit)"/g) || []).length;
  if (editCount >= 1) substantive = true;

  if (!substantive) process.exit(0);

  emit({
    decision: 'block',
    reason:
      `context-memory nudge: this turn advanced the work but did not checkpoint session state. Refresh THIS session's rolling summary so an interrupted session can resume — follow the SessionStart recall's instruction: if it gave you a summary id, supersede it; if this is a fresh session, create one with save_context(..., tags=["session-summary"], session_id="<the id from recall>") and supersede the id it returns after each update (session_id carries over). Body = where things stand + open items: "…\\n\\n## Open items\\n- …". Capture any novel lesson (the WHY/gotcha) as its own save_context too. If nothing changed worth recording, say so in one line and stop again — this will not fire twice.`
  });
} catch {
  // fail open
}
process.exit(0);
