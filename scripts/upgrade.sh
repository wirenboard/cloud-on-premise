#!/usr/bin/env bash
# 1.x -> 2.x upgrade: backup -> scan -> gate -> migrate. The 2.x migration aborts
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

    # The 1.x metrics container is an orphan under the 2.x compose file, so it is
    # located by image rather than by service name.
    local cid
    cid="$(docker ps --format '{{.ID}} {{.Image}}' | awk '$2 ~ /^influxdb(:|$)/ {print $1; exit}')"
    if [ -z "$cid" ]; then
        say "No running InfluxDB — skipping the metrics history backup." "$YELLOW"
        return
    fi
    say "------ InfluxDB backup (kept as-is, not converted to TimescaleDB) ------" "$NC"
    local dir="$BACKUP_DIR/influx-$TS"
    docker exec "$cid" influx backup /tmp/influx-backup -t "$(env_value INFLUXDB_TOKEN)" >/dev/null 2>&1 || true
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
    local mode="${1:-scan}" rc=0
    # /tmp is the only path writable by the image's unprivileged user, so the
    # conflicts file is exchanged through it instead of a root-owned mount.
    local remote="/tmp/migration_doctor.py" yaml="/tmp/conflicts.yaml"
    local local_yaml="$MIGRATION_DIR/conflicts.yaml"
    local cmd="uv run --no-dev ./manage.py shell -c \"import sys; sys.argv = ['migration_doctor', '$mode', '$yaml']; exec(open('$remote').read())\""

    if compose ps --services --filter status=running 2>/dev/null | grep -qx backend; then
        local cid
        cid="$(compose ps -q backend)"
        docker cp "$MIGRATION_DIR/migration_doctor.py" "$cid:$remote"
        [ -f "$local_yaml" ] && docker cp "$local_yaml" "$cid:$yaml"
        # A non-zero exit means "conflicts remain" — still bring conflicts.yaml back.
        compose exec backend sh -c "$cmd" || rc=$?
        docker cp "$cid:$yaml" "$local_yaml" 2>/dev/null || true
        return $rc
    fi

    # Fallback for a stopped stack: bind-mount and run privileged, then hand the
    # file back to whoever owns the checkout.
    compose run --rm --user root -v "$PWD/$MIGRATION_DIR:/migration" backend \
        sh -c "uv run --no-dev ./manage.py shell -c \"import sys; sys.argv = ['migration_doctor', '$mode', '/migration/conflicts.yaml']; exec(open('/migration/migration_doctor.py').read())\"" || rc=$?
    chown -R --reference="$ENV_FILE" "$MIGRATION_DIR" 2>/dev/null || true
    return $rc
}

# Everything that can be done while the cloud keeps serving: prepare the
# configuration, verify the environment, and warm the image cache. Nothing here
# touches the database or stops a service, so a failed run costs nothing.
check_upgrade() {
    local ready=1

    say "1/6 Configuration" "$NC"
    bash ./scripts/migrate-env.sh || ready=0

    if [ "$ready" -eq 1 ]; then
        say "2/6 Environment variables" "$NC"
        make check-env >/dev/null || ready=0
        [ "$ready" -eq 1 ] && say "    all required variables are set" "$GREEN"

        say "3/6 TLS certificate" "$NC"
        if make check-certs >/dev/null 2>&1; then
            say "    covers every required domain" "$GREEN"
        else
            say "    certificate does not cover all required domains — run 'make check-certs' for details" "$RED"
            say "    2.x additionally needs *.apps.<domain>; reissuing it takes a DNS challenge, so do it in advance" "$YELLOW"
            ready=0
        fi
    fi

    say "4/6 Disk space" "$NC"
    local free_mb enough=1
    free_mb="$(df -Pm . | awk 'NR==2 {print $4}')"
    # The 2.x images take about 5 GB; the rest is headroom for the dump and logs.
    if [ "$free_mb" -lt 6000 ]; then
        enough=0
        say "    ${free_mb} MB free — the new images alone need about 5 GB." "$RED"
        say "    Free some space, e.g. 'docker image prune -a --filter until=720h'." "$YELLOW"
        ready=0
    else
        say "    ${free_mb} MB free" "$GREEN"
    fi

    say "5/6 Images" "$NC"
    if [ "$enough" -eq 0 ]; then
        say "    skipped: free the disk first, downloading now would fill it" "$YELLOW"
    elif compose pull --quiet 2>/dev/null; then
        say "    downloaded, the update itself will not wait for them" "$GREEN"
    else
        say "    could not download the images for $VERSION — check the registry and the tag" "$RED"
        ready=0
    fi

    say "6/6 User accounts" "$NC"
    if fix_users scan >/dev/null 2>&1; then
        say "    every account fits the 2.x schema" "$GREEN"
    else
        say "    accounts conflict with the 2.x schema (email becomes the login)" "$RED"
        echo "    Look at them and repair while the cloud is still running:"
        echo "      make fix-users MODE=scan       see the list"
        echo "      make fix-users MODE=auto       apply the safe fixes"
        echo "      make fix-users MODE=resolve    decide the rest by hand"
        ready=0
    fi

    echo
    if [ "$ready" -eq 1 ]; then
        say "Everything is ready." "$GREEN"
        return 0
    fi
    say "Not ready yet. Fix what is marked above and run 'make upgrade' again —" "$YELLOW"
    say "nothing has been changed and the cloud keeps running." "$YELLOW"
    return 1
}

# The checks above cost nothing, so they run on every attempt; only this asks.
confirm() {
    case "${CONFIRM:-}" in yes|YES|y|1) return 0 ;; esac
    echo
    say "The checks passed. What happens next:" "$YELLOW"
    echo "  1. the database is backed up into $BACKUP_DIR"
    echo "  2. the cloud stops — users and controllers lose access for a while"
    echo "  3. the migration runs and release $VERSION starts"
    echo "  Expect a few minutes of downtime; controllers reconnect on their own."
    echo
    if [ ! -t 0 ]; then
        # Exit non-zero: a script that cannot be asked has not upgraded anything.
        say "Not a terminal: re-run as 'make upgrade CONFIRM=yes' to proceed unattended." "$RED"
        exit 1
    fi
    printf "Stop the cloud and upgrade now? [y/N] "
    read -r answer
    case "$answer" in y|Y|yes|YES) return 0 ;; esac
    say "Cancelled. Nothing was changed." "$YELLOW"
    return 1
}

# The maintenance window itself: back up, stop the application, migrate, start.
# Everything slow has already happened in check-upgrade.
upgrade() {
    check_upgrade || exit 1
    confirm || exit 0

    echo
    say "Step 1/4: backup (before ANY database change)." "$YELLOW"
    backup

    say "Step 2/4: stopping the application — the databases stay up for the migration." "$YELLOW"
    local app_services
    app_services="$(compose config --services | grep -vE '^(postgres|timescale|redis|minio|minio-client)$' | tr '\n' ' ')"
    compose stop $app_services

    # Re-check with nothing writing: a registration between the check and the
    # migration would fail it after the backup had already run.
    if ! fix_users scan >/dev/null 2>&1; then
        say "Accounts changed since the check and no longer fit the 2.x schema." "$RED"
        echo "Repair them with 'make fix-users MODE=resolve', then run 'make upgrade' again."
        echo "Nothing has been migrated; the cloud is stopped — 'make run' brings the old version back."
        exit 1
    fi

    say "Step 3/4: applying database migrations." "$YELLOW"
    compose run --rm backend uv run --no-dev ./manage.py migrate

    say "Step 4/4: starting 2.0." "$YELLOW"
    compose up -d --build

    # Controllers only start reporting once the cloud hands them the collector
    # config, and that rollout is half-hourly — ask for it now instead.
    compose exec -T backend uv run --no-dev ./manage.py shell -c \
        "from organizations.tasks import update_lagging_metrics_configs; update_lagging_metrics_configs.delay()" \
        >/dev/null 2>&1 || true

    say "Upgrade to $VERSION complete." "$GREEN"
}

case "${1:-}" in
    backup)    backup ;;
    fix-users) fix_users "${2:-scan}" ;;
    upgrade)   upgrade ;;
    *) echo "usage: $0 {backup|fix-users [MODE]|upgrade}" >&2; exit 2 ;;
esac
