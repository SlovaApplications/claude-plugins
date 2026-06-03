#!/bin/bash
# Stop hook: when a turn advanced the work but didn't checkpoint session state,
# block once and nudge Claude to refresh the rolling session-summary (so an
# interrupted session resumes where it left off) — and to capture any novel
# lesson while it's there.
#
# Satisfied by EITHER save_context OR supersede_context this turn (the rolling
# update supersedes the current session-summary; see session-recall.sh).
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

# A save OR a rolling-summary supersede this turn satisfies the checkpoint.
if printf '%s' "$TOOL_USES" | grep -qE '"name":"mcp__context-memory__(save_context|supersede_context)"'; then
  exit 0
fi

SUBSTANTIVE=0

# Mutating work that advances the session and is worth a checkpoint: code
# edits (>=1), commits/pushes, PR/issue creation. Deliberately excludes
# read-only and bookkeeping/communication ops — plain `ls`/`cat`, and
# `gh issue close`/`gh issue comment`/`gh pr merge` — which don't change the
# "where we are" state and would just force a no-op checkpoint turn.
if printf '%s' "$TOOL_USES" \
  | grep -E '"name":"Bash"' \
  | grep -qE 'git commit[ "]|git push[ "]|gh pr create[ "]|gh issue create[ "]'; then
  SUBSTANTIVE=1
fi

# Count occurrences (not lines) — an assistant message can contain multiple
# parallel tool_use blocks on a single JSONL line.
EDIT_COUNT="$(printf '%s' "$TOOL_USES" | grep -oE '"name":"(Edit|Write|NotebookEdit)"' | wc -l | tr -d ' ')"
if [ "${EDIT_COUNT:-0}" -ge 1 ]; then
  SUBSTANTIVE=1
fi

[ "$SUBSTANTIVE" -eq 1 ] || exit 0

jq -nc '{
  decision: "block",
  reason: "context-memory nudge: this turn advanced the work but did not checkpoint session state. Refresh the rolling session-summary so an interrupted session can resume — supersede the current session-summary (its id was injected by the SessionStart recall; use the new id after each update) with where things stand + open items: supersede_context(context_id=\"<current>\", body=\"…\\n\\n## Open items\\n- …\", tags=[\"session-summary\"]). Capture any novel lesson (the WHY/gotcha) as its own save_context too. If nothing changed worth recording, say so in one line and stop again — this will not fire twice."
}'
exit 0
