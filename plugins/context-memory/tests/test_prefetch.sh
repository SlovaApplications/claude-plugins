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

# Build a stub `curl` on a temp PATH so we can simulate server responses
# without making a real network call. Returns body on stdout, then the
# requested HTTP status as the final line — matching the `-w '\n%{http_code}'`
# contract the hook relies on.
make_curl_stub() {
  local status="$1" body="$2"
  STUB_DIR="$(mktemp -d)"
  cat > "$STUB_DIR/curl" <<EOF
#!/bin/bash
printf '%s' '$body'
printf '\n%s' '$status'
EOF
  chmod +x "$STUB_DIR/curl"
  printf '%s' "$STUB_DIR"
}

# Auth failure (401): key is set but server rejected it. Must hard-fail with
# exit 2 and surface guidance — same reasoning as missing-key. A silent
# no-op would leave the user wondering why prefetch went quiet.
run_auth_fail_case() {
  local status="$1" stub_dir stderr_out exit_code
  stub_dir="$(make_curl_stub "$status" '{"detail":"unauthorized"}')"
  stderr_out="$(
    printf '{"prompt":"hi"}' \
      | PATH="$stub_dir:$PATH" CONTEXT_MEMORY_API_KEY=cm_bad \
        bash "$HOOK" 2>&1 >/dev/null
  )"
  exit_code=$?
  rm -rf "$stub_dir"

  if [ "$exit_code" -ne 2 ]; then
    printf '  FAIL  HTTP %s exits 2 — got exit=%s\n' "$status" "$exit_code"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$stderr_out" | grep -q "authentication failed (HTTP $status)"; then
    printf '  FAIL  HTTP %s stderr names the status\n        stderr: %s\n' "$status" "$stderr_out"
    FAIL=$((FAIL + 1))
    return
  fi
  printf '  PASS  HTTP %s exits 2 with auth-failed guidance\n' "$status"
  PASS=$((PASS + 1))
}

# Server-side or transient failure (5xx, 429): must still fail open so a
# flaky backend doesn't block the user's prompt. Guards against accidentally
# expanding the hard-fail branch to all non-2xx.
run_transient_fail_case() {
  local status="$1" stub_dir exit_code
  stub_dir="$(make_curl_stub "$status" '{"detail":"oops"}')"
  printf '{"prompt":"hi"}' \
    | PATH="$stub_dir:$PATH" CONTEXT_MEMORY_API_KEY=cm_test \
      bash "$HOOK" >/dev/null 2>&1
  exit_code=$?
  rm -rf "$stub_dir"

  if [ "$exit_code" -eq 0 ]; then
    printf '  PASS  HTTP %s fails open (exit 0)\n' "$status"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  HTTP %s — expected exit 0, got %s\n' "$status" "$exit_code"
    FAIL=$((FAIL + 1))
  fi
}

echo "prefetch.sh smoke tests"
run_missing_key_case
run_no_prompt_case
run_auth_fail_case 401
run_auth_fail_case 403
run_transient_fail_case 500
run_transient_fail_case 429

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
