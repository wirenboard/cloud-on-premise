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

# All or nothing: the entrypoint runs this once, on an empty data volume. A partial
# init would leave a store that looks healthy — pg_isready answers, the container
# stays up — while telegraf silently writes nothing, and no restart would repair it.
psql -v ON_ERROR_STOP=1 --single-transaction \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$OUT"
rm -f "$OUT"
