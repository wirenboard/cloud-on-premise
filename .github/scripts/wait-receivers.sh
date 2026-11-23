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
  if [[ "$out" == *"HTTP 403"* || "$out" == *"HTTP 404"* ]]; then
    API_ERROR="GHCR_TOKEN needs Actions: read in $OWNER/$repo ($out)"
  else
    API_ERROR="gh api failed: $out"
  fi
}

RUN_ID=()
URL=()
RESULT=()
for i in "${!REPOS[@]}"; do
  RUN_ID[i]=""
  URL[i]="—"
  RESULT[i]=""
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
        RESULT[i]="$API_ERROR"
        continue
      fi
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
      RESULT[i]="$API_ERROR"
    elif [[ "${state%% *}" == "completed" ]]; then
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
