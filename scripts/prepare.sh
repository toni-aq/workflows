#!/usr/bin/env bash
# Isolated runner path, step 1: clone the target repo, run the duplicate-run guard, run the pre-fetch script.
# This is the only step before the model that holds secrets. It ends by removing the git credential from the clone,
# so the model step (which has no secrets either) cannot read it.
#
# Env: GH_PAT REPO_NAME PRE_SCRIPT DEDUPE_HOURS FORCE_RUN DRY_RUN LEDGER_BRANCH WORKFLOW JOB_NAME OUT_DIR
#      ALERT_SLACK_ID SLACK_BOT_TOKEN GITHUB_OUTPUT   (REPO_REF: test only, a branch to clone instead of the default)
#        (GIT_BASE: tests only, default https://github.com/toniaquino)
# Writes base_sha (the commit the model starts from) and skip=true|false (duplicate-run guard) to $GITHUB_OUTPUT.
set -eu
GIT_BASE="${GIT_BASE:-https://github.com/toniaquino}"
REPO_DIR="/tmp/$REPO_NAME"
AUTH_HEADER="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_PAT" | base64 -w 0)"
git -c http.extraheader="$AUTH_HEADER" clone --depth 1 ${REPO_REF:+--branch "$REPO_REF"} "$GIT_BASE/$REPO_NAME.git" "$REPO_DIR"
git -C "$REPO_DIR" config http.https://github.com/.extraheader "$AUTH_HEADER"
echo "base_sha=$(git -C "$REPO_DIR" rev-parse HEAD)" >> "$GITHUB_OUTPUT"

# Duplicate-run guard: a second live run of the same workflow within DEDUPE_HOURS is skipped before any model cost.
if [ -n "${DEDUPE_HOURS:-}" ] && [ "$DEDUPE_HOURS" != "0" ] && [ "${FORCE_RUN:-}" != "true" ] && [ "$DRY_RUN" = "false" ] \
   && [ -n "${LEDGER_BRANCH:-}" ] && [ "$LEDGER_BRANCH" != "none" ]; then
  CUTOFF="$(date -u -d "$DEDUPE_HOURS hours ago" +%Y-%m-%dT%H:%M:%SZ)"
  PRIOR=""
  if git -C "$REPO_DIR" fetch -q --depth 1 origin "$LEDGER_BRANCH" 2>/dev/null; then
    PRIOR="$(git -C "$REPO_DIR" show FETCH_HEAD:costs.jsonl 2>/dev/null \
      | jq -rs --arg wf "$WORKFLOW" --arg cutoff "$CUTOFF" \
        '[.[] | select(.workflow == $wf and .dry_run == false and .exit == 0 and (.ts >= $cutoff))] | last | if . then "\(.ts) run \(.run_id)" else empty end' 2>/dev/null)" || PRIOR=""
  fi
  if [ -n "$PRIOR" ]; then
    echo "SKIPPED (duplicate-run guard): $JOB_NAME already finished a live run in the last $DEDUPE_HOURS hours ($PRIOR). No model call was made. Re-run with force ticked to override."
    echo "skip=true" >> "$GITHUB_OUTPUT"
    if [ -n "${ALERT_SLACK_ID:-}" ] && [ -n "${SLACK_BOT_TOKEN:-}" ]; then
      curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" --data-urlencode "channel=$ALERT_SLACK_ID" \
        --data-urlencode "text=Skipped duplicate run: $JOB_NAME already ran live ($PRIOR) in the last $DEDUPE_HOURS hours. Re-run with force ticked to override." \
        https://slack.com/api/chat.postMessage | jq -r 'if .ok then "Skip notice sent." else "Skip notice failed: \(.error)" end'
    fi
    exit 0
  fi
fi
echo "skip=false" >> "$GITHUB_OUTPUT"

if [ -n "${PRE_SCRIPT:-}" ]; then
  echo "----- pre-script: $PRE_SCRIPT -----"
  bash "$REPO_DIR/$PRE_SCRIPT" || echo "pre-script exited non-zero; continuing (the prompt should fall back)"
fi

mkdir -p "${OUT_DIR:-/tmp/squad-out}"
git -C "$REPO_DIR" config --unset-all http.https://github.com/.extraheader || true
echo "Prepared $REPO_DIR; the git credential was removed from the clone."
