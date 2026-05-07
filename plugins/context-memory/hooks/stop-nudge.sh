#!/bin/bash
# Stop hook: nudge Claude to save_context (and vote on used contexts) when
# meaningful work happened this turn but no context-memory tool was called.
#
# Scope: only events after the LAST user message — i.e. just this turn's work.
# Once Claude is asked to continue (stop_hook_active=true), exit 0 to avoid
# an infinite loop. Fails open: any error → exit 0 → Claude is allowed to stop.

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

LAST_USER_LINE="$(grep -n '"type":"user"' "$TRANSCRIPT" | tail -n 1 | cut -d: -f1)"
[ -n "$LAST_USER_LINE" ] || exit 0
TURN="$(tail -n +"$LAST_USER_LINE" "$TRANSCRIPT")"

if printf '%s' "$TURN" | grep -q 'mcp__context-memory__save_context\|mcp__context-memory__vote_context'; then
  exit 0
fi

MEANINGFUL=0

if printf '%s' "$TURN" \
  | grep -E '"name":"Bash"' \
  | grep -qE 'git commit|gh pr create|gh pr merge|gh issue close|gh issue create|gh issue comment'; then
  MEANINGFUL=1
fi

EDIT_COUNT="$(printf '%s' "$TURN" | grep -cE '"name":"(Edit|Write|MultiEdit|NotebookEdit)"' 2>/dev/null)"
if [ "${EDIT_COUNT:-0}" -ge 3 ]; then
  MEANINGFUL=1
fi

[ "$MEANINGFUL" -eq 1 ] || exit 0

jq -nc '{
  decision: "block",
  reason: "context-memory nudge: this turn included meaningful work (commits, PRs, issue operations, or several edits) but no mcp__context-memory__save_context or mcp__context-memory__vote_context call was made. Before stopping: (1) save anything novel learned that future sessions would benefit from — focus on the WHY and gotchas, not what is already in code/git; (2) vote on any contexts that were actually load-bearing for solving the problem (upvote ones that helped, downvote ones that were wrong/outdated). If nothing is worth saving and no surfaced context was load-bearing, briefly say so in one line and stop again — this hook will not fire twice."
}'
exit 0
