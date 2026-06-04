#!/bin/bash
# SessionStart hook: inject this repo's "where you left off" memory at the start
# of a session, and stand up the capture instruction so the agent keeps that
# memory current.
#
# The rolling session-summary is scoped PER SESSION × repo, not per repo. Each
# session owns its own rolling doc (keyed by the Claude Code session_id); a new
# session does NOT supersede a previous session's summary — it reads it for
# continuity and writes its own. This stops concurrent or successive sessions
# from clobbering each other's end-state. See context-memory
# docs/DATA_MODEL.md § session_id.
#
# Two jobs, one hook:
#   1. SURFACE — fetch the relevant `session-summary` + all `orientation`
#      Contexts for the current repo and inject them via additionalContext.
#        - Resuming a session (this session already wrote a summary, found via
#          the session_id filter): surface it and hand its id back so the agent
#          continues superseding its own doc.
#        - Fresh session: surface the most recent prior session's summary
#          READ-ONLY ("where you left off") and tell the agent to create its
#          own session-scoped summary.
#   2. CAPTURE (instruction-only) — inject a standing instruction telling the
#      agent how to keep this session's summary current, with this repo's
#      canonical git_repo and the current session_id baked in so capture and
#      recall agree.
#
# Posture: unlike prefetch.sh, this hook FAILS OPEN on everything — including a
# missing API key. Blocking or erroring at session start is bad UX, and the
# missing-key case is already surfaced loudly by prefetch on the first prompt.
# Any problem → emit nothing, exit 0.

API_KEY="${CONTEXT_MEMORY_API_KEY:-}"
API_URL="${CONTEXT_MEMORY_API_URL:-https://api.context-memory.slova.app}"
TIMEOUT="${CONTEXT_MEMORY_RECALL_TIMEOUT:-2}"
ORIENTATION_LIMIT="${CONTEXT_MEMORY_ORIENTATION_LIMIT:-25}"
MAX_OUTPUT_BYTES="${CONTEXT_MEMORY_RECALL_MAX_BYTES:-4000}"

command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v git  >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

[ -n "$API_KEY" ] || exit 0

# Same cleartext-key guard as prefetch.sh, but fail open (no exit 2).
case "$API_URL" in
  https://*) ;;
  http://localhost | http://localhost:* | http://127.0.0.1 | http://127.0.0.1:*) ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"

# The Claude Code session id scopes the rolling summary to this session. Stable
# across --resume/--continue, so resuming continues the same doc. Empty is
# tolerated (older clients / odd invocations): we fall back to repo-only
# behavior so memory still flows, just without per-session isolation.
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"

# Canonical repo id = owner/repo from the origin remote (stable across
# https/ssh forms). Fallback: working-tree basename. This MUST match what the
# capture instruction tells the agent to write, or the term-filter misses.
REPO="$(
  url="$(git -C "$CWD" remote get-url origin 2>/dev/null)"
  if [ -n "$url" ]; then
    printf '%s' "$url" | sed -E 's#^git@[^:]+:##; s#^[a-z]+://[^/]+/##; s#\.git$##'
  else
    top="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$top" ] && basename "$top"
  fi
)"
# No repo → nothing to scope recall/capture to; do nothing.
[ -n "$REPO" ] || exit 0

AUTH_HEADER_FILE="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT
printf 'Authorization: Bearer %s\n' "$API_KEY" > "$AUTH_HEADER_FILE" || exit 0

# GET /api/v1/contexts?git_repo=<repo>&tag=<tag>&limit=<n>[&session_id=<sid>],
# recency-ordered. Echoes the JSON body on success, empty on any
# transport/non-2xx failure.
fetch_contexts() {
  tag="$1"; lim="$2"; sid="${3:-}"
  # Optional session_id filter as an array so the two extra args are added
  # cleanly (no word-splitting) only when a session id is present.
  sid_args=()
  [ -n "$sid" ] && sid_args=(--data-urlencode "session_id=$sid")
  resp="$(
    curl -sS --max-time "$TIMEOUT" --get \
      -H "@$AUTH_HEADER_FILE" \
      --data-urlencode "git_repo=$REPO" \
      --data-urlencode "tag=$tag" \
      --data-urlencode "limit=$lim" \
      "${sid_args[@]}" \
      -w '\n%{http_code}' \
      "$API_URL/api/v1/contexts" 2>/dev/null
  )" || return 1
  status="$(printf '%s' "$resp" | tail -n1)"
  case "$status" in 2[0-9][0-9]) ;; *) return 1 ;; esac
  printf '%s' "$resp" | sed '$d'
}

# This session's own rolling summary, if it has written one (resume case).
# Skipped when we have no session id to filter on.
OWN_ID=""
OWN_BODY=""
if [ -n "$SESSION_ID" ]; then
  OWN_JSON="$(fetch_contexts session-summary 1 "$SESSION_ID")"
  OWN_ID="$(printf '%s' "$OWN_JSON" | jq -r '.items[0].id // empty' 2>/dev/null)"
  OWN_BODY="$(printf '%s' "$OWN_JSON" | jq -r '.items[0].body // empty' 2>/dev/null)"
fi

# The most recent summary for this repo across all sessions — what to show as
# "where you left off" when this is a fresh session.
LATEST_JSON="$(fetch_contexts session-summary 1)"
LATEST_BODY="$(printf '%s' "$LATEST_JSON" | jq -r '.items[0].body // empty' 2>/dev/null)"
LATEST_ID="$(printf '%s' "$LATEST_JSON" | jq -r '.items[0].id // empty' 2>/dev/null)"

ORIENTATION_JSON="$(fetch_contexts orientation "$ORIENTATION_LIMIT")"
ORIENTATION_BODIES="$(
  printf '%s' "$ORIENTATION_JSON" \
    | jq -r '.items[]? | "- " + ((.body // "") | gsub("\n";" "))' 2>/dev/null
)"

# Build the injected context. The surfaced memory is byte-capped; the capture
# instruction is printed unconditionally outside the cap so a long summary can
# never truncate away the thing that keeps memory flowing.
SURFACE="$(
  {
    printf '[context-memory · session recall for %s]\n\n' "$REPO"
    if [ -n "$OWN_ID" ]; then
      printf '## Resuming this session\n%s\n\n' "$OWN_BODY"
    elif [ -n "$LATEST_BODY" ]; then
      printf '## Where you left off (previous session)\n%s\n\n' "$LATEST_BODY"
    else
      printf '## Where you left off\nNo prior session recorded for this repo yet.\n\n'
    fi
    if [ -n "$ORIENTATION_BODIES" ]; then
      printf '## Project facts\n%s\n' "$ORIENTATION_BODIES"
    fi
  } | head -c "$MAX_OUTPUT_BYTES"
)"

# The rolling-summary instruction depends on the session's state:
#   - Resuming (own summary exists): supersede that id, keep one doc current.
#   - Fresh session with a session id: create a NEW session-scoped summary
#     (don't touch the previous session's), then supersede the id you get back.
#   - No session id at all: fall back to repo-only rolling on the latest id.
if [ -n "$OWN_ID" ]; then
  ROLLING_LINE="• ROLLING SESSION STATE — you are resuming this session ($SESSION_ID). Keep its summary current by superseding it after each substantive turn (don't start a new one):
  supersede_context(context_id=\"$OWN_ID\", body=\"<where things stand>\n\n## Open items\n- …\", tags=[\"session-summary\"], git_repo=\"$REPO\")
  Use the new id it returns for the next update this session (session_id carries over automatically)."
elif [ -n "$SESSION_ID" ]; then
  ROLLING_LINE="• ROLLING SESSION STATE — the summary above (if any) is the PREVIOUS session's, for context only; do NOT supersede it. Start THIS session's own rolling summary, scoped to this session, then keep it current by superseding it after each substantive turn:
  save_context(body=\"<where things stand>\n\n## Open items\n- …\", tags=[\"session-summary\"], git_repo=\"$REPO\", session_id=\"$SESSION_ID\")
  Then supersede the id it returns after each update (session_id carries over automatically)."
elif [ -n "$LATEST_ID" ]; then
  ROLLING_LINE="• ROLLING SESSION STATE — keep one summary current so an interrupted session resumes. After each substantive turn, SUPERSEDE it (don't append a new one):
  supersede_context(context_id=\"$LATEST_ID\", body=\"<where things stand>\n\n## Open items\n- …\", tags=[\"session-summary\"], git_repo=\"$REPO\")
  Use the new id it returns for the next update this session."
else
  ROLLING_LINE="• ROLLING SESSION STATE — no rolling summary exists yet. Create one now, then keep it current by superseding it after each substantive turn:
  save_context(body=\"<where things stand>\n\n## Open items\n- …\", tags=[\"session-summary\"], git_repo=\"$REPO\")"
fi

# Built as a plain multi-line double-quoted string (NOT a $(cat <<EOF) here-doc):
# the instruction text contains apostrophes ("repo's", "it's"), and apostrophes
# inside a command-substitution-wrapped here-doc confuse bash's parser into
# treating the span between them as single-quoted, so the trailing lines get run
# as commands. A direct double-quoted assignment expands $REPO, keeps apostrophes
# literal, and has no such pitfall.
INSTRUCTION="

---
[context-memory — keep this repo's memory current (git_repo=\"$REPO\"):
$ROLLING_LINE
• When the user states a durable project fact (how it's wired, where things live), capture it once:
  save_context(body=\"<the fact>\", tags=[\"orientation\"], git_repo=\"$REPO\")
Pass git_repo=\"$REPO\" exactly as written so recall and capture stay aligned.]"

ADDITIONAL_CONTEXT="$SURFACE$INSTRUCTION"

# Emit via the documented SessionStart channel. additionalContext is prepended
# before the first user prompt.
jq -nc --arg ctx "$ADDITIONAL_CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0

exit 0
