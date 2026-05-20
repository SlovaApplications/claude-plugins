#!/bin/bash
# Stop hook: nudge Claude to save_context when meaningful work happened this
# turn but no context-memory tool was called.
#
# Scope: only events after the LAST user PROMPT (not tool_result wrapper).
# In Claude Code transcripts, tool_result blocks are also stored as
# "type":"user" entries — distinguished by the presence of "tool_use_id" —
# so we filter those out when locating the turn boundary.
#
# Once Claude is asked to continue (stop_hook_active=true), exit 0 to avoid
# an infinite loop. Fails open: any error → exit 0 → Claude is allowed to stop.

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

LAST_USER_LINE="$(grep -n '"type":"user"' "$TRANSCRIPT" | grep -v 'tool_use_id' | tail -n 1 | cut -d: -f1)"
[ -n "$LAST_USER_LINE" ] || exit 0
TURN="$(tail -n +"$LAST_USER_LINE" "$TRANSCRIPT")"

TOOL_USES="$(printf '%s' "$TURN" | grep '"type":"tool_use"')"

if printf '%s' "$TOOL_USES" | grep -qE '"name":"mcp__context-memory__save_context"'; then
  exit 0
fi

MEANINGFUL=0

if printf '%s' "$TOOL_USES" \
  | grep -E '"name":"Bash"' \
  | grep -qE 'git commit[ "]|gh pr create[ "]|gh pr merge[ "]|gh issue close[ "]|gh issue create[ "]|gh issue comment[ "]'; then
  MEANINGFUL=1
fi

# Count occurrences (not lines) — an assistant message can contain multiple
# parallel tool_use blocks on a single JSONL line.
EDIT_COUNT="$(printf '%s' "$TOOL_USES" | grep -oE '"name":"(Edit|Write|NotebookEdit)"' | wc -l | tr -d ' ')"
if [ "${EDIT_COUNT:-0}" -ge 3 ]; then
  MEANINGFUL=1
fi

[ "$MEANINGFUL" -eq 1 ] || exit 0

jq -nc '{
  decision: "block",
  reason: "context-memory nudge: this turn included meaningful work (commits, PRs, issue operations, or several edits) but no mcp__context-memory__save_context call was made. Before stopping, save anything novel that future sessions would benefit from — focus on the WHY and the gotchas, not what is already in code or git history. If nothing is worth saving, briefly say so in one line and stop again — this hook will not fire twice."
}'
exit 0
