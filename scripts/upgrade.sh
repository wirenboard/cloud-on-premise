#!/usr/bin/env bash
# 1.x -> 2.0 upgrade: backup -> scan -> gate -> migrate. The 2.0 migration aborts
# on a 1.x database until every account has a unique email equal to its username.
# Delete together with the make targets once 1.x is out of support.
set -euo pipefail

ENV_FILE=".env"
BACKUP_DIR="backups"
MIGRATION_DIR="migration"
VERSION="$(cat VERSION)"
TS="$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }
# `|| true`: a missing variable is an empty value, not a fatal error under set -e.
env_value() { grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' || true; }
compose() { VERSION="$VERSION" docker compose "$@"; }

backup() {
    mkdir -p "$BACKUP_DIR"
    local out="$BACKUP_DIR/pg-$TS.sql.gz"
    say "------ PostgreSQL dump ------" "$NC"
    compose exec -T postgres pg_dump -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" | gzip > "$out"
    if [ ! -s "$out" ]; then
        rm -f "$out"
        say "ERROR: PostgreSQL backup is empty — aborting." "$RED"
        exit 1
    fi
    say "PostgreSQL backup written: $out" "$GREEN"

    local svc
    svc="$(compose ps --services 2>/dev/null | grep -xE 'influx(db)?' | head -1 || true)"
    if [ -z "$svc" ]; then
        say "No running influx service — skipping the metrics history backup." "$YELLOW"
        return
    fi
    say "------ InfluxDB backup (kept as-is, not converted to TimescaleDB) ------" "$NC"
    local dir="$BACKUP_DIR/influx-$TS" cid
    compose exec -T "$svc" influx backup /tmp/influx-backup -t "$(env_value INFLUXDB_TOKEN)" || true
    cid="$(compose ps -q "$svc")"
    mkdir -p "$dir"
    docker cp "$cid:/tmp/influx-backup/." "$dir/" 2>/dev/null || true
    if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        say "InfluxDB backup written: $dir" "$GREEN"
    else
        say "WARNING: the InfluxDB backup is EMPTY — metrics history was NOT saved." "$YELLOW"
        say "Back up the 'influxData' docker volume manually if you need that history." "$YELLOW"
    fi
}

# The doctor runs inside the still-running 1.x backend container and touches only
# username/email. The mode goes through sys.argv: Django's shell rejects extra args.
fix_users() {
    local mode="${1:-scan}"
    local cmd="uv run --no-dev ./manage.py shell -c \"import sys; sys.argv = ['migration_doctor', '$mode']; exec(open('/migration/migration_doctor.py').read())\""
    local rc=0
    # -u/--user root: the image runs as nobody, which cannot write conflicts.yaml.
    if compose ps --services --filter status=running 2>/dev/null | grep -qx backend; then
        local cid
        cid="$(compose ps -q backend)"
        docker cp "$MIGRATION_DIR" "$cid:/"
        # A non-zero exit means "conflicts remain" — still copy conflicts.yaml back.
        compose exec -u root backend sh -c "$cmd" || rc=$?
        docker cp "$cid:/migration/." "$MIGRATION_DIR/"
    else
        compose run --rm --user root -v "$PWD/$MIGRATION_DIR:/migration" backend sh -c "$cmd" || rc=$?
    fi
    # The files come back owned by root; hand them to whoever owns the checkout.
    chown -R --reference="$ENV_FILE" "$MIGRATION_DIR" 2>/dev/null || true
    return $rc
}

upgrade() {
    if ! grep -Eq '^[[:space:]]*EMAIL_ENABLED=' "$ENV_FILE"; then
        say "EMAIL_ENABLED was not set — keeping the 1.x behaviour (True)." "$YELLOW"
        printf '\nEMAIL_ENABLED=True\n' >> "$ENV_FILE"
    fi
    # 1.x stored the SMTP settings as a URL and its parts; 2.0 uses Django's own names.
    if ! grep -Eq '^[[:space:]]*EMAIL_HOST=' "$ENV_FILE" && [ -n "$(env_value EMAIL_SERVER)" ]; then
        say "Converting the 1.x EMAIL_* variables to the 2.0 names." "$YELLOW"
        {
            printf '\nEMAIL_HOST=%s\n' "$(env_value EMAIL_SERVER)"
            printf 'EMAIL_HOST_USER=%s\n' "$(env_value EMAIL_LOGIN)"
            printf 'EMAIL_HOST_PASSWORD=%s\n' "$(env_value EMAIL_PASSWORD)"
            case "$(env_value EMAIL_PROTOCOL)" in
                *ssl*) printf 'EMAIL_USE_SSL=True\n' ;;
                *tls*) printf 'EMAIL_USE_TLS=True\n' ;;
            esac
        } >> "$ENV_FILE"
    fi

    # Report every variable the new release added at once, not one per run.
    local email_off=""
    case "$(env_value EMAIL_ENABLED | tr '[:upper:]' '[:lower:]')" in
        false|off|no|0) email_off=1 ;;
    esac
    missing=""
    for var in $(grep -oE '^[A-Z_]+=' .env.example | tr -d '='); do
        [ -n "$email_off" ] && case "$var" in EMAIL_*) continue ;; esac
        grep -Eq "^[[:space:]]*$var=" "$ENV_FILE" || missing="$missing $var"
    done
    if [ -n "$missing" ]; then
        say "This release needs variables that are not in your $ENV_FILE:" "$RED"
        for var in $missing; do echo "  $var"; done
        say "Copy them from .env.example, set your own values, then re-run 'make upgrade'." "$YELLOW"
        exit 1
    fi

    make generate-env
    make check-certs

    say "Step 1/4: mandatory backup (before ANY database change)." "$YELLOW"
    backup

    say "Step 2/4: scanning the user table for 2.0 conflicts." "$YELLOW"
    if ! fix_users scan; then
        say "Conflicts found — the migration is BLOCKED." "$RED"
        echo "Resolve them, then re-run 'make upgrade':"
        echo "  make fix-users MODE=resolve                       interactive wizard"
        echo "  make fix-users MODE=dump / MODE=apply             edit $MIGRATION_DIR/conflicts.yaml in between"
        echo "  make fix-users MODE=auto                          apply the safe fixes only"
        exit 1
    fi
    say "No user conflicts. Proceeding." "$GREEN"

    say "Step 3/4: applying database migrations on the 2.0 image." "$YELLOW"
    compose pull
    compose run --rm backend uv run --no-dev ./manage.py migrate

    say "Step 4/4: bringing up the 2.0 stack." "$YELLOW"
    compose up -d --build
    say "Upgrade to $VERSION complete." "$GREEN"
}

case "${1:-}" in
    backup)    backup ;;
    fix-users) fix_users "${2:-scan}" ;;
    upgrade)   upgrade ;;
    *) echo "usage: $0 {backup|fix-users [MODE]|upgrade}" >&2; exit 2 ;;
esac
