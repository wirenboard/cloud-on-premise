#!/usr/bin/env bash
# check-env may only pass EMAIL_ENABLED spellings the backend and Grafana read the
# same way — 'ok' and 'Y' mean "on" to the cloud and "off" to Grafana.
#
#     bash tests/test-check-env.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}

setup() {
    rm -rf "$WORK/case"; mkdir -p "$WORK/case/scripts"
    cp "$ROOT/Makefile" "$ROOT/.env.example" "$ROOT/VERSION" "$WORK/case/"
    cp "$ROOT/scripts/env.sh" "$WORK/case/scripts/"
    cd "$WORK/case" || exit 1
}

verdict() { # value -> prints "rejected" or "passed"
    setup
    printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=%s\n' "$1" > .env
    local out; out="$(make check-env 2>&1 || true)"
    case "$out" in *"is not a boolean"*) echo rejected ;; *) echo passed ;; esac
}

echo "spellings the cloud and Grafana agree on"
for v in True False true false TRUE FALSE yes no Yes No on off 1 0 y; do
    check "$v is accepted" "$([ "$(verdict "$v")" = passed ]; echo $?)"
done

echo
echo "spellings that would diverge — email on for the cloud, silent in Grafana"
for v in ok OK Ok Y tRue yES; do
    check "$v is refused" "$([ "$(verdict "$v")" = rejected ]; echo $?)"
done

echo
echo "and the refusal is loud, not a silent default"
setup
printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=ok\n' > .env
out="$(make check-env 2>&1)"; rc=$?
check "check-env exits non-zero" "$([ $rc -ne 0 ]; echo $?)"
check "the message names Grafana"  "$(printf '%s' "$out" | grep -q "Grafana"; echo $?)"
check "and offers True or False"   "$(printf '%s' "$out" | grep -q "Use True or False"; echo $?)"

# An empty value is a different error (required-variable), not this one.
setup
printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=\n' > .env
out="$(make check-env 2>&1 || true)"
says() { printf '%s' "$out" | grep -q -- "$1"; }   # captured: pipefail hides grep otherwise
check "an empty value is left to the required-variable check" "$(! says "is not a boolean"; echo $?)"

echo
echo "METRICS_RETENTION_DAYS is refused before it reaches the metrics store"
retention_refused() { # value -> 0 when check-env complains about it
    setup
    printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=True\nMETRICS_RETENTION_DAYS=%s\n' "$1" > .env
    printf '%s' "$(make check-env 2>&1 || true)" | grep -q "METRICS_RETENTION_DAYS"
}
for v in 1 30 3650; do
    check "$v is accepted" "$(! retention_refused "$v"; echo $?)"
done
for v in 0 -1 3651 30d abc 30.5; do
    check "'$v' is refused" "$(retention_refused "$v"; echo $?)"
done
# Compose trims it away and falls back to the default; the check reads it the same.
check "a whitespace-only value counts as absent" "$(! retention_refused ' '; echo $?)"
setup
printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=True\n' > .env
printf '%s' "$(make check-env 2>&1 || true)" | grep -q "METRICS_RETENTION_DAYS"
check "absent means the default, not an error" "$([ $? -ne 0 ]; echo $?)"

echo
if [ "$failures" -ne 0 ]; then echo "FAILED: $failures check(s)"; exit 1; fi
echo "all checks passed"
