#!/bin/bash
# Renders the TimescaleDB bootstrap template with the credentials from the
# environment and applies it on first initialisation of the data volume.
#
# We keep the SQL in a separate *.tmpl file (not *.sql) so the standard
# docker-entrypoint-initdb.d runner does not execute the un-rendered template
# directly. Only the role names/passwords are substituted; all the schema,
# procedures and tuning values are baked into the template.
set -euo pipefail

TMPL="/timescale/init.sql.tmpl"
OUT="$(mktemp)"

: "${TELEGRAF_TIMESCALE_USER:=telegraf}"
: "${TELEGRAF_TIMESCALE_PASSWORD:=telegraf_password}"
: "${GRAFANA_TIMESCALE_USER:=grafana}"
# Must match the compose default, or a stack without .env overrides bakes one
# password into the volume while the datasource presents another.
: "${GRAFANA_TIMESCALE_PASSWORD:=grafana_timescale_password}"
: "${METRICS_RETENTION_DAYS:=30}"
# Chunks are dropped a couple of days later than the per-host retention job, so a
# job that skips a run cannot take data with it.
RETENTION_SAFETY_DAYS=$((METRICS_RETENTION_DAYS + 2))

# Values land in single-quoted SQL and go through sed: escape the SQL quote, then the
# sed specials. Otherwise such a password breaks init, and init never runs twice.
esc() { printf '%s' "$1" | sed -e "s/'/''/g" -e 's![\\/&]!\\&!g'; }

sed \
  -e "s/__TELEGRAF_USER__/$(esc "$TELEGRAF_TIMESCALE_USER")/g" \
  -e "s/__TELEGRAF_PASSWORD__/$(esc "$TELEGRAF_TIMESCALE_PASSWORD")/g" \
  -e "s/__GRAFANA_USER__/$(esc "$GRAFANA_TIMESCALE_USER")/g" \
  -e "s/__GRAFANA_PASSWORD__/$(esc "$GRAFANA_TIMESCALE_PASSWORD")/g" \
  -e "s/__RETENTION_DAYS__/${METRICS_RETENTION_DAYS}/g" \
  -e "s/__RETENTION_SAFETY_DAYS__/${RETENTION_SAFETY_DAYS}/g" \
  "$TMPL" > "$OUT"

# The image installs timescaledb into postgres and template1 too; Timescale updates it only as the first command of a session.
psql -X -tA --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -c "SELECT datname FROM pg_database WHERE datallowconn" |
while read -r db; do
  outdated="$(psql -X -tA --username "$POSTGRES_USER" --dbname "$db" -c \
    "SELECT installed_version <> default_version FROM pg_available_extensions WHERE name = 'timescaledb'")"
  if [ "$outdated" = "t" ]; then
    psql -X -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" \
         -c "ALTER EXTENSION timescaledb UPDATE"
  fi
done

# All or nothing: a partial init leaves a store that answers pg_isready while
# telegraf silently writes nothing.
psql -v ON_ERROR_STOP=1 --single-transaction \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$OUT"
rm -f "$OUT"
