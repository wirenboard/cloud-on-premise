#!/usr/bin/env bash
# Usage: wait-receivers.sh SINCE REPO...  (SINCE is an ISO-8601 UTC time taken before the dispatch)
set -euo pipefail

SINCE="$1"
shift
REPOS=("$@")
OWNER="${OWNER:-wirenboard}"
WORKFLOW="${WORKFLOW:-build_onpremise_dispatch.yml}"
POLL="${POLL:-30}"
START_TIMEOUT="${START_TIMEOUT:-300}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3600}"
API_ATTEMPTS="${API_ATTEMPTS:-3}"

# Leaves the answer in API_OUT or the reason in API_ERROR instead of aborting, so the summary is always written.
api() {
  local out
  API_OUT=""
  API_ERROR=""
  if out=$(gh api "$@" 2>&1); then
    API_OUT="$out"
    return
  fi
  out="${out//$'\n'/ }"
  out="${out//|//}"
  if [[ "$out" == *"rate limit"* ]]; then
    API_ERROR="GitHub API rate limit in $OWNER/$repo ($out)"
  elif [[ "$out" == *"HTTP 403"* || "$out" == *"HTTP 404"* ]]; then
    API_ERROR="GHCR_TOKEN lacks Actions: read or $WORKFLOW is missing in $OWNER/$repo ($out)"
  else
    API_ERROR="gh api failed: $out"
  fi
}

# Retries the call on the next polls; the repository fails after API_ATTEMPTS failures in a row.
api_failed() {
  FAILS[$1]=$((FAILS[$1] + 1))
  if ((FAILS[$1] >= API_ATTEMPTS)); then
    RESULT[$1]="$API_ERROR"
  else
    waiting=1
  fi
}

RUN_ID=()
URL=()
RESULT=()
FAILS=()
for i in "${!REPOS[@]}"; do
  RUN_ID[i]=""
  URL[i]="—"
  RESULT[i]=""
  FAILS[i]=0
done

started=$(date +%s)
while true; do
  elapsed=$(($(date +%s) - started))
  waiting=0
  for i in "${!REPOS[@]}"; do
    [[ -z "${RESULT[i]}" ]] || continue
    repo="${REPOS[i]}"
    if [[ -z "${RUN_ID[i]}" ]]; then
      # The dispatch API returns no run id: take the oldest receiver run created after SINCE.
      api "repos/$OWNER/$repo/actions/workflows/$WORKFLOW/runs?event=repository_dispatch&created=%3E%3D$SINCE&per_page=100" \
        --jq '.workflow_runs | sort_by(.created_at) | first // empty | "\(.id) \(.html_url)"'
      run="$API_OUT"
      if [[ -n "$API_ERROR" ]]; then
        api_failed "$i"
        continue
      fi
      FAILS[i]=0
      if [[ -z "$run" ]]; then
        if ((elapsed > START_TIMEOUT)); then
          RESULT[i]="not started"
        else
          waiting=1
        fi
        continue
      fi
      RUN_ID[i]="${run%% *}"
      URL[i]="${run#* }"
    fi
    api "repos/$OWNER/$repo/actions/runs/${RUN_ID[i]}" --jq '"\(.status) \(.conclusion // "")"'
    state="$API_OUT"
    if [[ -n "$API_ERROR" ]]; then
      api_failed "$i"
      continue
    fi
    FAILS[i]=0
    if [[ "${state%% *}" == "completed" ]]; then
      RESULT[i]="${state#* }"
    elif ((elapsed > RUN_TIMEOUT)); then
      RESULT[i]="timed out (${state%% *})"
    else
      waiting=1
    fi
  done
  ((waiting)) || break
  sleep "$POLL"
done

failed=0
table="| repository | result | run |"$'\n'"|---|---|---|"
for i in "${!REPOS[@]}"; do
  [[ "${RESULT[i]}" == "success" ]] || failed=1
  echo "${REPOS[i]}: ${RESULT[i]} ${URL[i]}"
  table+=$'\n'"| ${REPOS[i]} | ${RESULT[i]} | ${URL[i]} |"
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### Image builds in product repositories\n\n%s\n\n' "$table" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
