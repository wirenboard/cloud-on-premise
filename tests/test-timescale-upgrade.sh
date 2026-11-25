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
TIMESCALE_IMAGE="$(sed -nE 's#^ +image: (timescale/timescaledb-ha:[^ ]+)$#\1#p' "$ROOT/docker-compose.yml" | sort -u)"
GUARD_IMAGE="$(sed -nE 's#^ +image: (.+/wbc-timescale-guard:[^ ]+)$#\1#p' "$ROOT/docker-compose.yml")"
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
# Organisation B's host, so a plan or its row estimate tells a client how much B has.
EXPLAINED="SELECT * FROM mqtt_metrics_readable WHERE host = 'HOSTB'"
explain_probes() { # tree project -> a plan or an error from each way to run EXPLAIN
    client_sql "$1" "$2" metrics "EXPLAIN $EXPLAINED"
    client_sql "$1" "$2" metrics "EXPLAIN ANALYZE $EXPLAINED"
    client_sql "$1" "$2" metrics "PREPARE q AS $EXPLAINED; EXPLAIN EXECUTE q"
    client_sql "$1" "$2" metrics "DO \$\$ DECLARE r text; BEGIN
        FOR r IN EXECUTE 'EXPLAIN ANALYZE $(printf '%s' "$EXPLAINED" | sed "s/'/''/g")' LOOP RAISE NOTICE '%', r; END LOOP; END \$\$"
    client_sql "$1" "$2" metrics "
        CREATE FUNCTION pg_temp.plan() RETURNS SETOF text LANGUAGE plpgsql
          AS \$\$ BEGIN RETURN QUERY EXECUTE 'EXPLAIN $(printf '%s' "$EXPLAINED" | sed "s/'/''/g")'; END \$\$;
        SELECT pg_temp.plan()"
}
debug_plan_probes() { # tree project -> the planner's tree sent as LOG messages
    client_sql "$1" "$2" metrics "SET client_min_messages = debug5; SET debug_print_plan = on; $EXPLAINED"
    client_sql "$1" "$2" metrics "SELECT set_config('client_min_messages', 'log', false), set_config('debug_print_parse', 'on', false),
        set_config('debug_print_rewritten', 'on', false); $EXPLAINED"
}
ORG_A_ROLE="org_${ORG_A//-/_}"
TABLE_QUERY="SELECT count(*) FROM mqtt_metrics WHERE host = 'HOSTB'"
set_role_probes() { # tree project -> what a client gets after switching to its organisation role; the table is planned before it is refused
    client_sql "$1" "$2" metrics "SET ROLE $ORG_A_ROLE; SET client_min_messages = debug5; SET debug_print_plan = on; $TABLE_QUERY"
    client_sql "$1" "$2" metrics "SET ROLE $ORG_A_ROLE; EXPLAIN $TABLE_QUERY"
}
definer_probe() { # tree project -> what a client gets from the owner's query in a SECURITY DEFINER function
    su_sql "$1" "$2" "CREATE FUNCTION public.definer_probe() RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
        AS \$\$ BEGIN RETURN ($TABLE_QUERY); END \$\$;
        GRANT EXECUTE ON FUNCTION public.definer_probe() TO client_a" >/dev/null
    client_sql "$1" "$2" metrics "SET client_min_messages = debug5; SET debug_print_plan = on; SELECT public.definer_probe()"
    su_sql "$1" "$2" "DROP FUNCTION public.definer_probe()" >/dev/null
}
# Statistics a client must not reach, and which of them the caller can.
STATS_GRANTS="SELECT coalesce(string_agg(o, ',' ORDER BY o), '') FROM (
    SELECT proname::text FROM pg_proc
    WHERE proname IN ('pg_stat_statements', 'pg_stat_statements_info', 'chunk_statistics') AND has_function_privilege(oid, 'EXECUTE')
    UNION ALL
    SELECT 'stat_chunk_activity' WHERE has_table_privilege(to_regclass('timescaledb_information.stat_chunk_activity'), 'SELECT')) s(o)"
grafana_sql() { # tree project sql
    dc "$1" "$2" exec -T -e PGPASSWORD=grafana_timescale_password timescale \
        psql -X -tA -h 127.0.0.1 -U grafana -d metrics -c "$3" 2>&1
}
CREATE_IN_PUBLIC="CREATE FUNCTION public.x() RETURNS int LANGUAGE sql AS 'SELECT 1'"
denied_explains() { printf '%s\n' "$1" | grep -c "permission denied to run EXPLAIN"; }
guard_checks() { # tree project -- what a client and the service roles may do in a store with the guard
    local out
    out="$(explain_probes "$1" "$2")"
    check "EXPLAIN, EXPLAIN ANALYZE, EXPLAIN EXECUTE and EXPLAIN in DO are refused to a client" \
        "$(is "$(denied_explains "$out")" 4; echo $?)"
    check "a client cannot create a pg_temp function to run EXPLAIN in" \
        "$(has "$out" "permission denied to create temporary tables"; echo $?)"
    check "no plan reaches a client" "$(! has "$out" "rows=" && ! has "$out" "Rows Removed"; echo $?)"
    out="$(debug_plan_probes "$1" "$2")"
    check "debug_print_* send no plan tree to a client" "$(! has "$out" ":rtable" && ! has "$out" "plan_rows"; echo $?)"
    check "and the client's query still runs" "$(! has "$out" ERROR; echo $?)"
    check "a client cannot create temporary tables" \
        "$(has "$(client_sql "$1" "$2" metrics "CREATE TEMP TABLE t(x int)")" "permission denied"; echo $?)"
    check "a client cannot connect to template1" \
        "$(has "$(client_sql "$1" "$2" template1 "SELECT 1")" "permission denied for database"; echo $?)"
    check "a client at debug5 receives no LOG message" "$(! has "$(debug_plan_probes "$1" "$2")" "LOG:"; echo $?)"
    out="$(set_role_probes "$1" "$2")"
    check "after SET ROLE to its organisation role a client gets no plan tree" "$(! has "$out" "plan_rows" && ! has "$out" "LOG:"; echo $?)"
    check "after SET ROLE to its organisation role EXPLAIN is still refused" "$(has "$out" "permission denied to run EXPLAIN"; echo $?)"
    check "a SECURITY DEFINER function sends a client no plan of the owner's query" \
        "$(out="$(definer_probe "$1" "$2")"; ! has "$out" ERROR && ! has "$out" "plan_rows"; echo $?)"
    check "a client cannot create a function in public" \
        "$(has "$(client_sql "$1" "$2" metrics "$CREATE_IN_PUBLIC")" "permission denied for schema public"; echo $?)"
    check "a client cannot run ensure_measurement" \
        "$(has "$(client_sql "$1" "$2" metrics "CALL ensure_measurement('mqtt_metrics')")" "permission denied for procedure"; echo $?)"
    check "a client cannot execute populate_mqtt_metrics_dimensions" \
        "$(is "$(su_sql "$1" "$2" "SELECT has_function_privilege('client_a', 'public.populate_mqtt_metrics_dimensions()', 'EXECUTE')")" f; echo $?)"
    check "telegraf writes a metric into a new chunk through the dimensions trigger" "$(has "$(su_sql "$1" "$2" "BEGIN;
        INSERT INTO auth.host_org_map(host, organization_id) VALUES ('HOSTPROBE', '$ORG_A');
        SET LOCAL ROLE telegraf;
        INSERT INTO mqtt_metrics(time, host, topic, value) VALUES (now() + interval '30 days', 'HOSTPROBE', 'load', '1') RETURNING organization_id;
        ROLLBACK" 2>&1)" "$ORG_A"; echo $?)"
    check "a client cannot read TimescaleDB or pg_stat_statements statistics" "$(is "$(client_sql "$1" "$2" metrics "$STATS_GRANTS")" ""; echo $?)"
    check "the exporter role reads them and creates a temporary table" "$(out="$(su_sql "$1" "$2" "SET ROLE ts_exporter; $STATS_GRANTS")"
        has "$out" "pg_stat_statements" && has "$(su_sql "$1" "$2" "SET ROLE ts_exporter; CREATE TEMP TABLE t(x int)" 2>&1)" "CREATE TABLE"; echo $?)"
    check "telegraf runs ensure_measurement and creates a temporary table" \
        "$(su_sql "$1" "$2" "SET ROLE telegraf; CALL ensure_measurement('mqtt_metrics'); CREATE TEMP TABLE t(x int)" >/dev/null 2>&1; echo $?)"
    check "timescale sends LOG messages to its log, where the guard sees them" \
        "$(is "$(su_sql "$1" "$2" "SHOW log_min_messages")" warning; echo $?)"
    check "the superuser gets a plan" "$(has "$(su_sql "$1" "$2" "EXPLAIN $EXPLAINED")" "rows="; echo $?)"
    check "the Grafana role gets a plan and a temporary table" "$(has "$(grafana_sql "$1" "$2" "EXPLAIN $EXPLAINED")" "rows=" \
        && has "$(grafana_sql "$1" "$2" "CREATE TEMP TABLE t(x int)")" "CREATE TABLE"; echo $?)"
}

stats_probes() { # tree project
    client_sql "$1" "$2" metrics "SELECT count(*) FROM pg_stat_user_tables"
    client_sql "$1" "$2" metrics "SELECT count(*) FROM pg_statio_user_tables"
    client_sql "$1" "$2" metrics "SELECT pg_stat_get_tuples_returned('pg_class'::regclass)"
}

echo "the EXPLAIN guard image"
check "is tagged as the timescale image it is built against" "$([[ "${GUARD_IMAGE##*:}" =~ ^"${TIMESCALE_IMAGE##*:}"(-r[0-9]+)?$ ]]; echo $?)"
docker build -q --build-arg TIMESCALE_IMAGE="$TIMESCALE_IMAGE" -t "$GUARD_IMAGE" "$ROOT/explain-guard" >/dev/null
check "builds" "$?"

echo
echo "$BASE_REF store with two organisations and a compressed chunk"
dc old "$PROJECT" up -d --wait timescale >/dev/null 2>&1 || { echo "  FAIL old timescale did not start"; exit 1; }
# PUBLIC keeps CREATE on public in a store upgraded from PostgreSQL 14 or granted it by hand.
su_sql old "$PROJECT" "GRANT CREATE ON SCHEMA public TO PUBLIC" >/dev/null
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
out="$(explain_probes old "$PROJECT")"
check "every way to run EXPLAIN shows a plan" "$(is "$(printf '%s\n' "$out" | grep -c "Result  (cost")" 5; echo $?)"
check "EXPLAIN ANALYZE counts organisation B's rows" "$(has "$out" "Rows Removed by Filter: 50"; echo $?)"
check "debug_print_* send the plan tree" "$(has "$(debug_plan_probes old "$PROJECT")" "plan_rows"; echo $?)"
check "a client creates temporary tables" "$(has "$(client_sql old "$PROJECT" metrics "CREATE TEMP TABLE t(x int)")" "CREATE TABLE"; echo $?)"
check "a client connects to template1" "$(is "$(client_sql old "$PROJECT" template1 "SELECT 1")" 1; echo $?)"
check "a client creates a function in public" "$(has "$(client_sql old "$PROJECT" metrics "$CREATE_IN_PUBLIC")" "CREATE FUNCTION"; echo $?)"
su_sql old "$PROJECT" "DROP FUNCTION IF EXISTS public.x()" >/dev/null

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
guard_checks new "$PROJECT"
check "readable views keep the newest rows first" "$(is "$(su_sql new "$PROJECT" "
    SELECT count(*) FROM pg_views WHERE viewname IN ('mqtt_metrics_readable', 'mqtt_metrics_numeric_readable') AND definition ~ 'ORDER BY \"?time\"? DESC'")" 2; echo $?)"

echo
echo "the guard after a restart of timescale alone"
dc new "$PROJECT" restart timescale >/dev/null 2>&1
for _ in $(seq 60); do su_sql new "$PROJECT" "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
check "EXPLAIN is still refused to a client" "$(is "$(denied_explains "$(explain_probes new "$PROJECT")")" 4; echo $?)"

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
su_sql new "$PROJECT-fresh" "CALL ensure_measurement('mqtt_metrics');
    CREATE ROLE client_a LOGIN PASSWORD 'client_pw'; GRANT views_reader TO client_a;
    CALL auth.grant_org_role('client_a', '$ORG_A')" >/dev/null 2>&1
out="$(stats_probes new "$PROJECT-fresh")"
check "statistics are refused to a client" "$(is "$(printf '%s\n' "$out" | grep -c "permission denied")" 3; echo $?)"
guard_checks new "$PROJECT-fresh"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
