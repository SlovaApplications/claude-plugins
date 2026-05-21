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
# without making a real network call. The stub reads STUB_BODY / STUB_STATUS
# from the environment at exec time (rather than baking them into the script
# at write time), so test bodies can contain any characters — including
# single quotes — without breaking the heredoc.
make_curl_stub() {
  local stub_dir
  # If mktemp fails, $stub_dir is empty and PATH="$stub_dir:$PATH" silently
  # falls back to the system curl — which would make a real network call
  # against the production API during tests. Bail out loudly instead.
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

# Auth failure (401): key is set but server rejected it. Must hard-fail with
# exit 2 and surface guidance — same reasoning as missing-key. A silent
# no-op would leave the user wondering why prefetch went quiet.
run_auth_fail_case() {
  local status="$1" stub_dir stderr_out exit_code
  stub_dir="$(make_curl_stub)" || exit 1
  stderr_out="$(
    printf '{"prompt":"hi"}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_bad \
        STUB_BODY='{"detail":"unauthorized"}' \
        STUB_STATUS="$status" \
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
  stub_dir="$(make_curl_stub)" || exit 1
  printf '{"prompt":"hi"}' \
    | PATH="$stub_dir:$PATH" \
      CONTEXT_MEMORY_API_KEY=cm_test \
      STUB_BODY='{"detail":"oops"}' \
      STUB_STATUS="$status" \
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

# Regression for an earlier version of the stub that baked the body into the
# generated script via single-quote interpolation, which broke if the body
# itself contained a single quote. The current stub reads from STUB_BODY
# at exec time, so any byte sequence is safe.
run_quote_in_body_case() {
  local stub_dir exit_code
  stub_dir="$(make_curl_stub)" || exit 1
  printf '{"prompt":"hi"}' \
    | PATH="$stub_dir:$PATH" \
      CONTEXT_MEMORY_API_KEY=cm_test \
      STUB_BODY="[{\"msg\":\"it's fine\"}]" \
      STUB_STATUS=500 \
      bash "$HOOK" >/dev/null 2>&1
  exit_code=$?
  rm -rf "$stub_dir"
  if [ "$exit_code" -eq 0 ]; then
    printf '  PASS  body containing single quote does not break the stub\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  body with single quote — expected exit 0, got %s\n' "$exit_code"
    FAIL=$((FAIL + 1))
  fi
}

# Success render — Contexts only. The hook must parse the post-cutover search
# shape (flat `body` + `type`, not the retired `.content.*` nesting) and, when
# several Contexts return with no Topic, emit the create_topic synthesis nudge.
run_render_contexts_case() {
  local stub_dir stdout_out exit_code
  stub_dir="$(make_curl_stub)" || exit 1
  stdout_out="$(
    printf '{"prompt":"hi"}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        STUB_BODY='[{"type":"context","id":"c1","body":"NAT Gateway is the third highest cost","tags":["aws"]},{"type":"context","id":"c2","body":"Single NAT for cost savings","tags":["aws"]}]' \
        STUB_STATUS=200 \
        bash "$HOOK" 2>/dev/null
  )"
  exit_code=$?
  rm -rf "$stub_dir"

  if [ "$exit_code" -ne 0 ]; then
    printf '  FAIL  context render — expected exit 0, got %s\n' "$exit_code"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$stdout_out" | grep -q 'NAT Gateway is the third highest cost'; then
    printf '  FAIL  context render — context body missing from output\n        stdout: %s\n' "$stdout_out"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$stdout_out" | grep -q 'create_topic'; then
    printf '  FAIL  context render — synthesis nudge missing\n        stdout: %s\n' "$stdout_out"
    FAIL=$((FAIL + 1))
    return
  fi
  printf '  PASS  Contexts render and trigger the create_topic nudge\n'
  PASS=$((PASS + 1))
}

# Success render — a Topic is present. The Topic renders with its [Topic]
# marker, and the synthesis nudge must NOT fire: a Topic already covers the
# cluster, so nudging the agent to create another would be noise.
run_render_topic_case() {
  local stub_dir stdout_out exit_code
  stub_dir="$(make_curl_stub)" || exit 1
  stdout_out="$(
    printf '{"prompt":"hi"}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        STUB_BODY='[{"type":"topic","id":"t1","title":"AWS cost review","overview":"Where the spend goes."},{"type":"context","id":"c1","body":"NAT Gateway cost"}]' \
        STUB_STATUS=200 \
        bash "$HOOK" 2>/dev/null
  )"
  exit_code=$?
  rm -rf "$stub_dir"

  if [ "$exit_code" -ne 0 ]; then
    printf '  FAIL  topic render — expected exit 0, got %s\n' "$exit_code"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$stdout_out" | grep -q '\[Topic\] AWS cost review'; then
    printf '  FAIL  topic render — [Topic] marker missing\n        stdout: %s\n' "$stdout_out"
    FAIL=$((FAIL + 1))
    return
  fi
  if printf '%s' "$stdout_out" | grep -q 'create_topic'; then
    printf '  FAIL  topic render — nudge fired despite a Topic being present\n        stdout: %s\n' "$stdout_out"
    FAIL=$((FAIL + 1))
    return
  fi
  printf '  PASS  Topic renders with [Topic] marker and suppresses the nudge\n'
  PASS=$((PASS + 1))
}

# A non-HTTPS, non-local API_URL would send the API key in cleartext. The
# hook must refuse loudly (exit 2) and never reach the request.
run_bad_url_case() {
  local stub_dir stderr_out exit_code
  stub_dir="$(make_curl_stub)" || exit 1
  stderr_out="$(
    printf '{"prompt":"hi"}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        CONTEXT_MEMORY_API_URL=http://insecure.example.com \
        STUB_BODY='[]' \
        STUB_STATUS=200 \
        bash "$HOOK" 2>&1 >/dev/null
  )"
  exit_code=$?
  rm -rf "$stub_dir"
  if [ "$exit_code" -eq 2 ] && printf '%s' "$stderr_out" | grep -q 'non-HTTPS URL'; then
    printf '  PASS  non-HTTPS API_URL exits 2 with a cleartext-leak warning\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  non-HTTPS API_URL — expected exit 2 + warning, got exit=%s stderr=%s\n' "$exit_code" "$stderr_out"
    FAIL=$((FAIL + 1))
  fi
}

# http://localhost is allowed — a local dev backend has no network hop to
# eavesdrop. The guard must let it through to the normal request path.
run_localhost_url_case() {
  local stub_dir stdout_out exit_code
  stub_dir="$(make_curl_stub)" || exit 1
  stdout_out="$(
    printf '{"prompt":"hi"}' \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY=cm_test \
        CONTEXT_MEMORY_API_URL=http://localhost:8000 \
        STUB_BODY='[{"type":"context","id":"c1","body":"local dev context"}]' \
        STUB_STATUS=200 \
        bash "$HOOK" 2>/dev/null
  )"
  exit_code=$?
  rm -rf "$stub_dir"
  if [ "$exit_code" -eq 0 ] && printf '%s' "$stdout_out" | grep -q 'local dev context'; then
    printf '  PASS  http://localhost API_URL is allowed for local dev\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  http://localhost — expected exit 0 + rendered output, got exit=%s stdout=%s\n' "$exit_code" "$stdout_out"
    FAIL=$((FAIL + 1))
  fi
}

# A `curl` stub that records its own argv to $ARGV_FILE, so the test can
# assert the API key is not passed on the command line.
make_argv_recording_curl_stub() {
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
printf '%s\n' "$@" > "$ARGV_FILE"
printf '%s' "$STUB_BODY"
printf '\n%s' "$STUB_STATUS"
STUB
  chmod +x "$stub_dir/curl"
  printf '%s' "$stub_dir"
}

# The API key must never appear in curl's argv — argv is readable by any
# local process via `ps`/`/proc`. It is passed through a header file instead.
run_key_not_in_argv_case() {
  local stub_dir argv_file
  stub_dir="$(make_argv_recording_curl_stub)" || exit 1
  argv_file="$(mktemp)" || { rm -rf "$stub_dir"; exit 1; }
  printf '{"prompt":"hi"}' \
    | PATH="$stub_dir:$PATH" \
      CONTEXT_MEMORY_API_KEY=cm_secret_should_not_leak \
      ARGV_FILE="$argv_file" \
      STUB_BODY='[]' \
      STUB_STATUS=200 \
      bash "$HOOK" >/dev/null 2>&1
  if [ ! -s "$argv_file" ]; then
    printf '  FAIL  key-not-in-argv — curl stub recorded no argv (was it called?)\n'
    FAIL=$((FAIL + 1))
  elif grep -qF 'cm_secret_should_not_leak' "$argv_file"; then
    printf '  FAIL  key-not-in-argv — API key leaked into curl argv:\n%s\n' "$(cat "$argv_file")"
    FAIL=$((FAIL + 1))
  else
    printf '  PASS  API key is not present in curl argv\n'
    PASS=$((PASS + 1))
  fi
  rm -rf "$stub_dir"
  rm -f "$argv_file"
}

echo "prefetch.sh smoke tests"
run_missing_key_case
run_no_prompt_case
run_auth_fail_case 401
run_auth_fail_case 403
run_transient_fail_case 500
run_transient_fail_case 429
run_quote_in_body_case
run_render_contexts_case
run_render_topic_case
run_bad_url_case
run_localhost_url_case
run_key_not_in_argv_case

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
