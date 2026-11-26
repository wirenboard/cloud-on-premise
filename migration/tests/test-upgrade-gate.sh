#!/usr/bin/env bash
# `make run` / `update` / `restart` must refuse while the installation is on 1.x.
#
#     bash migration/tests/test-upgrade-gate.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}

setup() {
    rm -rf "$WORK/case"; mkdir -p "$WORK/case"
    mkdir -p "$WORK/case/scripts"
    cp "$ROOT/Makefile" "$ROOT/.env.example" "$ROOT/VERSION" "$WORK/case/"
    cp "$ROOT/scripts/env.sh" "$WORK/case/scripts/"
    cd "$WORK/case" || exit 1
}

# The signature of a configuration that has not been through migrate-env yet.
for leftover in INFLUXDB_TOKEN ADMIN_USERNAME EMAIL_PROTOCOL; do
    setup
    printf 'ABSOLUTE_SERVER=cloud.example.com\n%s=x\n' "$leftover" > .env
    out="$(make check-not-1x 2>&1)"; rc=$?
    check "$leftover in .env blocks the start" "$([ $rc -ne 0 ]; echo $?)"
    check "$leftover: the message names 'make upgrade'" "$(printf '%s' "$out" | grep -q "make upgrade"; echo $?)"
done

# A configuration migrate-env has already converted must not be blocked: by then
# the 1.x names are gone, which is what lets `make update` work after the upgrade.
setup
printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_HOST=smtp.example.com\nGRAFANA_ADMIN_USER=ga\n' > .env
make check-not-1x >/dev/null 2>&1
check "a migrated .env is let through" "$?"

setup
check "no .env at all is let through" "$(make check-not-1x >/dev/null 2>&1; echo $?)"

# The names must only count as a signature when they are live settings.
setup
printf 'ABSOLUTE_SERVER=cloud.example.com\n#INFLUXDB_TOKEN=old\n' > .env
check "a commented-out leftover does not block" "$(make check-not-1x >/dev/null 2>&1; echo $?)"

# An upgrade that stopped after its backup leaves the database possibly
# half-migrated: starting the stack on top of that is the worst case of all.
setup
printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_HOST=smtp.example.com\n' > .env
mkdir -p backups && : > backups/.upgrade-unfinished
out="$(make check-not-1x 2>&1)"; rc=$?
check "an interrupted upgrade blocks the start" "$([ $rc -ne 0 ]; echo $?)"
check "the message offers to finish it" "$(printf '%s' "$out" | grep -q "make upgrade"; echo $?)"
check "and points at the rollback" "$(printf '%s' "$out" | grep -q "RELEASE_NOTES_2.0.md"; echo $?)"
rm -f backups/.upgrade-unfinished
check "clearing the marker unblocks it" "$(make check-not-1x >/dev/null 2>&1; echo $?)"

# The rollback documents that removal, or the operator is stuck with the marker.
check "the rollback clears the marker" \
  "$(grep -q 'rm -f backups/.upgrade-unfinished' "$ROOT/migration/RELEASE_NOTES_2.0.md"; echo $?)"
check "the English rollback too" \
  "$(grep -q 'rm -f backups/.upgrade-unfinished' "$ROOT/migration/RELEASE_NOTES_2.0_EN.md"; echo $?)"

# upgrade.sh has to both raise and clear it, or the guard is either dead or permanent.
check "upgrade.sh raises the marker after the backup" \
  "$(grep -q ': > "$UPGRADE_MARKER"' "$ROOT/migration/upgrade.sh"; echo $?)"
check "upgrade.sh clears it when done" \
  "$(grep -q 'rm -f "$UPGRADE_MARKER"' "$ROOT/migration/upgrade.sh"; echo $?)"

# One source for the name, or the two sides drift apart.
check "the marker name is defined in env.sh" \
  "$(grep -q '^UPGRADE_MARKER=' "$ROOT/scripts/env.sh"; echo $?)"
check "and is not spelled out anywhere else" \
  "$(! grep -rl 'backups/\.upgrade-unfinished' "$ROOT/Makefile" "$ROOT/migration/upgrade.sh" >/dev/null 2>&1; echo $?)"

# The guard has to sit on every target that starts the stack.
setup
for target in run run-no-cert-check update restart; do
    check "$target depends on the guard" \
      "$(awk -v t="^$target:$" '$0 ~ t {f=1; next} f && /^[a-z]/ {exit} f && /check-not-1x/ {found=1} END {exit !found}' "$ROOT/Makefile"; echo $?)"
done
check "stop is not gated" \
  "$(awk '/^stop:/{f=1; next} f && /^[a-z]/{exit} f && /check-not-1x/{found=1} END {exit found}' "$ROOT/Makefile"; echo $?)"

echo
if [ "$failures" -ne 0 ]; then echo "FAILED: $failures check(s)"; exit 1; fi
echo "all checks passed"
