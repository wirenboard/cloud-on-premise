#!/usr/bin/env bash
# EMAIL_ENABLED is read twice: by the backend, and by Grafana through its config
# file. They accept different spellings, so check-env may only pass the ones both
# read the same way — 'ok' and 'Y' mean "on" to the cloud and "off" to Grafana.
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
    cp "$ROOT/scripts/lib.sh" "$WORK/case/scripts/"
    cd "$WORK/case" || exit 1
}

# The check runs before the required-variable loop, so a minimal .env is enough:
# an accepted value simply has to get past it, not to make the whole file valid.
verdict() { # value -> prints "rejected" or "passed"
    setup
    printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=%s\n' "$1" > .env
    # Captured, not piped: under pipefail a failing make would mask a matching grep.
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
check "an empty value is left to the required-variable check" \
  "$(! make check-env 2>&1 | grep -q "is not a boolean"; echo $?)"

echo
if [ "$failures" -ne 0 ]; then echo "FAILED: $failures check(s)"; exit 1; fi
echo "all checks passed"
