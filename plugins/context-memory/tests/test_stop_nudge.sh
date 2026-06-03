#!/bin/bash
# Smoke tests for stop-nudge.sh. Run from any cwd: ./tests/test_stop_nudge.sh
# Requires jq.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/../hooks/stop-nudge.sh"
FIX="$DIR/fixtures"
PASS=0
FAIL=0

run_case() {
  local name="$1" fixture="$2" stop_active="$3" expect="$4"
  local payload output decision
  payload="$(jq -nc --arg p "$FIX/$fixture" --argjson sa "$stop_active" '{transcript_path:$p, stop_hook_active:$sa}')"
  output="$(printf '%s' "$payload" | bash "$HOOK")"
  if [ -z "$output" ]; then
    decision="allow"
  else
    decision="$(printf '%s' "$output" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")"
  fi

  if [ "$decision" = "$expect" ]; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s — expected decision=%s, got decision=%s\n' "$name" "$expect" "$decision"
    printf '        output: %s\n' "$output"
    FAIL=$((FAIL + 1))
  fi
}

echo "stop-nudge.sh smoke tests"

# Headline regression: a turn with a tool_call followed by a tool_result must
# still detect meaningful work. The naive "last user line" heuristic landed on
# the tool_result and missed the prior tool_use.
run_case "blocks when commit happened with no save" \
  "meaningful_no_save.jsonl" false block

run_case "allows when save_context was called in the same turn" \
  "meaningful_with_save.jsonl" false allow

run_case "allows on Q&A-only turn (no tool calls)" \
  "qa_only.jsonl" false allow

# stop_hook_active=true means we already blocked once — never block twice.
run_case "allows when stop_hook_active=true even if work happened" \
  "meaningful_no_save.jsonl" true allow

# User typing "mcp__context-memory__save_context" in their prompt must NOT
# be treated as a real call.
run_case "blocks even if user prompt mentions tool name as text" \
  "false_positive_user_text.jsonl" false block

# Three Edits in a single assistant message (one JSONL line) must still
# count as 3, not 1. Line-based counting would silently undercount this.
run_case "blocks on three parallel edits in one assistant message" \
  "parallel_edits.jsonl" false block

# A turn that runs Bash but the command is not meaningful work (e.g. ls)
# must not trigger the predicate.
run_case "allows on non-meaningful Bash (ls) only" \
  "non_meaningful_bash.jsonl" false allow

# Bookkeeping/communication ops (gh issue close/comment, gh pr merge) are
# deliberately NOT meaningful work: they rarely carry a save-worthy insight,
# and firing the block on them just forces a "nothing to save" extra turn.
run_case "allows on bookkeeping (gh issue close) with no save" \
  "bookkeeping_issue_close.jsonl" false allow

# Substring "git commit" inside a path like git-commit-history.txt must
# not trip the meaningful-work matcher.
run_case "allows when 'git commit' appears only as a substring in a filename" \
  "false_substring_git_commit.jsonl" false allow

# Empty / missing transcript: hook must fail open and let Claude stop.
run_case "allows on empty transcript file" \
  "empty.jsonl" false allow

run_missing_transcript_case() {
  local payload output decision
  payload="$(jq -nc --arg p "$FIX/__does_not_exist__.jsonl" '{transcript_path:$p, stop_hook_active:false}')"
  output="$(printf '%s' "$payload" | bash "$HOOK")"
  if [ -z "$output" ]; then
    decision="allow"
  else
    decision="$(printf '%s' "$output" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")"
  fi
  if [ "$decision" = "allow" ]; then
    printf '  PASS  allows on missing transcript path\n'
    PASS=$((PASS + 1))
  else
    printf '  FAIL  allows on missing transcript path — got decision=%s\n' "$decision"
    FAIL=$((FAIL + 1))
  fi
}
run_missing_transcript_case

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
