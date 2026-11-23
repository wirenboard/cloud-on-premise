#!/usr/bin/env bash
# Needs Docker: bash tests/test-timescale-upgrade.sh (BASE_REF=v2.0.1, PROJECT=tsupgrade)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_REF="${BASE_REF:-v2.0.1}"
PROJECT="${PROJECT:-tsupgrade}"
# Under the repository: Colima shares only the home directory with its VM, and bind mounts need it.
WORK="$(mktemp -d "$ROOT/.tsupgrade.XXXXXX")"
failures=0

ORG_A=11111111-1111-1111-1111-111111111111
ORG_B=22222222-2222-2222-2222-222222222222

cleanup() {
    for p in "$PROJECT" "$PROJECT-fresh"; do
        DOCKER_NET_NAME="$p-net" docker compose -p "$p" --env-file "$WORK/env" -f "$WORK/new/docker-compose.yml" \
            down -v --remove-orphans >/dev/null 2>&1
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}
is() { [ "$1" = "$2" ]; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

mkdir -p "$WORK/old/timescale" "$WORK/new"
for f in docker-compose.yml timescale/10-apply-init.sh timescale/init.sql.tmpl; do
    git -C "$ROOT" show "$BASE_REF:$f" > "$WORK/old/$f" || exit 1
done
chmod +x "$WORK/old/timescale/10-apply-init.sh"
cp -R "$ROOT/docker-compose.yml" "$ROOT/timescale" "$WORK/new/"
cat "$ROOT/.env.example" > "$WORK/env"
printf '%s=x\n' VERSION ABSOLUTE_SERVER ABSOLUTE_SERVER_REGEX SECRET_KEY PRIVATE_KEY PUBLIC_KEY \
    TUNNEL_AUTH_TOKEN TUNNEL_DASHBOARD_USER TUNNEL_DASHBOARD_PASSWORD ADMIN_EMAIL ADMIN_PASSWORD >> "$WORK/env"

dc() { # tree project args...
    local tree="$1" project="$2"; shift 2
    DOCKER_NET_NAME="$project-net" docker compose -p "$project" --env-file "$WORK/env" -f "$WORK/$tree/docker-compose.yml" "$@"
}
su_sql() { dc "$1" "$2" exec -T timescale psql -X -tA -v ON_ERROR_STOP=1 -U timescale -d metrics -c "$3"; }
client_sql() { # tree project db sql — as an organisation-A login made the way the backend makes it
    dc "$1" "$2" exec -T -e PGPASSWORD=client_pw timescale \
        psql -X -tA -h 127.0.0.1 -U client_a -d "$3" -c "$4" 2>&1
}
init() { dc "$1" "$2" run --rm -T timescale-init 2>&1; }

leak_probes() { # tree project -> every value a client gets to see from org views
    client_sql "$1" "$2" metrics "
        CREATE FUNCTION pg_temp.peek(text, text) RETURNS boolean LANGUAGE plpgsql COST 0.0000001
          AS \$\$ BEGIN RAISE NOTICE 'peek % %', \$1, \$2; RETURN true; END \$\$;
        SELECT count(*) FROM mqtt_metrics_readable WHERE pg_temp.peek(host, value);
        SELECT count(*) FROM org_controllers WHERE pg_temp.peek(host, '');"
    client_sql "$1" "$2" metrics "SELECT count(*) FROM mqtt_metrics_readable WHERE value::int >= 0"
    client_sql "$1" "$2" metrics "SELECT count(*) FROM mqtt_metrics_readable WHERE time < now() - interval '8 days' AND value::int >= 0"
    client_sql "$1" "$2" metrics "SELECT count(*) FROM org_controllers WHERE host::int >= 0"
    client_sql "$1" "$2" metrics "SELECT count(*) FROM mqtt_metrics_topics_readable WHERE host::int >= 0"
}
stats_probes() { # tree project
    client_sql "$1" "$2" metrics "SELECT count(*) FROM pg_stat_user_tables"
    client_sql "$1" "$2" metrics "SELECT count(*) FROM pg_statio_user_tables"
    client_sql "$1" "$2" metrics "SELECT pg_stat_get_tuples_returned('pg_class'::regclass)"
}

echo "$BASE_REF store with two organisations and a compressed chunk"
dc old "$PROJECT" up -d --wait timescale >/dev/null 2>&1 || { echo "  FAIL old timescale did not start"; exit 1; }
init old "$PROJECT" >/dev/null
su_sql old "$PROJECT" "
    CALL ensure_measurement('mqtt_metrics');
    INSERT INTO auth.host_org_map(host, organization_id) VALUES ('HOSTA', '$ORG_A'), ('HOSTB', '$ORG_B');
    INSERT INTO mqtt_metrics(time, host, topic, value)
      SELECT now() - interval '10 days' + i * interval '1 minute', 'HOSTA', 'load', i::text FROM generate_series(1, 100) i
      UNION ALL
      SELECT now() - interval '10 days' + i * interval '1 minute', 'HOSTB', 'load', 'secret-b-' || i FROM generate_series(1, 100) i
      UNION ALL
      SELECT now() - i * interval '1 minute', h, 'load', CASE h WHEN 'HOSTA' THEN i::text ELSE 'secret-b-' || i END
      FROM generate_series(1, 50) i, (VALUES ('HOSTA'), ('HOSTB')) v(h);
    SELECT count(compress_chunk(c)) FROM show_chunks('mqtt_metrics', older_than => interval '8 days') c;
    CREATE ROLE client_a LOGIN PASSWORD 'client_pw';
    GRANT views_reader TO client_a;
    CALL auth.grant_org_role('client_a', '$ORG_A');
" >/dev/null 2>&1
old_version="$(su_sql old "$PROJECT" "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
rows_before="$(su_sql old "$PROJECT" "SELECT count(*) FROM mqtt_metrics")"
check "old store holds 300 rows on timescaledb $old_version" "$(is "$rows_before" 300; echo $?)"

echo
echo "negative control: on $BASE_REF a client sees other organisations"
out="$(leak_probes old "$PROJECT")"
check "a failing condition reveals organisation B's rows" "$(has "$out" secret-b- || has "$out" HOSTB; echo $?)"
out="$(stats_probes old "$PROJECT")"
check "statistics are readable" "$(! has "$out" "permission denied"; echo $?)"

echo
echo "upgrade to this tree"
dc old "$PROJECT" stop timescale >/dev/null 2>&1
dc new "$PROJECT" up -d --wait timescale >/dev/null 2>&1 || { echo "  FAIL new timescale did not start"; exit 1; }
out="$(init new "$PROJECT")"; rc=$?
check "timescale-init succeeds" "$rc"
check "timescale-init updates the extension" "$(has "$out" "ALTER EXTENSION"; echo $?)"
stale=0
for db in $(su_sql new "$PROJECT" "SELECT datname FROM pg_database WHERE datallowconn"); do
    is "$(dc new "$PROJECT" exec -T timescale psql -X -tA -U timescale -d "$db" -c \
        "SELECT installed_version = default_version FROM pg_available_extensions WHERE name = 'timescaledb'")" t \
        || stale=$((stale + 1))
done
check "timescaledb is at the image version in every database" "$(is "$stale" 0; echo $?)"
check "all 300 rows survive" "$(is "$(su_sql new "$PROJECT" "SELECT count(*) FROM mqtt_metrics")" 300; echo $?)"
check "the compressed chunk is still compressed and readable" "$([ "$(su_sql new "$PROJECT" "
    SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name = 'mqtt_metrics' AND is_compressed")" -ge 1 ] \
    && is "$(su_sql new "$PROJECT" "SELECT count(*) FROM mqtt_metrics WHERE time < now() - interval '8 days'")" 200; echo $?)"

out="$(init new "$PROJECT")"; rc=$?
check "a repeated timescale-init succeeds" "$rc"
check "a repeated timescale-init does not touch the extension" "$(! has "$out" "ALTER EXTENSION"; echo $?)"

echo
echo "a client of organisation A after the upgrade"
check "reads its own rows only" "$(is "$(client_sql new "$PROJECT" metrics "SELECT count(*) FROM mqtt_metrics_readable")" 150; echo $?)"
out="$(leak_probes new "$PROJECT")"
check "no error reveals organisation B's rows" "$(! has "$out" secret-b- && ! has "$out" HOSTB; echo $?)"
out="$(stats_probes new "$PROJECT")"
check "every statistics probe is refused" "$(is "$(printf '%s\n' "$out" | grep -c "permission denied")" 3; echo $?)"
check "readable views keep the newest rows first" "$(is "$(su_sql new "$PROJECT" "
    SELECT count(*) FROM pg_views WHERE viewname IN ('mqtt_metrics_readable', 'mqtt_metrics_numeric_readable') AND definition ~ 'ORDER BY \"?time\"? DESC'")" 2; echo $?)"

echo
echo "a public view readable by clients without security_barrier stops timescale-init"
su_sql new "$PROJECT" "CREATE VIEW public.legacy_view AS SELECT host FROM auth.host_org_map; GRANT SELECT ON public.legacy_view TO views_reader" >/dev/null 2>&1
out="$(init new "$PROJECT")"; rc=$?
check "timescale-init fails and names the view" "$([ "$rc" -ne 0 ] && has "$out" legacy_view; echo $?)"
su_sql new "$PROJECT" "DROP VIEW public.legacy_view" >/dev/null 2>&1

echo
echo "fresh install of this tree"
dc new "$PROJECT-fresh" up -d --wait timescale >/dev/null 2>&1 || { echo "  FAIL fresh timescale did not start"; exit 1; }
init new "$PROJECT-fresh" >/dev/null; rc=$?
check "timescale-init succeeds on a fresh volume" "$rc"
su_sql new "$PROJECT-fresh" "CREATE ROLE client_a LOGIN PASSWORD 'client_pw'; GRANT views_reader TO client_a" >/dev/null 2>&1
out="$(stats_probes new "$PROJECT-fresh")"
check "statistics are refused to a client" "$(is "$(printf '%s\n' "$out" | grep -c "permission denied")" 3; echo $?)"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
