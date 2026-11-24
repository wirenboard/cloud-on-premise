#!/usr/bin/env bash
# make update hands over to wb-onprem; run/restart refuse a stack of another version;
# the release manifest has the shape wb-onprem reads: bash tests/test-update-path.sh
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
# docker: `compose ps -a` prints the images in $FAKE_IMAGES, `compose ps --status running`
# the containers in $FAKE_RUNNING (all of $FAKE_IMAGES by default), `volume inspect` finds
# only the volumes in $FAKE_VOLUMES of the project "onprem"; every call is logged.
cat > "$FAKE/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
    *"compose ps"*"--status running"*) printf '%s\n' ${FAKE_RUNNING-${FAKE_IMAGES:-}} ;;
    *"compose ps"*) printf '%s\n' ${FAKE_IMAGES:-} ;;
    *"compose config"*) printf 'name: onprem\nservices: {}\n' ;;
    "volume inspect "*) case " ${FAKE_VOLUMES:-} " in *" ${3:-} "*) ;; *) exit 1 ;; esac ;;
esac
exit 0
SH
cat > "$FAKE/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$CALLS"
exec "$@"
SH
cat > "$FAKE/wb-onprem" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >> "$CALLS"
SH
chmod +x "$FAKE"/*
export CALLS="$WORK/calls"
# make update calls sudo only when it does not already run as root; the fake logs its own path.
AS_ROOT="sudo "; [ "$(id -u)" -eq 0 ] && AS_ROOT=""

setup() { # VERSION of the files
    rm -rf "$WORK/case"; mkdir -p "$WORK/case/scripts"
    cp "$ROOT/Makefile" "$ROOT/.env.example" "$WORK/case/"
    cp "$ROOT/scripts/env.sh" "$WORK/case/scripts/"
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
mkdir backups && printf '{\n  "version": "2.1.0",\n  "commit": "%040d"\n}\n' 0 > backups/installed.json
PATH="$FAKE:$PATH" FAKE_IMAGES="" FAKE_VOLUMES="onprem_postgresData" make check-running-version >/dev/null 2>&1
check "takes the version wb-onprem installed last as the record" $?
setup 2.1.0
printf '2.1.0\n' > .last-run-version
mkdir backups && printf '{\n  "version": "2.0.1",\n  "commit": "%040d"\n}\n' 0 > backups/installed.json
touch -t 200001010000 .last-run-version
check "takes the newer of the two records (a restore by wb-onprem after a run)" "$(PATH="$FAKE:$PATH" \
    FAKE_IMAGES="" FAKE_VOLUMES="onprem_postgresData" make check-running-version >/dev/null 2>&1 && echo 1 || echo 0)"
setup 2.1.0
out="$(PATH="$FAKE:$PATH" FAKE_IMAGES="$(img 2.0.1)" FAKE_RUNNING="" make check-running-version 2>&1)"; rc=$?
check "refuses a stopped stack of another version" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "tells to start the stopped stack as it was before make update" \
    "$(printf '%s' "$out" | tr '\n' ' ' | grep -q 'docker compose start.*make update'; echo $?)"
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
echo "make update hands over to wb-onprem"
setup 2.1.0
PATH="$FAKE:$PATH" make update >/dev/null 2>&1
check "exits zero when wb-onprem does" $?
check "runs wb-onprem update as root by its full path, for this directory" \
    "$(grep -qx "${AS_ROOT}$FAKE/wb-onprem update --dir $WORK/case" "$CALLS"; echo $?)"
check "does not answer the confirmation on its own" "$(grep -q -- '--yes' "$CALLS" && echo 1 || echo 0)"
check "neither pulls nor stops containers itself" "$(grep -Eq 'compose (pull|up|down)' "$CALLS" && echo 1 || echo 0)"
setup 2.1.0
PATH="$FAKE:$PATH" make update WB_ONPREM_UPDATE_FLAGS="--yes --redeploy" >/dev/null 2>&1
check "passes --yes and --redeploy only from WB_ONPREM_UPDATE_FLAGS" \
    "$(grep -qx "${AS_ROOT}$FAKE/wb-onprem update --dir $WORK/case --yes --redeploy" "$CALLS"; echo $?)"

setup 2.1.0
printf '#!/usr/bin/env bash\nexit 2\n' > "$FAKE/wb-onprem"
check "fails when wb-onprem refuses" "$(PATH="$FAKE:$PATH" make update >/dev/null 2>&1 && echo 1 || echo 0)"

setup 2.1.0
rm "$FAKE/wb-onprem"
if command -v wb-onprem >/dev/null 2>&1; then
    echo "  skip without wb-onprem: one is installed on this machine"
else
    out="$(PATH="$FAKE:$PATH" make update 2>&1)"; rc=$?
    check "without wb-onprem fails" "$([ $rc -ne 0 ] && echo 0 || echo 1)"
    check "without wb-onprem points to its releases" \
        "$(printf '%s' "$out" | grep -q 'github.com/wirenboard/wb-onprem-cli/releases'; echo $?)"
    check "without wb-onprem touches nothing" "$([ -s "$CALLS" ] && echo 1 || echo 0)"
fi

echo
echo "the 2.1.0 manifest"
python3 -I - "$ROOT" <<'PY' || failures=$((failures + 1))
import json, os, posixpath, sys

root = sys.argv[1]
failures = 0
def check(name, ok):
    global failures
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    failures += not ok

m = json.load(open(os.path.join(root, "upgrade/2.1.0/manifest.json")))
check("format 1, version 2.1.0, min_cli 0.2.0",
      (m.get("format"), m.get("version"), m.get("min_cli")) == (1, "2.1.0", "0.2.0"))
check("updates only from 2.0.1 up to 2.1.0", m.get("upgrade_from") == ">=2.0.1,<2.1.0")
checks = m.get("checks", [])
check("has the login check", [c.get("id") for c in checks] == ["logins-differ-only-by-case"])
for c in checks:
    check(f"{c['id']}: every field wb-onprem requires is a non-empty string",
          all(isinstance(c.get(k), str) and c[k] for k in ("id", "type", "database", "file", "message", "hint")))
    check(f"{c['id']}: sql on the main database", (c["type"], c["database"]) == ("sql", "main"))
    check(f"{c['id']}: its file lies in upgrade/2.1.0/ and exists",
          posixpath.normpath(c["file"]) == c["file"] and c["file"].startswith("upgrade/2.1.0/")
          and os.path.isfile(os.path.join(root, c["file"])))
sys.exit(1 if failures else 0)
PY

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
