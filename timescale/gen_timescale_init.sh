#!/usr/bin/env bash
set -euo pipefail

HOST="timescaledb"
PORT="5432"
DB="${TIMESCALE_DB}"
USER="${TIMESCALE_USER}"
PASSWORD="${TIMESCALE_PASSWORD}"

sed -i 's/\r$//' /init/timescale_init.sh 2>/dev/null || true
sed -i 's/\r$//' /init/init.sql.tmpl 2>/dev/null || true

echo "Waiting for Postgres ${HOST}:${PORT}/${DB}..."
i=0
while [ $i -lt 90 ]; do
  if pg_isready -h "$HOST" -p "$PORT" -d "$DB" -U "$USER" >/dev/null 2>&1; then
    echo "Postgres is ready."
    break
  fi
  i=$((i+1))
  sleep 2
done
[ $i -lt 90 ] || { echo "ERROR: Postgres is not ready after timeout."; exit 1; }


if ! command -v envsubst >/dev/null 2>&1; then
  echo "Installing envsubst..."
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache gettext
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y --no-install-recommends gettext-base && rm -rf /var/lib/apt/lists/*
  else
    echo "ERROR: no package manager to install envsubst" >&2
    exit 1
  fi
fi


echo "Rendering /tmpl/init.sql.tmpl -> /tmp/init.rendered.sql"
envsubst \
  '$TELEGRAF_TIMESCALE_USER $TELEGRAF_TIMESCALE_PASSWORD $GRAFANA_ADMIN_USER $GRAFANA_ADMIN_PASSWORD' \
  < /tmpl/init.sql.tmpl > /tmp/init.rendered.sql

echo "Applying SQL..."
psql "postgresql://${USER}:${PASSWORD}@${HOST}:${PORT}/${DB}" \
  -v ON_ERROR_STOP=1 -f /tmp/init.rendered.sql

echo "Done."
