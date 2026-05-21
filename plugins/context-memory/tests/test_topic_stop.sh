#!/bin/bash
# Smoke tests for topic-stop.sh. Run from any cwd: ./tests/test_topic_stop.sh
# Requires jq. Uses a stub `curl` on a temp PATH — no real network calls.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/../hooks/topic-stop.sh"
PASS=0
FAIL=0

# Stub `curl`: prints STUB_BODY then a newline + STUB_STATUS, matching the
# hook's `-w '\n%{http_code}'`. Values are read from the environment at exec
# time so bodies can contain any character. See test_prefetch.sh for the
# reasoning behind the mktemp guards.
make_curl_stub() {
  local stub_dir
  stub_dir="$(mktemp -d)" || {
    echo "FATAL: mktemp -d failed; refusing to run tests against the real API" >&2
    exit 1
  }
  if [ -z "$stub_dir" ] || [ ! -d "$stub_dir" ]; then
    echo "FATAL: mktemp -d returned an unusable path: '$stub_dir'" >&2
    exit 1
  fi
  cat > "$stub_dir/curl" <<'STUB'
#!/bin/bash
printf '%s' "$STUB_BODY"
printf '\n%s' "$STUB_STATUS"
STUB
  chmod +x "$stub_dir/curl"
  printf '%s' "$stub_dir"
}

decision_of() {
  if [ -z "$1" ]; then
    printf 'allow'
  else
    printf '%s' "$1" | jq -r '.decision // "allow"' 2>/dev/null || printf 'allow'
  fi
}

# name | stop_active | body | status | expected decision
run_case() {
  local name="$1" stop_active="$2" body="$3" status="$4" expect="$5"
  local stub_dir output decision
  stub_dir="$(make_curl_stub)" || exit 1
  output="$(
    printf '{"stop_hook_active":%s}' "$stop_active" \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        STUB_BODY="$body" \
        STUB_STATUS="$status" \
        bash "$HOOK" 2>/dev/null
  )"
  rm -rf "$stub_dir"
  decision="$(decision_of "$output")"
  if [ "$decision" = "$expect" ]; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s — expected decision=%s, got decision=%s\n' "$name" "$expect" "$decision"
    printf '        output: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi
}

# Missing key: a Stop hook must fail open (exit 0, no output) — hard-failing
# would wedge the agent so it could never stop.
run_missing_key_case() {
  local output exit_code
  output="$(
    printf '{"stop_hook_active":false}' \
      | env -u CONTEXT_MEMORY_API_KEY bash "$HOOK" 2>/dev/null
  )"
  exit_code=$?
  if [ "$exit_code" -eq 0 ] && [ -z "$output" ]; then
    printf '  PASS  missing key fails open (exit 0, no block)\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  missing key — expected exit 0 + empty, got exit=%s output=%s\n' "$exit_code" "$output"
    FAIL=$((FAIL + 1))
  fi
}

# Block case: assert the reason carries the imperative, the tag, and the IDs.
run_block_content_case() {
  local stub_dir output reason
  stub_dir="$(make_curl_stub)" || exit 1
  output="$(
    printf '{"stop_hook_active":false}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        STUB_BODY='{"clusters":[{"tag":"rate-limiting","context_count":5,"context_ids":["c1","c2","c3","c4","c5"]}]}' \
        STUB_STATUS=200 \
        bash "$HOOK" 2>/dev/null
  )"
  rm -rf "$stub_dir"
  reason="$(printf '%s' "$output" | jq -r '.reason // ""' 2>/dev/null)"

  if [ "$(decision_of "$output")" != "block" ]; then
    printf '  FAIL  block content — expected decision=block\n        output: %s\n' "$output"
    FAIL=$((FAIL + 1))
    return
  fi
  for needle in 'create_topic' 'rate-limiting' 'c1, c2, c3, c4, c5'; do
    if ! printf '%s' "$reason" | grep -qF "$needle"; then
      printf '  FAIL  block content — reason missing %q\n        reason: %s\n' "$needle" "$reason"
      FAIL=$((FAIL + 1))
      return
    fi
  done
  printf '  PASS  block reason carries the imperative, tag, and context_ids\n'
  PASS=$((PASS + 1))
}

# Large cluster: context_ids beyond the cap (25) must be summarized, not dumped.
run_id_cap_case() {
  local stub_dir body output reason
  stub_dir="$(make_curl_stub)" || exit 1
  body="$(jq -nc '{clusters:[{tag:"big",context_count:30,context_ids:[range(30)|"id\(.)"]}]}')"
  output="$(
    printf '{"stop_hook_active":false}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        STUB_BODY="$body" \
        STUB_STATUS=200 \
        bash "$HOOK" 2>/dev/null
  )"
  rm -rf "$stub_dir"
  reason="$(printf '%s' "$output" | jq -r '.reason // ""' 2>/dev/null)"
  if [ "$(decision_of "$output")" = "block" ] && printf '%s' "$reason" | grep -qF '+5 more'; then
    printf '  PASS  large cluster caps context_ids and summarizes the rest\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  large cluster — expected block + "+5 more"\n        reason: %s\n' "$reason"
    FAIL=$((FAIL + 1))
  fi
}

echo "topic-stop.sh smoke tests"

run_missing_key_case

# stop_hook_active=true: never block twice, even when clusters are present.
run_case "allows when stop_hook_active=true despite open clusters" \
  true '{"clusters":[{"tag":"x","context_count":9,"context_ids":["a","b"]}]}' 200 allow

# Open clusters present → block.
run_case "blocks when an uncovered cluster exists" \
  false '{"clusters":[{"tag":"auth","context_count":6,"context_ids":["a","b","c"]}]}' 200 block

# No clusters → allow.
run_case "allows when clusters list is empty" \
  false '{"clusters":[]}' 200 allow

# Missing clusters key → allow (treated as empty).
run_case "allows when response has no clusters key" \
  false '{}' 200 allow

# Non-2xx → fail open (a flaky/erroring backend must not wedge the agent).
run_case "fails open on HTTP 401" \
  false '{"detail":"unauthorized"}' 401 allow
run_case "fails open on HTTP 500" \
  false '{"detail":"oops"}' 500 allow

# Malformed body on a 200 → fail open rather than emit a broken block.
run_case "fails open on malformed 200 body" \
  false 'not json' 200 allow

run_block_content_case
run_id_cap_case

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
