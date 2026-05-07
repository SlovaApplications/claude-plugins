#!/bin/bash
# Smoke tests for prefetch.sh. Run from any cwd: ./tests/test_prefetch.sh
# Requires jq.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/../hooks/prefetch.sh"
PASS=0
FAIL=0

# Missing key: hook must hard-fail with exit 2 and emit setup guidance to
# stderr. Silent no-op would hide the misconfiguration.
run_missing_key_case() {
  local payload stderr_out exit_code
  payload='{"prompt":"hello"}'
  stderr_out="$(printf '%s' "$payload" | env -u CONTEXT_MEMORY_API_KEY bash "$HOOK" 2>&1 >/dev/null)"
  exit_code=$?

  if [ "$exit_code" -ne 2 ]; then
    printf '  FAIL  missing key exits 2 — got exit=%s\n' "$exit_code"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$stderr_out" | grep -q 'CONTEXT_MEMORY_API_KEY is not set'; then
    printf '  FAIL  missing key stderr mentions the env var\n        stderr: %s\n' "$stderr_out"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$stderr_out" | grep -q 'claude plugin remove'; then
    printf '  FAIL  missing key stderr mentions the disable path\n        stderr: %s\n' "$stderr_out"
    FAIL=$((FAIL + 1))
    return
  fi
  printf '  PASS  missing key exits 2 with setup + disable guidance\n'
  PASS=$((PASS + 1))
}

# Key present but payload has no prompt: hook must still fail open (exit 0)
# so the user's prompt passes through unchanged. Guards against the new
# hard-fail accidentally swallowing the existing fail-open paths.
run_no_prompt_case() {
  local payload exit_code
  payload='{}'
  printf '%s' "$payload" | CONTEXT_MEMORY_API_KEY=cm_test bash "$HOOK" >/dev/null 2>&1
  exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    printf '  PASS  key present + empty prompt fails open (exit 0)\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  key present + empty prompt — expected exit 0, got %s\n' "$exit_code"
    FAIL=$((FAIL + 1))
  fi
}

echo "prefetch.sh smoke tests"
run_missing_key_case
run_no_prompt_case

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
