#!/bin/sh
# Runs once on first initialisation of the application PostgreSQL volume.
# Creates a dedicated role + database for clients-grafana so Grafana keeps its
# own state separate from the application schema. Upstream provisions this via
# a separate pgcat pool + Ansible; on-premise we bootstrap it inline.
set -e

GRAFANA_DB_USER="${GRAFANA_DB_USER:-grafana}"
GRAFANA_DB_PASSWORD="${GRAFANA_DB_PASSWORD:-grafana_db_password}"
GRAFANA_DB_NAME="${GRAFANA_DB_NAME:-grafana}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${GRAFANA_DB_USER}') THEN
            CREATE ROLE "${GRAFANA_DB_USER}" LOGIN PASSWORD '${GRAFANA_DB_PASSWORD}';
        END IF;
    END
    \$\$;
SQL

# CREATE DATABASE cannot run inside a DO block / transaction, so do it conditionally here.
if ! psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname = '${GRAFANA_DB_NAME}'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "CREATE DATABASE \"${GRAFANA_DB_NAME}\" OWNER \"${GRAFANA_DB_USER}\";"
fi
