#!/bin/bash
# PostToolUse hook for Bash: when Claude runs a "meaningful work" command
# (commit, PR/issue ops), inject a soft reminder to consider saving context.
# This is a contextual hint — the load-bearing enforcement is in stop-nudge.sh.
#
# Fails open: any error → exit 0 with no output.

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$TOOL" = "Bash" ] || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || exit 0

case "$CMD" in
  *"git commit"*|*"gh pr create"*|*"gh pr merge"*|*"gh issue close"*|*"gh issue create"*|*"gh issue comment"*)
    HINT="context-memory nudge: meaningful work just happened. If something novel was learned (a non-obvious decision, a gotcha, a why-it-matters), call mcp__context-memory__save_context now while it's fresh. Skip if it's pure bookkeeping."
    jq -nc --arg hint "$HINT" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $hint
      }
    }'
    ;;
esac

exit 0
