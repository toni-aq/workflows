#!/usr/bin/env bash
# Isolated runner path, last step of the finish job: one cost line in the ledger branch, and a DM when a run failed.
# Same record and same alert as the single-job path. Reads what the model job packed in MODEL_OUT:
# claude-output.json, claude-exit, breakdown.json. Bookkeeping must never fail the routine: the workflow marks this
# step continue-on-error.
#
# Env: GH_PAT SLACK_BOT_TOKEN REPO_NAME JOB_NAME MODEL MAX_TURNS MAX_BUDGET_USD EFFORT OUTCOME_FILE ALERT_SLACK_ID ALERT_CHANNEL_ID LEDGER_BRANCH
#      DRY_RUN RUN_ID EVENT WORKFLOW SERVER THIS_REPO MODEL_OUT GITHUB_STEP_SUMMARY   (GIT_BASE: tests only)
set -u
GIT_BASE="${GIT_BASE:-https://github.com/toniaquino}"
MODEL_OUT="${MODEL_OUT:-/tmp/model-out}"
OUT="$MODEL_OUT/claude-output.json"
if [ ! -s "$OUT" ]; then
  echo "No claude output to record (the run stopped before claude finished)."
  CLAUDE_EXIT="$(cat "$MODEL_OUT/claude-exit" 2>/dev/null || echo 'no output')"
  REC=""
else
  CLAUDE_EXIT="$(cat "$MODEL_OUT/claude-exit" 2>/dev/null || echo 0)"
  OUTCOME='{}'
  BREAKDOWN="$(cat "$MODEL_OUT/breakdown.json" 2>/dev/null)" || BREAKDOWN='{"error":"breakdown missing"}'
  echo "$BREAKDOWN" | jq -e . >/dev/null 2>&1 || BREAKDOWN='{"error":"breakdown unreadable"}'
  if [ -n "${OUTCOME_FILE:-}" ] && [ -s "$OUTCOME_FILE" ]; then
    OUTCOME="$(jq -c . "$OUTCOME_FILE" 2>/dev/null || echo '{}')"
  fi
  REC="$(jq -c --arg ts "$(date -u +%FT%TZ)" --arg wf "$WORKFLOW" --arg job "$JOB_NAME" --arg run "$RUN_ID" \
    --arg event "$EVENT" --arg model "$MODEL" --arg dry "$DRY_RUN" --arg cap "$MAX_TURNS" --arg exit "$CLAUDE_EXIT" --arg budget "$MAX_BUDGET_USD" --arg effort "$EFFORT" \
    --argjson outcome "$OUTCOME" --argjson breakdown "$BREAKDOWN" \
    '{ts: $ts, workflow: $wf, job: $job, run_id: $run, event: $event, model: $model, dry_run: ($dry != "false"),
      max_turns: (($cap | tonumber? ) // 0), max_budget_usd: (($budget | tonumber? ) // 0), effort: (if $effort == "" then null else $effort end), exit: ($exit | tonumber? // $exit), cost_usd: .total_cost_usd,
      turns: .num_turns, duration_ms: .duration_ms, is_error: (.is_error // false), subtype: (.subtype // null),
      input_tokens: .usage.input_tokens, cache_read: .usage.cache_read_input_tokens,
      cache_creation: .usage.cache_creation_input_tokens, output_tokens: .usage.output_tokens, outcome: $outcome, out: $breakdown, isolated: true}' \
    "$OUT" 2>/dev/null)" || REC=""
fi

if [ -n "$REC" ]; then
  echo "$REC"
  echo "$JOB_NAME: \$$(echo "$REC" | jq -r '.cost_usd // 0'), $(echo "$REC" | jq -r '.turns // 0') turns" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

if [ -n "$REC" ] && [ "${LEDGER_BRANCH:-}" != "none" ] && [ -n "${LEDGER_BRANCH:-}" ]; then
  AUTH_HEADER="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_PAT" | base64 -w 0)"
  rm -rf /tmp/ledger && mkdir /tmp/ledger && cd /tmp/ledger && git init -q
  git remote add origin "$GIT_BASE/$REPO_NAME.git"
  git config http.https://github.com/.extraheader "$AUTH_HEADER"
  for attempt in 1 2 3; do
    if git fetch -q --depth 1 origin "$LEDGER_BRANCH" 2>/dev/null; then
      git checkout -q -B "$LEDGER_BRANCH" FETCH_HEAD
    else
      git checkout -q --orphan "$LEDGER_BRANCH" 2>/dev/null || true
    fi
    echo "$REC" >> costs.jsonl
    git add costs.jsonl
    git -c user.name=team-kb-bot -c user.email=team-kb-bot@bynder.com commit -q -m "cost: $JOB_NAME $RUN_ID"
    if git push -q origin "$LEDGER_BRANCH" 2>/dev/null; then echo "Ledger updated ($LEDGER_BRANCH)."; break; fi
    echo "Ledger push attempt $attempt failed; retrying."; sleep $((attempt * 2))
  done
  cd /
fi

SUBTYPE=""
if [ -n "$REC" ]; then SUBTYPE="$(echo "$REC" | jq -r '.subtype // ""' 2>/dev/null)"; fi
if [ -n "${ALERT_SLACK_ID:-}" ] && [ -n "${SLACK_BOT_TOKEN:-}" ] && { [ "$CLAUDE_EXIT" != "0" ] || [ "${SUBTYPE#error}" != "$SUBTYPE" ] || [ "${FINISH_FAILED:-}" = "true" ]; }; then
  WHAT="exit $CLAUDE_EXIT"
  [ "${SUBTYPE#error}" != "$SUBTYPE" ] && WHAT="$SUBTYPE"
  [ "${FINISH_FAILED:-}" = "true" ] && [ "$CLAUDE_EXIT" = "0" ] && WHAT="the finish step failed"
  DETAIL=""
  [ -n "$REC" ] && DETAIL=" after $(echo "$REC" | jq -r '.turns // "?"') turns, \$$(echo "$REC" | jq -r '.cost_usd // "?"')"
  TEXT="Routine alert: $JOB_NAME ended with $WHAT$DETAIL. Run: $SERVER/$THIS_REPO/actions/runs/$RUN_ID"
  curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" --data-urlencode "channel=$ALERT_SLACK_ID" --data-urlencode "text=$TEXT" https://slack.com/api/chat.postMessage | jq -r 'if .ok then "Alert sent." else "Alert failed: \(.error)" end'
  if [ -n "${ALERT_CHANNEL_ID:-}" ]; then
    curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" --data-urlencode "channel=$ALERT_CHANNEL_ID" --data-urlencode "text=$TEXT" https://slack.com/api/chat.postMessage | jq -r 'if .ok then "Channel alert sent." else "Channel alert failed: \(.error)" end'
  fi
fi
exit 0
