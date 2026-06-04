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
: "${GRAFANA_TIMESCALE_PASSWORD:=grafana_db_password}"

sed \
  -e "s/__TELEGRAF_USER__/${TELEGRAF_TIMESCALE_USER}/g" \
  -e "s/__TELEGRAF_PASSWORD__/${TELEGRAF_TIMESCALE_PASSWORD}/g" \
  -e "s/__GRAFANA_USER__/${GRAFANA_TIMESCALE_USER}/g" \
  -e "s/__GRAFANA_PASSWORD__/${GRAFANA_TIMESCALE_PASSWORD}/g" \
  "$TMPL" > "$OUT"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$OUT"
rm -f "$OUT"
