#!/usr/bin/env bash
# Isolated runner path, step 2: the model. No secrets are in this step's environment except ANTHROPIC_API_KEY, and
# the model only gets the file tools in TOOLS (no shell, no web), so a prompt injected through Slack or Jira text can
# edit files in the clone and nothing else. A later job treats those edits as data.
#
# Env: ANTHROPIC_API_KEY REPO_NAME PROMPT_PATH TOOLS MODEL MAX_TURNS MAX_BUDGET_USD EFFORT GITHUB_OUTPUT
# Writes /tmp/claude-output.json and /tmp/claude-exit; exits with claude's exit code.
set -u
MODEL_FLAG=(); TURN_FLAG=(); BUDGET_FLAG=(); EFFORT_FLAG=()
[ -n "${MODEL:-}" ] && MODEL_FLAG=(--model "$MODEL")
[ -n "${MAX_TURNS:-}" ] && [ "$MAX_TURNS" != "0" ] && TURN_FLAG=(--max-turns "$MAX_TURNS")
[ -n "${MAX_BUDGET_USD:-}" ] && [ "$MAX_BUDGET_USD" != "0" ] && BUDGET_FLAG=(--max-budget-usd "$MAX_BUDGET_USD")
[ -n "${EFFORT:-}" ] && EFFORT_FLAG=(--effort "$EFFORT")
if [ -z "${TOOLS:-}" ]; then
  echo "TOOLS is empty; the isolated path needs an explicit tool list (for example Read,Edit,Write,Glob,Grep)."
  echo "1" > /tmp/claude-exit
  exit 1
fi
claude --dangerously-skip-permissions --tools "$TOOLS" "${MODEL_FLAG[@]}" "${TURN_FLAG[@]}" "${BUDGET_FLAG[@]}" "${EFFORT_FLAG[@]}" \
  -p "$(cat "/tmp/$REPO_NAME/$PROMPT_PATH")" --output-format json > /tmp/claude-output.json
CLAUDE_EXIT=$?
echo "$CLAUDE_EXIT" > /tmp/claude-exit
echo "----- Routine output -----"
jq -r '.result // "(no .result field -- see raw JSON below)"' /tmp/claude-output.json
echo "----- Cost and usage -----"
jq '{cost_usd: .total_cost_usd, duration_ms: .duration_ms, num_turns: .num_turns, usage: .usage}' /tmp/claude-output.json 2>/dev/null || cat /tmp/claude-output.json
if [ "$CLAUDE_EXIT" != "0" ]; then
  echo "claude exited with code $CLAUDE_EXIT (subtype: $(jq -r '.subtype // "unknown"' /tmp/claude-output.json 2>/dev/null))"
fi
exit "$CLAUDE_EXIT"
