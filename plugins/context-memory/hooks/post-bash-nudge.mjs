#!/usr/bin/env node
// PostToolUse hook for Bash: when Claude runs a "meaningful work" command
// (commit, PR/issue ops), inject a soft reminder to consider saving context.
// This is a contextual hint — the load-bearing enforcement is in stop-nudge.mjs.
//
// Fails open: any error → exit 0 with no output.

import { readStdin, parseJson, emit } from './lib.mjs';

try {
  const input = parseJson(await readStdin());
  if (!input || input.tool_name !== 'Bash') process.exit(0);

  const cmd = input.tool_input?.command || '';
  if (!cmd) process.exit(0);

  const triggers = [
    'git commit ',
    'gh pr create ',
    'gh pr merge ',
    'gh issue close ',
    'gh issue create ',
    'gh issue comment '
  ];
  if (triggers.some((t) => cmd.includes(t))) {
    emit({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext:
          "context-memory nudge: meaningful work just happened. If something novel was learned (a non-obvious decision, a gotcha, a why-it-matters), call mcp__context-memory__save_context now while it's fresh. Skip if it's pure bookkeeping."
      }
    });
  }
} catch {
  // fail open
}
process.exit(0);
