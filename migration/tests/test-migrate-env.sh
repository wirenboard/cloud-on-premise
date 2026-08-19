#!/usr/bin/env bash
# Runs migration/migrate-env.sh against fixture .env files in a scratch directory.
#
#     bash migration/tests/test-migrate-env.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() { # name, condition-as-exit-code
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}
has()  { grep -qxF "$2" "$1"; }        # file, exact line
val()  { grep -E "^$2=" "$1" | tail -1 | cut -d= -f2-; }

# A 1.5.0 .env: the shape migrate-env has to convert.
write_1x() {
    cat > "$1" <<'ENV'
ABSOLUTE_SERVER=cloud.example.com
ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=adminpw
EMAIL_ENABLED=True
EMAIL_PROTOCOL=smtp+tls
EMAIL_SERVER=smtp.example.com
EMAIL_PORT=587
EMAIL_LOGIN=bot@example.com
EMAIL_PASSWORD=mailpw
EMAIL_NOTIFICATIONS_FROM=bot@example.com
EMAIL_URL=smtp+tls://bot%40example.com:mailpw@smtp.example.com:587
TUNNEL_DASHBOARD_USER=tunnel_admin
TUNNEL_DASHBOARD_PASSWORD=tunnelpw
POSTGRES_DB=db
POSTGRES_USER=pguser
POSTGRES_PASSWORD=pgpw
INFLUXDB_USERNAME=influx
INFLUXDB_PASSWORD=influxpw
INFLUXDB_TOKEN=influxtoken
SECRET_KEY=django-secret
TUNNEL_AUTH_TOKEN=tunnel-token
ABSOLUTE_SERVER_REGEX=cloud\.example\.com
PRIVATE_KEY=privkey
PUBLIC_KEY=pubkey
ENV
}

setup() { # fresh scratch copy of the repo files the script touches
    rm -rf "$WORK/case"; mkdir -p "$WORK/case/scripts" "$WORK/case/migration"
    cp "$ROOT/Makefile" "$ROOT/.env.example" "$WORK/case/"
    cp "$ROOT/scripts/env.sh" "$WORK/case/scripts/"
    cp "$ROOT/migration/migrate-env.sh" "$WORK/case/migration/"
    cd "$WORK/case" || exit 1
}

echo "1.x -> 2.0 conversion"
setup; write_1x .env
bash migration/migrate-env.sh >/dev/null 2>&1; rc=$?
check "stops for the operator while values are missing" "$([ $rc -eq 1 ]; echo $?)"
check "EMAIL_SERVER -> EMAIL_HOST"        "$([ "$(val .env EMAIL_HOST)" = "smtp.example.com" ]; echo $?)"
check "EMAIL_LOGIN -> EMAIL_HOST_USER"    "$([ "$(val .env EMAIL_HOST_USER)" = "bot@example.com" ]; echo $?)"
check "EMAIL_PASSWORD -> EMAIL_HOST_PASSWORD" "$([ "$(val .env EMAIL_HOST_PASSWORD)" = "mailpw" ]; echo $?)"
check "generated secrets survive verbatim" "$([ "$(val .env SECRET_KEY)" = "django-secret" ] && [ "$(val .env TUNNEL_AUTH_TOKEN)" = "tunnel-token" ]; echo $?)"
check "the previous file is kept"          "$(ls .env.bak-* >/dev/null 2>&1; echo $?)"
check "1.x-only variables are dropped"     "$(! grep -qE '^(INFLUXDB_TOKEN|ADMIN_USERNAME|EMAIL_URL)=' .env; echo $?)"
check "the old file still has them"        "$(grep -q '^INFLUXDB_TOKEN=' .env.bak-*; echo $?)"

# The reason this file exists: a required variable that cannot be derived must be
# left EMPTY. Filling it from .env.example would ship the published default and
# check-env, seeing a value, would wave it through.
check "new required variables are left empty" "$(has .env 'GRAFANA_ADMIN_PASSWORD='; echo $?)"
check "not filled from the example"           "$(! has .env 'GRAFANA_ADMIN_PASSWORD=grafana_password'; echo $?)"

# The required-vars list is asked for, not scraped: a reformat of it in the Makefile
# used to leave every variable looking optional, which filled the new ones from the
# example instead of stopping the upgrade.
setup; write_1x .env
python3 - <<'PY'
lines = open("Makefile", encoding="utf-8").read().split("\n")
out, names, grabbing = [], [], False
for line in lines:
    if line.startswith("REQUIRED_VARS := "):
        grabbing = True
        continue
    if grabbing:
        name = line.strip().rstrip("\\").strip()
        if name:
            names.append(name)
        if not line.rstrip().endswith("\\"):
            grabbing = False
            out.append("CORE_VARS := " + " ".join(names))
            out.append("REQUIRED_VARS = $(CORE_VARS)")
        continue
    out.append(line)
open("Makefile", "w", encoding="utf-8").write("\n".join(out))
PY
make -s print-required-vars >/dev/null 2>&1
check "the reformatted Makefile is still valid" "$?"
bash migration/migrate-env.sh >/dev/null 2>&1; rc=$?
check "a reformatted list still stops the upgrade" "$([ $rc -eq 1 ]; echo $?)"
check "and still leaves the value empty" "$(has .env 'GRAFANA_ADMIN_PASSWORD='; echo $?)"

# If the list cannot be read at all, refusing is the only safe answer: treating
# everything as optional is what used to fill the new variables from the example.
setup; write_1x .env
printf 'REQUIRED_VARS := \\\n  BROKEN\n' > Makefile
out="$(bash migration/migrate-env.sh 2>&1)"; rc=$?
check "an unreadable list aborts" "$([ $rc -ne 0 ]; echo $?)"
check "and says why" "$(printf '%s' "$out" | grep -q 'required variables'; echo $?)"

echo
echo "idempotence"
setup; write_1x .env
bash migration/migrate-env.sh >/dev/null 2>&1
sed -i.bak 's/^GRAFANA_ADMIN_USER=$/GRAFANA_ADMIN_USER=ga/; s/^GRAFANA_ADMIN_PASSWORD=$/GRAFANA_ADMIN_PASSWORD=gp/' .env
cp .env .env.settled
bash migration/migrate-env.sh >/dev/null 2>&1; rc=$?
check "a settled file passes"       "$([ $rc -eq 0 ]; echo $?)"
check "and is left untouched"       "$(diff -q .env .env.settled >/dev/null; echo $?)"
check "no second backup is written" "$([ "$(ls .env.bak-* 2>/dev/null | wc -l)" -eq 1 ]; echo $?)"

echo
echo "EMAIL_PROTOCOL becomes the TLS/SSL flags"
for proto_case in "smtp+tls:True:" "smtp+ssl:False:True" "smtp:False:"; do
    proto="${proto_case%%:*}"; rest="${proto_case#*:}"
    want_tls="${rest%%:*}"; want_ssl="${rest#*:}"
    setup; write_1x .env
    sed -i.bak "s|^EMAIL_PROTOCOL=.*|EMAIL_PROTOCOL=$proto|" .env
    bash migration/migrate-env.sh >/dev/null 2>&1
    check "$proto -> EMAIL_USE_TLS=$want_tls" "$([ "$(val .env EMAIL_USE_TLS)" = "$want_tls" ]; echo $?)"
    [ -n "$want_ssl" ] && check "$proto -> EMAIL_USE_SSL=$want_ssl" "$([ "$(val .env EMAIL_USE_SSL)" = "$want_ssl" ]; echo $?)"
done

echo
echo "email switched off"
setup; write_1x .env
sed -i.bak 's/^EMAIL_ENABLED=True/EMAIL_ENABLED=False/' .env
bash migration/migrate-env.sh >/dev/null 2>&1
check "EMAIL_* are not demanded" "$(! grep -qE '^EMAIL_(HOST|PORT|NOTIFICATIONS_FROM)=$' .env; echo $?)"
check "EMAIL_ENABLED stays False" "$([ "$(val .env EMAIL_ENABLED)" = "False" ]; echo $?)"

echo
echo "a relay that takes mail without credentials"
setup; write_1x .env
# The 1.x file of such an installation simply has no login and no password.
sed -i.bak '/^EMAIL_LOGIN=/d; /^EMAIL_PASSWORD=/d' .env
bash migration/migrate-env.sh >/dev/null 2>&1
check "EMAIL_HOST_USER is left empty"     "$([ -z "$(val .env EMAIL_HOST_USER)" ]; echo $?)"
check "EMAIL_HOST_PASSWORD is left empty" "$([ -z "$(val .env EMAIL_HOST_PASSWORD)" ]; echo $?)"
check "no example credentials sneak in"   "$(! grep -qE '^EMAIL_HOST_(USER|PASSWORD)=(mymail@mail\.com|password)$' .env; echo $?)"
check "and the rest of the file is still migrated" "$([ "$(val .env EMAIL_HOST)" = "smtp.example.com" ]; echo $?)"

echo
echo "custom values outside the template"
setup; write_1x .env
echo "MY_CUSTOM_SETTING=keep-me" >> .env
bash migration/migrate-env.sh >/dev/null 2>&1
check "are carried over" "$([ "$(val .env MY_CUSTOM_SETTING)" = "keep-me" ]; echo $?)"

echo
echo "nothing to migrate"
setup
bash migration/migrate-env.sh >/dev/null 2>&1
check "no .env is not an error" "$([ $? -eq 0 ]; echo $?)"

echo
if [ "$failures" -ne 0 ]; then echo "FAILED: $failures check(s)"; exit 1; fi
echo "all checks passed"
