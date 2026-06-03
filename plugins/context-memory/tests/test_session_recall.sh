#!/bin/bash
# Smoke tests for session-recall.sh. Run from any cwd: ./tests/test_session_recall.sh
# Requires jq. Stubs both `git` (repo derivation) and `curl` (API) on a temp
# PATH so nothing touches a real repo or the production API.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/../hooks/session-recall.sh"
PASS=0
FAIL=0

PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","cwd":"/tmp/proj"}'

# Build stub `git` + `curl` on a temp PATH. Both read their behavior from env
# at exec time (STUB_GIT_URL / STUB_GIT_TOPLEVEL / STUB_SUMMARY /
# STUB_ORIENTATION / STUB_STATUS) so test bodies can hold any characters.
make_stubs() {
  local d
  d="$(mktemp -d)" || {
    echo "FATAL: mktemp -d failed; refusing to run against the real API/repo" >&2
    exit 1
  }
  [ -d "$d" ] || { echo "FATAL: bad stub dir" >&2; exit 1; }

  cat > "$d/git" <<'STUB'
#!/bin/bash
case "$*" in
  *"remote get-url"*)
    [ -n "${STUB_GIT_URL:-}" ] || exit 1
    printf '%s\n' "$STUB_GIT_URL" ;;
  *"rev-parse --show-toplevel"*)
    [ -n "${STUB_GIT_TOPLEVEL:-}" ] || exit 1
    printf '%s\n' "$STUB_GIT_TOPLEVEL" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$d/git"

  cat > "$d/curl" <<'STUB'
#!/bin/bash
args="$*"
if printf '%s' "$args" | grep -q 'tag=session-summary'; then
  printf '%s' "${STUB_SUMMARY:-}"
elif printf '%s' "$args" | grep -q 'tag=orientation'; then
  printf '%s' "${STUB_ORIENTATION:-}"
fi
printf '\n%s' "${STUB_STATUS:-200}"
STUB
  chmod +x "$d/curl"

  printf '%s' "$d"
}

# Run the hook with stubs + env; echoes stdout and RETURNS the hook's exit code
# (callers capture it via `EXIT=$?` right after the command substitution — the
# code can't be set on a global from inside the `$(...)` subshell).
run_hook() {
  local stub_dir out rc
  stub_dir="$(make_stubs)" || exit 1
  out="$(
    printf '%s' "$PAYLOAD" \
      | PATH="$stub_dir:$PATH" \
        CONTEXT_MEMORY_API_KEY="${KEY-cm_test}" \
        CONTEXT_MEMORY_API_URL="${URL-https://api.context-memory.slova.app}" \
        STUB_GIT_URL="${STUB_GIT_URL-}" \
        STUB_GIT_TOPLEVEL="${STUB_GIT_TOPLEVEL-}" \
        STUB_SUMMARY="${STUB_SUMMARY-}" \
        STUB_ORIENTATION="${STUB_ORIENTATION-}" \
        STUB_STATUS="${STUB_STATUS-200}" \
        bash "$HOOK" 2>/dev/null
  )"
  rc=$?
  rm -rf "$stub_dir"
  printf '%s' "$out"
  return "$rc"
}

EXIT=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

echo "session-recall.sh smoke tests"

# 1. Happy path: repo + summary + orientation → valid SessionStart JSON whose
#    additionalContext carries the recall, the project facts, and the capture
#    instruction with the canonical owner/repo git_repo.
test_happy() {
  local out ctx
  out="$(
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_SUMMARY='{"items":[{"id":"019e-rolling-id","body":"Wired the ETL.\n\n## Open items\n- backfill 2023"}]}' \
    STUB_ORIENTATION='{"items":[{"body":"data-lake is sourced from the app DB"}]}' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "happy path exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  [ -n "$ctx" ] || { bad "happy path emits additionalContext" "out=$out"; return; }
  printf '%s' "$ctx" | grep -q 'Where you left off'      || { bad "has recall header" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'Wired the ETL'           || { bad "has summary body" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'supersede_context'       || { bad "instruction tells agent to supersede the rolling summary" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q '019e-rolling-id'         || { bad "instruction surfaces the current summary id" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'Project facts'           || { bad "has project facts header" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'sourced from the app DB' || { bad "has orientation body" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"' || { bad "instruction has canonical repo" "$ctx"; return; }
  ok "happy path injects recall + facts + capture instruction (canonical repo)"
}

# 2. No git remote and no toplevel → nothing to scope to → exit 0, no output.
test_no_repo() {
  local out
  out="$(STUB_GIT_URL='' STUB_GIT_TOPLEVEL='' run_hook)"
  EXIT=$?
  if [ "$EXIT" -eq 0 ] && [ -z "$out" ]; then
    ok "no repo → exit 0, no output"
  else
    bad "no repo → expected exit 0 + empty" "exit=$EXIT out=$out"
  fi
}

# 3. Missing API key → FAIL OPEN (exit 0, no output). Divergence from
#    prefetch.sh on purpose: a SessionStart hook must not error at session start.
test_missing_key() {
  local out
  out="$(KEY='' STUB_GIT_URL='git@github.com:acme/widgets.git' run_hook)"
  EXIT=$?
  if [ "$EXIT" -eq 0 ] && [ -z "$out" ]; then
    ok "missing key → fails open (exit 0, no output)"
  else
    bad "missing key → expected exit 0 + empty" "exit=$EXIT out=$out"
  fi
}

# 4. No prior summary (empty items) → still emits, with the "no prior session"
#    line AND the capture instruction (so memory can start flowing).
test_no_prior_summary() {
  local out ctx
  out="$(
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_SUMMARY='{"items":[]}' \
    STUB_ORIENTATION='{"items":[]}' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "no-prior exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  printf '%s' "$ctx" | grep -q 'No prior session recorded' || { bad "no-prior shows empty-state line" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"'   || { bad "no-prior still injects capture instruction" "$ctx"; return; }
  ok "no prior summary → empty-state + capture instruction still injected"
}

# 5. Non-HTTPS, non-localhost URL → refuse (fail open, no output) so the key
#    can't leak over cleartext.
test_cleartext_url() {
  local out
  out="$(URL='http://evil.example.com' STUB_GIT_URL='git@github.com:acme/widgets.git' run_hook)"
  EXIT=$?
  if [ "$EXIT" -eq 0 ] && [ -z "$out" ]; then
    ok "non-HTTPS URL → fails open, no output"
  else
    bad "non-HTTPS URL → expected exit 0 + empty" "exit=$EXIT out=$out"
  fi
}

# 6. Backend 5xx on the fetches → recall degrades gracefully (empty-state) but
#    the hook still emits the capture instruction. Never errors the session.
test_backend_5xx() {
  local out ctx
  out="$(
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_STATUS='500' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "5xx exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"' || { bad "5xx still injects capture instruction" "$ctx"; return; }
  ok "backend 5xx → recall degrades, capture instruction still injected"
}

# 7. ssh and https remotes derive the same canonical owner/repo.
test_repo_derivation() {
  local out ctx
  out="$(STUB_GIT_URL='https://github.com/acme/widgets.git' STUB_SUMMARY='{"items":[]}' run_hook)"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  if printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"'; then
    ok "https remote derives same canonical owner/repo as ssh"
  else
    bad "https remote derivation" "$ctx"
  fi
}

test_happy
test_no_repo
test_missing_key
test_no_prior_summary
test_cleartext_url
test_backend_5xx
test_repo_derivation

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
