#!/bin/bash
# Stop hook: block the agent from ending its turn while context-memory has
# tag clusters that crossed the synthesis threshold with no Topic covering
# them. Detection is one read-only API call (no tokens spent); the agent
# resolves each cluster itself — create_topic to synthesize, or
# dismiss_cluster when a cluster should not become a Topic — while it still
# has the full session context, more than it ever saved to context-memory.
#
# stop_hook_active guard: once the agent has already been asked to continue,
# exit 0 so the hook never loops forever.
# Fails open on every error (missing key/deps, network, bad response): a Stop
# hook that hard-failed would wedge the agent, unable to ever finish. Key
# misconfiguration is surfaced loudly by the UserPromptSubmit prefetch hook
# instead — this hook stays silent and lets the agent stop.

API_KEY="${CONTEXT_MEMORY_API_KEY:-}"
API_URL="${CONTEXT_MEMORY_API_URL:-https://api.context-memory.slova.app}"
TIMEOUT="${CONTEXT_MEMORY_TOPIC_STOP_TIMEOUT:-2}"
MAX_IDS=25

[ -n "$API_KEY" ] || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# Never send the bearer token over a cleartext connection. https is always
# fine; http only for a local backend, where there is no network hop to
# eavesdrop. Anything else → fail open (a Stop hook must not hard-fail).
case "$API_URL" in
  https://*) ;;
  http://localhost | http://localhost:* | http://127.0.0.1 | http://127.0.0.1:*) ;;
  *) exit 0 ;;
esac

INPUT="$(cat)"
STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Pass the auth header through a 0600 temp file, not curl's argv — argv is
# readable by any local process via `ps`/`/proc`. mktemp creates the file
# 0600; the EXIT trap removes it on every exit path below.
AUTH_HEADER_FILE="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT
printf 'Authorization: Bearer %s\n' "$API_KEY" > "$AUTH_HEADER_FILE" || exit 0

# -sS keeps curl quiet on success but lets real transport errors (timeout,
# DNS, connection refused) bubble up to ||. -w appends the HTTP status as the
# last line so we can tell 2xx from everything else.
HTTP_RESPONSE="$(
  curl -sS \
    --max-time "$TIMEOUT" \
    -w '\n%{http_code}' \
    -H "@$AUTH_HEADER_FILE" \
    "$API_URL/api/v1/contexts/cluster-suggestions" 2>/dev/null
)" || exit 0

HTTP_STATUS="$(printf '%s' "$HTTP_RESPONSE" | tail -n1)"
RESPONSE="$(printf '%s' "$HTTP_RESPONSE" | sed '$d')"

# Any non-2xx (auth, server error, rate limit) → fail open. The pattern
# matches exactly 200-299; empty or non-numeric statuses fall through too.
case "$HTTP_STATUS" in
  2[0-9][0-9]) ;;
  *)           exit 0 ;;
esac

[ -n "$RESPONSE" ] || exit 0
COUNT="$(printf '%s' "$RESPONSE" | jq '(.clusters // []) | length' 2>/dev/null)"
[ -n "$COUNT" ] && [ "$COUNT" -gt 0 ] 2>/dev/null || exit 0

# One imperative line per cluster: the tag, the live-Context count, and the
# context_ids to attach. IDs are capped so a very large cluster cannot blow
# up the block message; the agent can list_contexts by tag for the rest.
#
# $total is the true live count (context_count); $ids is only the sample the
# backend sent, itself already capped server-side — so "+N more" must be
# counted from $total, not from the length of the truncated $ids array.
DETAIL="$(printf '%s' "$RESPONSE" | jq -r --argjson max "$MAX_IDS" '
  .clusters[]
  | (.context_ids // []) as $ids
  | (.context_count // ($ids | length)) as $total
  | ([$max, ($ids | length)] | min) as $shown
  | "  - tag \"" + .tag + "\": " + ($total | tostring)
    + " Contexts, no Topic. context_ids: " + (($ids[0:$max]) | join(", "))
    + (if $total > $shown
       then " (+" + (($total - $shown) | tostring)
            + " more — list_contexts tag=\"" + .tag + "\" for the rest)"
       else "" end)
' 2>/dev/null)"
[ -n "$DETAIL" ] || exit 0

REASON="context-memory: ${COUNT} tag cluster(s) have reached the synthesis threshold with no Topic covering them. Before you stop, call create_topic for each cluster below — give each a title, scope, overview, and a body that compiles the understanding, and pass the listed context_ids so the Contexts become a durable synthesis:
${DETAIL}
You have more context right now than a future session will. If a cluster genuinely should not become a Topic — a generic/process label, or Contexts too scattered to cohere under one scope — call dismiss_cluster(tag, reason) instead of create_topic. A dismissed cluster stops being flagged; this is how you clear a cluster you are deliberately not synthesizing."

jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
