#!/bin/bash
# SessionStart hook: inject this repo's "where you left off" memory at the start
# of a session, and stand up the capture instruction so the agent keeps that
# memory current.
#
# Two jobs, one hook (the crawl-phase design — see context-memory
# docs/SHARED_KNOWLEDGE_SUBSTRATE_PLAN.md § Roadmap):
#   1. SURFACE — fetch the newest `session-summary` Context + all `orientation`
#      Contexts for the current repo and inject them via additionalContext.
#   2. CAPTURE (instruction-only) — inject a standing instruction telling the
#      agent to save a session-summary at wrap-up and to capture durable project
#      facts as `orientation`, with this repo's canonical git_repo baked in so
#      capture and recall agree on the key.
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

# GET /api/v1/contexts?git_repo=<repo>&tag=<tag>&limit=<n>, recency-ordered.
# Echoes the JSON body on success, empty on any transport/non-2xx failure.
fetch_contexts() {
  tag="$1"; lim="$2"
  resp="$(
    curl -sS --max-time "$TIMEOUT" --get \
      -H "@$AUTH_HEADER_FILE" \
      --data-urlencode "git_repo=$REPO" \
      --data-urlencode "tag=$tag" \
      --data-urlencode "limit=$lim" \
      -w '\n%{http_code}' \
      "$API_URL/api/v1/contexts" 2>/dev/null
  )" || return 1
  status="$(printf '%s' "$resp" | tail -n1)"
  case "$status" in 2[0-9][0-9]) ;; *) return 1 ;; esac
  printf '%s' "$resp" | sed '$d'
}

SUMMARY_JSON="$(fetch_contexts session-summary 1)"
ORIENTATION_JSON="$(fetch_contexts orientation "$ORIENTATION_LIMIT")"

SUMMARY_BODY="$(printf '%s' "$SUMMARY_JSON" | jq -r '.items[0].body // empty' 2>/dev/null)"
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
    if [ -n "$SUMMARY_BODY" ]; then
      printf '## Where you left off\n%s\n\n' "$SUMMARY_BODY"
    else
      printf '## Where you left off\nNo prior session recorded for this repo yet.\n\n'
    fi
    if [ -n "$ORIENTATION_BODIES" ]; then
      printf '## Project facts\n%s\n' "$ORIENTATION_BODIES"
    fi
  } | head -c "$MAX_OUTPUT_BYTES"
)"

# Built as a plain multi-line double-quoted string (NOT a $(cat <<EOF) here-doc):
# the instruction text contains apostrophes ("repo's", "it's"), and apostrophes
# inside a command-substitution-wrapped here-doc confuse bash's parser into
# treating the span between them as single-quoted, so the trailing lines get run
# as commands. A direct double-quoted assignment expands $REPO, keeps apostrophes
# literal, and has no such pitfall.
INSTRUCTION="

---
[context-memory — keep this repo's memory current (git_repo=\"$REPO\"):
• When you finish meaningful work or the user wraps up, save a short session summary:
  save_context(body=\"<what happened>\n\n## Open items\n- …\", tags=[\"session-summary\"], git_repo=\"$REPO\")
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
