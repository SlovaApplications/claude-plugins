#!/bin/bash
# Smoke tests for session-recall.sh. Run from any cwd: ./tests/test_session_recall.sh
# Requires jq. Stubs both `git` (repo derivation) and `curl` (API) on a temp
# PATH so nothing touches a real repo or the production API.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/../hooks/session-recall.sh"
PASS=0
FAIL=0

# Default payload carries a session_id — the rolling summary is per-session now.
# Individual tests override PAYLOAD (e.g. to drop session_id) before run_hook.
PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","cwd":"/tmp/proj","session_id":"sess-abc"}'

# Build stub `git` + `curl` on a temp PATH. Both read their behavior from env
# at exec time (STUB_GIT_URL / STUB_GIT_TOPLEVEL / STUB_SUMMARY /
# STUB_SUMMARY_OWN / STUB_ORIENTATION / STUB_STATUS) so test bodies can hold
# any characters.
#
# The curl stub distinguishes the two session-summary fetches the hook makes:
#   - session-scoped fetch (carries session_id=) → STUB_SUMMARY_OWN (resume)
#   - latest fetch (no session_id)               → STUB_SUMMARY (prior session)
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
  if printf '%s' "$args" | grep -q 'session_id='; then
    printf '%s' "${STUB_SUMMARY_OWN:-}"
  else
    printf '%s' "${STUB_SUMMARY:-}"
  fi
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
        STUB_SUMMARY_OWN="${STUB_SUMMARY_OWN-}" \
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

# 1. Resume: this session already has its own summary (session-scoped fetch
#    returns it) → surface it as "Resuming this session" and instruct the agent
#    to SUPERSEDE its own id (continue the same doc), not start a new one.
test_resume() {
  local out ctx
  out="$(
    PAYLOAD='{"hook_event_name":"SessionStart","source":"resume","cwd":"/tmp/proj","session_id":"sess-abc"}' \
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_SUMMARY_OWN='{"items":[{"id":"019e-own-id","session_id":"sess-abc","body":"Resumed the ETL.\n\n## Open items\n- backfill 2023"}]}' \
    STUB_SUMMARY='{"items":[{"id":"019e-own-id","session_id":"sess-abc","body":"Resumed the ETL."}]}' \
    STUB_ORIENTATION='{"items":[{"body":"data-lake is sourced from the app DB"}]}' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "resume exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  [ -n "$ctx" ] || { bad "resume emits additionalContext" "out=$out"; return; }
  printf '%s' "$ctx" | grep -q 'Resuming this session' || { bad "resume header" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'Resumed the ETL'        || { bad "resume body" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'supersede_context'      || { bad "resume → supersede own doc" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q '019e-own-id'            || { bad "resume surfaces own id" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'sourced from the app DB' || { bad "resume has orientation" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"' || { bad "resume canonical repo" "$ctx"; return; }
  ok "resume → surfaces own summary + supersede-own instruction"
}

# 2. Fresh session with a prior summary from a DIFFERENT session: show the prior
#    body READ-ONLY ("previous session"), and instruct the agent to CREATE its
#    own session-scoped summary — NOT supersede the prior one (its id must not
#    even appear, so the agent can't accidentally clobber it).
test_fresh_with_prior() {
  local out ctx
  out="$(
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_SUMMARY_OWN='{"items":[]}' \
    STUB_SUMMARY='{"items":[{"id":"019e-prev-id","session_id":"sess-OLD","body":"Previous session wired the ETL."}]}' \
    STUB_ORIENTATION='{"items":[]}' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "fresh-with-prior exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  printf '%s' "$ctx" | grep -q 'previous session'                || { bad "shows previous-session header" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'Previous session wired the ETL'  || { bad "shows prior body read-only" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'save_context'                    || { bad "fresh → create own via save_context" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'session_id="sess-abc"'           || { bad "fresh → stamps current session_id" "$ctx"; return; }
  if printf '%s' "$ctx" | grep -q '019e-prev-id'; then
    bad "fresh must NOT expose the prior id (no accidental supersede)" "$ctx"; return
  fi
  ok "fresh+prior → prior shown read-only, create own session-scoped summary"
}

# 3. Fresh session, no prior summary at all → empty-state line + create-own
#    instruction stamped with the current session_id.
test_no_prior_summary() {
  local out ctx
  out="$(
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_SUMMARY_OWN='{"items":[]}' \
    STUB_SUMMARY='{"items":[]}' \
    STUB_ORIENTATION='{"items":[]}' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "no-prior exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  printf '%s' "$ctx" | grep -q 'No prior session recorded' || { bad "no-prior shows empty-state line" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'save_context'              || { bad "no-prior → create own" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'session_id="sess-abc"'     || { bad "no-prior stamps session_id" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"'   || { bad "no-prior injects capture instruction" "$ctx"; return; }
  ok "no prior summary → empty-state + create-own instruction"
}

# 4. No session_id in the payload (older client) → fall back to repo-only
#    rolling: supersede the latest summary's id, as before.
test_no_session_id_fallback() {
  local out ctx
  out="$(
    PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","cwd":"/tmp/proj"}' \
    STUB_GIT_URL='git@github.com:acme/widgets.git' \
    STUB_SUMMARY='{"items":[{"id":"019e-rolling-id","body":"Wired the ETL."}]}' \
    run_hook
  )"
  EXIT=$?
  [ "$EXIT" -eq 0 ] || { bad "fallback exits 0" "exit=$EXIT"; return; }
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  printf '%s' "$ctx" | grep -q 'Where you left off'  || { bad "fallback recall header" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q 'supersede_context'   || { bad "fallback supersedes latest" "$ctx"; return; }
  printf '%s' "$ctx" | grep -q '019e-rolling-id'     || { bad "fallback surfaces latest id" "$ctx"; return; }
  ok "no session_id → repo-only fallback (supersede latest)"
}

# 5. No git remote and no toplevel → nothing to scope to → exit 0, no output.
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

# 6. Missing API key → FAIL OPEN (exit 0, no output). Divergence from
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

# 7. Non-HTTPS, non-localhost URL → refuse (fail open, no output) so the key
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

# 8. Backend 5xx on the fetches → recall degrades gracefully (empty-state) but
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

# 9. ssh and https remotes derive the same canonical owner/repo.
test_repo_derivation() {
  local out ctx
  out="$(STUB_GIT_URL='https://github.com/acme/widgets.git' STUB_SUMMARY='{"items":[]}' STUB_SUMMARY_OWN='{"items":[]}' run_hook)"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  if printf '%s' "$ctx" | grep -q 'git_repo="acme/widgets"'; then
    ok "https remote derives same canonical owner/repo as ssh"
  else
    bad "https remote derivation" "$ctx"
  fi
}

test_resume
test_fresh_with_prior
test_no_prior_summary
test_no_session_id_fallback
test_no_repo
test_missing_key
test_cleartext_url
test_backend_5xx
test_repo_derivation

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
