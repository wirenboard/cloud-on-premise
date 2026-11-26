#!/usr/bin/env bash
# make update and the version guard of run/restart: bash tests/test-update-path.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}

FAKE="$WORK/bin"
mkdir -p "$FAKE"
# ps -a: $FAKE_IMAGES, other ps: $FAKE_RUNNING (default $FAKE_IMAGES), volumes: $FAKE_VOLUMES; $FAKE_FAIL fails.
cat > "$FAKE/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [ -n "${FAKE_FAIL:-}" ]; then case "$*" in *"$FAKE_FAIL"*) exit 1 ;; esac; fi
case "$*" in
    *"exec -T postgres psql"*) cat > /dev/null; printf '%b' "${FAKE_PSQL:-}" ;;
    *"compose ps -a"*) printf '%s\n' ${FAKE_IMAGES:-} ;;
    *"compose ps"*) printf '%s\n' ${FAKE_RUNNING-${FAKE_IMAGES:-}} ;;
    *"compose config"*) printf 'name: onprem\nservices: {}\n' ;;
    "volume inspect "*) case " ${FAKE_VOLUMES:-} " in *" ${3:-} "*) ;; *) exit 1 ;; esac ;;
esac
exit 0
SH
# make: logs the target; `backup` adds a dump named after $FAKE_DUMP_TIME, as migration/upgrade.sh does.
cat > "$FAKE/fake-make" <<'SH'
#!/usr/bin/env bash
printf 'make %s%s\n' "$*" "${UPDATE_FILES_PULLED:+ (files pulled)}" >> "$CALLS"
if [ "$1" = backup ]; then mkdir -p backups && : > "backups/pg-${FAKE_DUMP_TIME:-20261126-120000}.sql.gz"; fi
SH
# git: on a branch unless $FAKE_DETACHED; `pull` fails when $FAKE_GIT_FAIL is set.
cat > "$FAKE/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$CALLS"
case "$1" in
    symbolic-ref) [ -z "${FAKE_DETACHED:-}" ] ;;
    pull) [ -z "${FAKE_GIT_FAIL:-}" ] ;;
    describe) echo v2.1.0 ;;
esac
SH
chmod +x "$FAKE"/*
export CALLS="$WORK/calls"

setup() { # VERSION of the files
    rm -rf "$WORK/case"; mkdir -p "$WORK/case/scripts" "$WORK/case/upgrade/2.1.0"
    cp "$ROOT/Makefile" "$ROOT/.env.example" "$WORK/case/"
    cp "$ROOT/scripts/env.sh" "$ROOT/scripts/update.sh" "$WORK/case/scripts/"
    cp "$ROOT/upgrade/2.1.0/logins-differ-only-by-case.sql" "$WORK/case/upgrade/2.1.0/"
    printf '%s\n' "$1" > "$WORK/case/VERSION"
    printf 'ABSOLUTE_SERVER=cloud.example.com\nEMAIL_ENABLED=False\n' > "$WORK/case/.env"
    cp "$WORK/case/.env" "$WORK/env.before"
    : > "$CALLS"
    cd "$WORK/case" || exit 1
}

img() { printf 'ghcr.io/wirenboard/on-premise/wbc-%s:%s ' backend "$1" frontend "$1"; }

echo "run, restart and run-no-cert-check refuse while another version runs"
for target in run restart run-no-cert-check; do
    setup 2.1.0
    out="$(PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.0.1) redis:7.4.12" make "$target" 2>&1)"; rc=$?
    check "make $target exits non-zero" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
    check "make $target names both versions and make update" \
        "$(printf '%s' "$out" | tr '\n' ' ' | grep -q '2\.0\.1.*2\.1\.0.*make update'; echo $?)"
    check "make $target neither stops nor starts containers" \
        "$(grep -Eq 'compose (up|down)' "$CALLS" && echo 1 || echo 0)"
    check "make $target leaves .env alone" "$(cmp -s .env "$WORK/env.before"; echo $?)"
done

echo
echo "the version guard"
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.1.0)" make check-running-version >/dev/null 2>&1
check "passes the stack of the files' version" $?
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.1.0) ghcr.io/wirenboard/on-premise/wbc-timescale-guard:pg17.11-ts2.30.2" \
    make check-running-version >/dev/null 2>&1
check "the one-shot wbc-timescale-guard, tagged after Timescale, is not a version" $?
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.1.0)" FAKE_RUNNING="" make check-running-version >/dev/null 2>&1
check "passes a stopped stack of the files' version" $?
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_IMAGES="" make check-running-version >/dev/null 2>&1
check "passes a fresh installation: no containers, no database volume" $?
setup 2.1.0
out="$(PATH="$FAKE:$PATH" FAKE_IMAGES="" FAKE_VOLUMES="onprem_postgresData" make check-running-version 2>&1)"; rc=$?
check "refuses a database with no containers and no record of the version that ran" \
    "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "tells to start the previous version with its files, then make update" \
    "$(printf '%s' "$out" | tr '\n' ' ' | grep -q 'git checkout.*make run.*make update'; echo $?)"
setup 2.1.0
printf '2.0.1\n' > .last-run-version
out="$(PATH="$FAKE:$PATH" FAKE_IMAGES="" FAKE_VOLUMES="onprem_postgresData" make check-running-version 2>&1)"; rc=$?
check "refuses a database whose last run was another version" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "names the version that ran last and the files' version" \
    "$(printf '%s' "$out" | tr '\n' ' ' | grep -q '2\.0\.1.*2\.1\.0'; echo $?)"
setup 2.1.0
printf '2.1.0\n' > .last-run-version
PATH="$FAKE:$PATH" FAKE_IMAGES="" FAKE_VOLUMES="onprem_postgresData" make check-running-version >/dev/null 2>&1
check "passes a database whose last run was the files' version" $?
setup 2.1.0
out="$(PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.0.1)" FAKE_RUNNING="" make check-running-version 2>&1)"; rc=$?
check "refuses a stopped stack of another version" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "tells to start the stopped stack with its own files before make update" \
    "$(printf '%s' "$out" | grep -qF 'git checkout v2.0.1 && make run && git checkout - && make update'; echo $?)"
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_IMAGES="redis:7.4.12 grafana/grafana:12.4.14" make check-running-version >/dev/null 2>&1
check "ignores images that are not wbc-*" $?
setup 2.1.0
check "refuses a stack with mixed versions" "$(PATH="$FAKE:$PATH" \
    FAKE_IMAGES="$(img 2.1.0) ghcr.io/wirenboard/on-premise/wbc-webssh:2.0.1" \
    make check-running-version >/dev/null 2>&1 && echo 1 || echo 0)"
setup 2.1.0-testing
check "refuses a release stack under -testing files (a redeploy is make update)" \
    "$(PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.1.0)" make check-running-version >/dev/null 2>&1 && echo 1 || echo 0)"

echo
echo "a start records its version"
for target in run run-no-cert-check restart; do
    setup 2.1.0
    PATH="$FAKE:$PATH" make "$target" MAKE=true >/dev/null 2>&1
    check "make $target records the version it started" \
        "$([ "$(cat .last-run-version 2>/dev/null)" = 2.1.0 ] && echo 0 || echo 1)"
done
setup 2.1.0
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/case/docker"; chmod +x "$WORK/case/docker"
PATH="$WORK/case:$FAKE:$PATH" make run MAKE=true >/dev/null 2>&1
check "a failed start records nothing" "$([ -e .last-run-version ] && echo 1 || echo 0)"
check "the record is ignored by git" \
    "$(git -C "$ROOT" check-ignore -q .last-run-version; echo $?)"

echo
echo "make stop keeps the containers for the version guard"
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.0.1)" FAKE_RUNNING="" make stop >/dev/null 2>&1
check "stops the services without removing them" \
    "$(grep -q 'compose stop' "$CALLS" && ! grep -q 'compose down' "$CALLS"; echo $?)"
setup 2.1.0
PATH="$FAKE:$PATH" FAKE_RUNNING="minio-id minio-client-id" make stop >/dev/null 2>&1
check "also stops what is left running: the 2.0.x MinIO the files no longer list" \
    "$(grep -qx 'stop minio-id minio-client-id' "$CALLS"; echo $?)"

echo
echo "make update from 2.0.1"
# Line of the first call matching $1 in the log, 0 when there is none.
at() { grep -n -m1 -e "$1" "$CALLS" | cut -d: -f1 | grep . || echo 0; }
in_order() { # patterns in the order the calls must come
    local prev=0 n
    for p in "$@"; do
        n="$(at "$p")"
        [ "$n" -gt "$prev" ] || return 1
        prev="$n"
    done
}
update() { PATH="$FAKE:$PATH" UPDATE_FILES_PULLED=1 make update MAKE="$FAKE/fake-make" 2>&1; }
first_pass() { PATH="$FAKE:$PATH" make update MAKE="$FAKE/fake-make" 2>&1; }

setup 2.1.0
out="$(first_pass)"; rc=$?
check "on a branch: git pull --ff-only, then make update of the pulled files" \
    "$([ $rc -eq 0 ] && in_order 'git pull --ff-only' 'make update (files pulled)'; echo $?)"
check "and nothing else in the first pass" "$(grep -Eq 'compose (pull|down|up)|make backup' "$CALLS" && echo 1 || echo 0)"
setup 2.1.0
out="$(FAKE_GIT_FAIL=1 first_pass)"; rc=$?
check "a failed git pull stops the update" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "before any change" "$(grep -Eq 'make update|compose|make backup' "$CALLS" && echo 1 || echo 0)"
setup 2.1.0
out="$(FAKE_DETACHED=1 first_pass)"; rc=$?
check "a checked-out tag: no git pull, updates to the tag" \
    "$([ $rc -eq 0 ] && ! grep -q 'git pull' "$CALLS" && grep -q 'make update (files pulled)' "$CALLS"; echo $?)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" update)"; rc=$?
check "exits zero" $rc
check "checks logins, then env, certs, pull, backup, stop, Grafana duplicates, start, metrics schema" \
    "$(in_order 'exec -T postgres psql' 'make generate-env' 'make check-certs' 'compose pull' 'make backup' \
        'compose down --remove-orphans' 'delete_duplicate_grafana_orgs --apply' \
        'compose up -d --build --remove-orphans' 'make check-metrics-schema'; echo $?)"
check "refuses 1.x before anything else" "$(in_order 'make check-not-1x' 'compose ps'; echo $?)"
check "removes Grafana duplicates with the new backend image alone, its database and Grafana up" \
    "$(in_order 'compose up -d --wait postgres clients-grafana' \
        'compose run --rm --no-deps backend uv run --no-dev ./manage.py delete_duplicate_grafana_orgs --apply'; echo $?)"
check "records the version it started" "$([ "$(cat .last-run-version 2>/dev/null)" = 2.1.0 ] && echo 0 || echo 1)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_PSQL='5 Admin\n6 admin\n' update)"; rc=$?
check "refuses logins that differ only by case" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "lists them" "$(printf '%s' "$out" | grep -qx '6 admin'; echo $?)"
check "before any change" "$(grep -Eq 'make (generate-env|backup)|compose (pull|down|up)' "$CALLS" && echo 1 || echo 0)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_FAIL='exec -T postgres' update)"; rc=$?
check "refuses when the login check cannot run" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "and changes nothing" "$(grep -Eq 'make (generate-env|backup)|compose (pull|down|up)' "$CALLS" && echo 1 || echo 0)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_FAIL='compose pull' update)"; rc=$?
check "a failed pull fails the update" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "and leaves 2.0.1 running, with no dump taken" "$(grep -Eq 'compose (down|up)|make backup' "$CALLS" && echo 1 || echo 0)"

setup 2.1.0
mkdir backups
for t in 20261101-000000 20261102-000000 20261103-000000 20261104-000000; do : > "backups/pg-$t.sql.gz"; done
: > backups/keep-me.txt
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_DUMP_TIME=20261126-130000 update)"; rc=$?
check "keeps the last 3 dumps, the new one included, and nothing else is touched" \
    "$([ "$(ls backups | tr '\n' ' ')" = "keep-me.txt pg-20261103-000000.sql.gz pg-20261104-000000.sql.gz pg-20261126-130000.sql.gz " ] && echo 0 || echo 1)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_FAIL='delete_duplicate_grafana_orgs' update)"; rc=$?
check "goes on when the Grafana cleanup fails" "$rc"
check "and tells how to run it later" "$(printf '%s' "$out" | grep -q 'delete_duplicate_grafana_orgs \[--apply\]'; echo $?)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_FAIL='up -d --build' update)"; rc=$?
check "a failed start fails the update" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "and names the dump to roll back to" "$(printf '%s' "$out" | grep -q 'backups/pg-20261126-120000.sql.gz'; echo $?)"
check "records no version" "$([ -e .last-run-version ] && echo 1 || echo 0)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_FAIL='prune' update)"; rc=$?
check "a failed prune does not stop the update halfway" "$(in_order 'compose down' 'compose up -d --build'; echo $?)"

setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1) ghcr.io/wirenboard/on-premise/wbc-timescale-guard:pg17.11-ts2.30.2" update)"; rc=$?
check "the guard image tagged after Timescale is not a version" "$rc"

echo
echo "make update refuses what it cannot switch"
setup 2.1.0
out="$(FAKE_IMAGES="" update)"; rc=$?
check "a stopped cloud" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "points a new installation to make run" "$(printf '%s' "$out" | grep -q "'make run'"; echo $?)"
check "and changes nothing" "$(grep -Eq 'make (generate-env|backup)|compose (pull|down|up)' "$CALLS" && echo 1 || echo 0)"
setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.1)" FAKE_RUNNING="" update)"; rc=$?
check "a stopped 2.0.1: tells to start it with its own files" \
    "$([ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'git checkout v2.0.1 && make run'; echo $?)"
setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.1.0)" FAKE_RUNNING="" update)"; rc=$?
check "a stopped 2.1.0, e.g. after a failed start: points to make run and the logs, not to 2.0.1" \
    "$([ $rc -ne 0 ] && printf '%s' "$out" | grep -q "start them with 'make run'" &&
       ! printf '%s' "$out" | grep -q 'git checkout'; echo $?)"
setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.0.0)" update)"; rc=$?
check "2.0.0" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "sends it through 2.0.1 first" "$(printf '%s' "$out" | grep -q 'git checkout v2.0.1 && make update'; echo $?)"
check "and changes nothing" "$(grep -Eq 'make (generate-env|backup)|compose (pull|down|up)' "$CALLS" && echo 1 || echo 0)"
setup 2.1.0
out="$(FAKE_IMAGES="$(img 2.1.0) ghcr.io/wirenboard/on-premise/wbc-webssh:2.0.1" update)"; rc=$?
check "a stack of mixed versions, named so" \
    "$([ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'several versions: 2.0.1 2.1.0'; echo $?)"

echo
echo "make update rebuilds the same release"
for pair in "2.1.0 2.1.0" "2.1.0-testing 2.1.0" "2.1.0 2.1.0-testing"; do
    read -r files running <<< "$pair"
    setup "$files"
    out="$(FAKE_IMAGES="$(img "$running")" update)"; rc=$?
    check "$running running, $files files: exits zero" "$rc"
    check "$running running, $files files: pulls, backs up and restarts" \
        "$(in_order 'compose pull' 'make backup' 'compose down --remove-orphans' 'compose up -d --build'; echo $?)"
    check "$running running, $files files: no login check, no Grafana cleanup" \
        "$(grep -Eq 'psql|delete_duplicate_grafana_orgs' "$CALLS" && echo 1 || echo 0)"
done

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
