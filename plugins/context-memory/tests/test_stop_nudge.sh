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

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
