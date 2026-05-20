#!/bin/bash
# UserPromptSubmit hook: search context-memory for prior contexts relevant to
# the user's prompt and inject the top hits as additional context for Claude.
#
# Hard-fails (exit 2) if CONTEXT_MEMORY_API_KEY is unset — the plugin can't do
# anything useful without it, and a silent no-op hides the misconfiguration.
# All other failures (network error, missing deps, malformed response) still
# fail open: the script prints nothing and exits 0 so the prompt passes through.

API_KEY="${CONTEXT_MEMORY_API_KEY:-}"
API_URL="${CONTEXT_MEMORY_API_URL:-https://api.context-memory.slova.app}"
TIMEOUT="${CONTEXT_MEMORY_PREFETCH_TIMEOUT:-1.5}"
LIMIT="${CONTEXT_MEMORY_PREFETCH_LIMIT:-5}"
MAX_OUTPUT_BYTES="${CONTEXT_MEMORY_PREFETCH_MAX_BYTES:-2000}"

if [ -z "$API_KEY" ]; then
  cat >&2 <<'EOF'
context-memory: CONTEXT_MEMORY_API_KEY is not set.

Fix this by either:

  1. Setting an API key (get one at https://context-memory.slova.app).

     macOS / Linux (bash, zsh):

       export CONTEXT_MEMORY_API_KEY=cm_...

     Add the line to ~/.zshrc or ~/.bashrc to persist across sessions.

     Windows (PowerShell), persistent for the current user:

       [Environment]::SetEnvironmentVariable("CONTEXT_MEMORY_API_KEY", "cm_...", "User")

     Or session-only:

       $env:CONTEXT_MEMORY_API_KEY = "cm_..."

     Windows (cmd.exe), persistent — takes effect in NEW shells only:

       setx CONTEXT_MEMORY_API_KEY cm_...

  2. Disabling the plugin:

       /plugin                                   (interactive)
       claude plugin remove context-memory@slova (one-shot)
EOF
  exit 2
fi

command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$PROMPT" ] || exit 0

# Cap query length so we don't ship a 10KB prompt as a search query.
QUERY="$(printf '%s' "$PROMPT" | head -c 500)"

REQUEST_BODY="$(jq -nc --arg q "$QUERY" --argjson l "$LIMIT" '{query:$q, limit:$l}' 2>/dev/null)"
[ -n "$REQUEST_BODY" ] || exit 0

# Drop -f so non-2xx responses still return the body + status (so we can
# distinguish auth failures from other 4xx/5xx). Append the HTTP status as
# the last line via -w; -sS keeps curl quiet on success but lets real
# transport errors (timeout, DNS, connection refused) bubble up to ||.
HTTP_RESPONSE="$(
  curl -sS \
    --max-time "$TIMEOUT" \
    -w '\n%{http_code}' \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$REQUEST_BODY" \
    "$API_URL/api/v1/contexts/search" 2>/dev/null
)" || exit 0

HTTP_STATUS="$(printf '%s' "$HTTP_RESPONSE" | tail -n1)"
RESPONSE="$(printf '%s' "$HTTP_RESPONSE" | sed '$d')"

# 401/403 = the API key is set but the server rejected it. Surface this loudly
# (same reasoning as missing key) — it's almost always a persistent
# misconfiguration, and a silent no-op leaves the user wondering why prefetch
# stopped working. Other non-2xx statuses (5xx, 429, etc.) are likely
# transient and fall through to the fail-open path below.
if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; then
  cat >&2 <<EOF
context-memory: authentication failed (HTTP $HTTP_STATUS).

Your CONTEXT_MEMORY_API_KEY is set but the server rejected it. The key
is most likely expired, revoked, or malformed.

Fix this by either:

  1. Issuing a new API key at https://context-memory.slova.app and
     replacing the value in your shell config (see the missing-key
     error message for per-OS instructions).

  2. Disabling the plugin:

       /plugin                                   (interactive)
       claude plugin remove context-memory@slova (one-shot)
EOF
  exit 2
fi

# Any other non-2xx: fail open. Server errors and rate limits should not
# block the user's prompt. The pattern matches exactly 200-299; empty or
# non-numeric statuses (shouldn't happen with curl's %{http_code}, but
# defensive) fall through to the wildcard branch.
case "$HTTP_STATUS" in
  2[0-9][0-9]) ;;
  *)           exit 0 ;;
esac

[ -n "$RESPONSE" ] || exit 0

COUNT="$(printf '%s' "$RESPONSE" | jq 'if type == "array" then length else 0 end' 2>/dev/null)"
[ -n "$COUNT" ] && [ "$COUNT" != "0" ] || exit 0

# Count each kind separately: the counts label the header and decide whether
# the synthesis nudge fires below. A malformed response yields empty strings,
# which the arithmetic comparisons treat as 0.
TOPIC_COUNT="$(printf '%s' "$RESPONSE" | jq '[.[] | select(.type == "topic")] | length' 2>/dev/null)"
CONTEXT_COUNT="$(printf '%s' "$RESPONSE" | jq '[.[] | select(.type != "topic")] | length' 2>/dev/null)"

# Search returns a mixed Context+Topic list (see context-memory DATA_MODEL.md):
# every item carries a `type`; Contexts carry a flat markdown `body`, Topics
# carry `title` + `overview`. The old `.content.{what,why,...}` shape is gone.
{
  printf '[context-memory: %s relevant result(s) from prior sessions]\n\n' "$COUNT"
  printf '%s' "$RESPONSE" | jq -r '
    def clip($n): if (. | length) > $n then .[0:$n] + "…" else . end;
    .[]
    | (
        if .type == "topic" then
          "### [Topic] " + ((.title // "(untitled topic)") | clip(120))
          + "\n" + ((.overview // "") | clip(280))
        else
          ((.body // "") | split("\n")) as $lines
          | (($lines[0] // "") | sub("^#+[[:space:]]*"; "")) as $head
          | "### " + (if ($head | test("[^[:space:]]")) then ($head | clip(120))
                      else "(untitled context)" end)
          + "\n" + (($lines[1:] | join("\n")) | clip(280))
        end
      )
      + (if (.tags // []) | length > 0 then "\ntags: " + (.tags | join(", ")) else "" end)
      + "\n"
  ' 2>/dev/null
} | head -c "$MAX_OUTPUT_BYTES"

# Synthesis nudge: several Contexts came back and no Topic ties them together.
# Encourage the agent to compile them. Printed outside the byte cap above so a
# long result list can't truncate it away — it is short and is the whole point
# of surfacing the cluster.
if [ "${CONTEXT_COUNT:-0}" -ge 2 ] && [ "${TOPIC_COUNT:-0}" -eq 0 ]; then
  printf '\n[context-memory: %s related Contexts surfaced and no Topic synthesizes them. If they cohere around one subject, consider calling create_topic to compile them into a durable synthesis.]\n' "$CONTEXT_COUNT"
fi

exit 0
