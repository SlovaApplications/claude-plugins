#!/bin/bash
# UserPromptSubmit hook: search context-memory for prior contexts relevant to
# the user's prompt and inject the top hits as additional context for Claude.
#
# Fails open: if anything goes wrong (no API key, network error, missing deps),
# the script prints nothing and exits 0 so the prompt passes through unchanged.

API_KEY="${CONTEXT_MEMORY_API_KEY:-}"
API_URL="${CONTEXT_MEMORY_API_URL:-https://api.context-memory.slova.app}"
TIMEOUT="${CONTEXT_MEMORY_PREFETCH_TIMEOUT:-1.5}"
LIMIT="${CONTEXT_MEMORY_PREFETCH_LIMIT:-5}"
MAX_OUTPUT_BYTES="${CONTEXT_MEMORY_PREFETCH_MAX_BYTES:-2000}"

[ -n "$API_KEY" ] || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$PROMPT" ] || exit 0

# Cap query length so we don't ship a 10KB prompt as a search query.
QUERY="$(printf '%s' "$PROMPT" | head -c 500)"

REQUEST_BODY="$(jq -nc --arg q "$QUERY" --argjson l "$LIMIT" '{query:$q, limit:$l}' 2>/dev/null)"
[ -n "$REQUEST_BODY" ] || exit 0

RESPONSE="$(
  curl -fsS \
    --max-time "$TIMEOUT" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$REQUEST_BODY" \
    "$API_URL/api/v1/contexts/search" 2>/dev/null
)" || exit 0

[ -n "$RESPONSE" ] || exit 0

COUNT="$(printf '%s' "$RESPONSE" | jq 'if type == "array" then length else 0 end' 2>/dev/null)"
[ -n "$COUNT" ] && [ "$COUNT" != "0" ] || exit 0

{
  printf '[context-memory: %s relevant context(s) from prior sessions]\n\n' "$COUNT"
  printf '%s' "$RESPONSE" | jq -r '
    .[]
    | "### " + (.content.what // "(untitled)")
      + "\n**Why it matters:** " + (.content.why // "—")
      + (if (.content.when_relevant // []) | length > 0
           then "\n**When relevant:** " + ((.content.when_relevant // []) | join(", "))
           else "" end)
      + (if (.content.dead_ends // []) | length > 0
           then "\n**Dead ends:** " + ((.content.dead_ends // []) | join("; "))
           else "" end)
      + "\n"
  ' 2>/dev/null
} | head -c "$MAX_OUTPUT_BYTES"

exit 0
