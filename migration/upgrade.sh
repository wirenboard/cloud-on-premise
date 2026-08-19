#!/usr/bin/env bash
# 1.x -> 2.x upgrade: backup -> scan -> gate -> migrate. The 2.x migration aborts
# on a 1.x database until every account has a unique email equal to its username.
# Delete together with the make targets once 1.x is out of support.
set -euo pipefail

. "$(dirname "$0")/../scripts/env.sh"

ENV_FILE="$ENV_FILE_DEFAULT"
BACKUP_DIR="backups"
MIGRATION_DIR="migration"
VERSION="$(cat VERSION)"
TS="$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }
# The configuration migration runs before the backup and drops the variables this
# release no longer uses, so a value needed only by 1.x is read from the copy it left.
legacy_env_value() {
    local value; value="$(env_value "$1")"
    [ -n "$value" ] || value="$(env_value "$1" "$(ls -t "$ENV_FILE".bak-* 2>/dev/null | head -1)")"
    printf '%s' "$value"
}
compose() { VERSION="$VERSION" docker compose "$@"; }

backup() {
    mkdir -p "$BACKUP_DIR"
    local out="$BACKUP_DIR/pg-$TS.sql.gz" part="$BACKUP_DIR/pg-$TS.sql.gz.part"
    say "------ PostgreSQL dump ------" "$NC"
    # Moved into place only once it holds data: gzip of a failed dump is still a
    # valid 20-byte archive, and would sit in backups/ looking like a real one.
    if compose exec -T postgres pg_dump -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" | gzip > "$part" &&
       [ -n "$(gzip -dc "$part" 2>/dev/null | head -c 1)" ]; then
        mv "$part" "$out"
    else
        rm -f "$part"
        say "ERROR: the PostgreSQL dump failed or came out empty — aborting." "$RED"
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
    local token; token="$(legacy_env_value INFLUXDB_TOKEN)"
    # Once the configuration has been migrated the newest .env.bak is itself 2.x and no
    # longer carries the token, so take it from the container that is still running on it.
    [ -z "$token" ] && token="$(docker exec "$cid" printenv DOCKER_INFLUXDB_INIT_ADMIN_TOKEN 2>/dev/null || true)"
    # Leftovers from an earlier run would pass the non-empty check below as fresh.
    docker exec "$cid" rm -rf /tmp/influx-backup 2>/dev/null || true
    docker exec "$cid" influx backup /tmp/influx-backup -t "$token" >/dev/null 2>&1 || true
    mkdir -p "$dir"
    docker cp "$cid:/tmp/influx-backup/." "$dir/" 2>/dev/null || true
    if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        say "InfluxDB backup written: $dir" "$GREEN"
    else
        say "WARNING: the InfluxDB backup is EMPTY — metrics history was NOT saved." "$YELLOW"
        say "Back up the 'influxData' docker volume manually if you need that history." "$YELLOW"
    fi
}

# $1 mode, $2 script path, $3 conflicts file — the stopped-stack fallback uses other
# paths. The mode goes through sys.argv: Django's shell rejects arguments of its own.
doctor_cmd() {
    printf "uv run --no-dev ./manage.py shell -c \"import sys; sys.argv = ['migration_doctor', '%s', '%s']; exec(open('%s').read())\"" "$1" "$3" "$2"
}

# The doctor runs inside the still-running 1.x backend container and touches only
# username/email.
fix_users() {
    local mode="${1:-scan}" rc=0
    # /tmp is the only path writable by the image's unprivileged user, so the
    # conflicts file is exchanged through it instead of a root-owned mount.
    local remote="/tmp/migration_doctor.py" yaml="/tmp/conflicts.yaml"
    local local_yaml="$MIGRATION_DIR/conflicts.yaml"

    # The container's environment was fixed when it started, and the admin whose email
    # is blank is exactly the case where 1.x started without ADMIN_EMAIL — so the value
    # is passed in from the current .env instead of being read from inside.
    local admin_email; admin_email="$(env_value ADMIN_EMAIL)"

    if compose ps --services --filter status=running 2>/dev/null | grep -qx backend; then
        local cid
        cid="$(compose ps -q backend)"
        docker cp "$MIGRATION_DIR/migration_doctor.py" "$cid:$remote"
        [ -f "$local_yaml" ] && docker cp "$local_yaml" "$cid:$yaml"
        # A non-zero exit means "conflicts remain" — still bring conflicts.yaml back.
        compose exec -e ADMIN_EMAIL="$admin_email" backend \
            sh -c "$(doctor_cmd "$mode" "$remote" "$yaml")" || rc=$?
        docker cp "$cid:$yaml" "$local_yaml" 2>/dev/null || true
        return $rc
    fi

    # Fallback for a stopped stack: bind-mount and run privileged, then hand the
    # file back to whoever owns the checkout. --no-deps: the doctor needs only
    # postgres; the full dependency tree would create the metrics volume early.
    compose up -d postgres >/dev/null 2>&1 || true
    compose run --rm --no-deps --user root -e ADMIN_EMAIL="$admin_email" \
        -v "$PWD/$MIGRATION_DIR:/migration" backend \
        sh -c "$(doctor_cmd "$mode" /migration/migration_doctor.py /migration/conflicts.yaml)" || rc=$?
    chown -R --reference="$ENV_FILE" "$MIGRATION_DIR" 2>/dev/null || true
    return $rc
}

# The metrics store bakes its credentials into its volume on first start, so a
# volume that predates the passwords in .env can never be logged into again.
metrics_volume_name() {
    local proj
    proj="$(compose config --format json 2>/dev/null | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$proj" ] || proj="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
    printf '%s_timescaleData' "$proj"
}

# Runs while the cloud keeps serving: nothing here touches the database or stops a
# service, so a failed run costs nothing.
check_upgrade() {
    local ready=1 config_ok=1 n=0 total=6
    step() { n=$((n + 1)); say "$n/$total $1" "$NC"; }

    step "Configuration and secrets"
    # A rolled-back upgrade restores a .env without the passwords the volume was
    # created with; fresh ones would silently lock telegraf and Grafana out.
    if [ -z "$(env_value TIMESCALE_PASSWORD)" ] && docker volume inspect "$(metrics_volume_name)" >/dev/null 2>&1; then
        say "    the metrics store volume '$(metrics_volume_name)' already exists, but .env has no metrics passwords" "$RED"
        say "    Passwords are baked into the volume when it is created — fresh ones would not match it." "$YELLOW"
        say "    Either put the previous TIMESCALE_*/TELEGRAF_*/GRAFANA_TIMESCALE_* values back into .env," "$YELLOW"
        say "    or drop the volume (it only holds 2.x metrics): docker volume rm $(metrics_volume_name)" "$YELLOW"
        return 1
    fi
    # Whether the configuration still looks like 1.x has to be answered before the
    # migration rewrites it — the marker below depends on the answer.
    local was_1x=0 v
    for v in INFLUXDB_TOKEN ADMIN_USERNAME EMAIL_PROTOCOL; do
        if [ -n "$(env_value "$v")" ]; then was_1x=1; fi
    done

    # Before the migration, so the new passwords are carried over into the 2.x file
    # like any other value: the metrics store bakes them in when it first starts.
    make generate-metrics-passwords >/dev/null || ready=0
    # Installations updating from a release archive have no key pair yet, and the
    # public key is mounted as a file: without this docker creates a directory in
    # its place and the tunnels break after the migration, not before.
    make generate-jwt >/dev/null || ready=0
    bash ./migration/migrate-env.sh || ready=0
    config_ok=$ready

    # From here the configuration is 2.x while the database can still be 1.x, and
    # both 1.x signals the guard relies on are gone. The marker keeps `make run`
    # out until the upgrade finishes or the rollback clears it.
    if [ "$config_ok" -eq 1 ] && [ "$was_1x" -eq 1 ]; then
        mkdir -p "$BACKUP_DIR"
        : > "$UPGRADE_MARKER"
    fi

    step "Environment variables"
    if [ "$config_ok" -eq 0 ]; then
        say "    skipped: fix the configuration above first" "$YELLOW"
    elif make check-env >/dev/null; then
        say "    all required variables are set" "$GREEN"
    else
        say "    some required variables are missing or empty — 'make check-env' prints the list" "$RED"
        ready=0
    fi

    step "TLS certificate"
    if [ "$config_ok" -eq 0 ]; then
        say "    skipped: fix the configuration above first" "$YELLOW"
    elif make check-certs >/dev/null 2>&1; then
        say "    covers every required domain" "$GREEN"
    else
        say "    certificate does not cover all required domains — run 'make check-certs' for details" "$RED"
        say "    2.x additionally needs *.apps.<domain>; reissuing it takes a DNS challenge, so do it in advance" "$YELLOW"
        ready=0
    fi

    step "Disk space"
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

    step "Images"
    # Every compose call reads the whole file, so an unfinished configuration makes
    # them fail for a reason that has nothing to do with images or accounts.
    if [ "$config_ok" -eq 0 ]; then
        say "    skipped: fix the configuration above first" "$YELLOW"
    elif [ "$enough" -eq 0 ]; then
        say "    skipped: free the disk first, downloading now would fill it" "$YELLOW"
    elif compose pull --quiet 2>/dev/null; then
        say "    downloaded, the update itself will not wait for them" "$GREEN"
    else
        say "    could not download the images for $VERSION — check the registry and the tag" "$RED"
        ready=0
    fi

    step "User accounts"
    if [ "$config_ok" -eq 0 ]; then
        say "    skipped: fix the configuration above first" "$YELLOW"
    elif fix_users scan >/dev/null 2>&1; then
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
    say "Not ready yet. Fix what is marked above and run 'make upgrade' again." "$YELLOW"
    say "The cloud keeps running and the database has not been touched. The configuration," "$YELLOW"
    say "however, has already been migrated to $VERSION — the previous one is kept next to it" "$YELLOW"
    say "as .env.bak-<date>, and going back to 1.x means restoring the oldest of those copies." "$YELLOW"
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
    say "Cancelled. The database was not touched; the configuration is already $VERSION." "$YELLOW"
    return 1
}

# The maintenance window itself: back up, stop the application, migrate, start.
# Everything slow has already happened in check-upgrade.
upgrade() {
    local n=0 total=4
    step() { n=$((n + 1)); say "Step $n/$total: $1" "$YELLOW"; }

    check_upgrade || exit 1
    confirm || exit 0

    echo
    step "backup (before ANY database change)."
    backup
    # Raised back in check_upgrade, as soon as the configuration became 2.x. Kept
    # here for the case where that never happened — a 2.x .env with a 1.x database.
    : > "$UPGRADE_MARKER"

    step "stopping the application — the databases stay up for the migration."
    local app_services
    app_services="$(compose config --services | grep -vE '^(postgres|timescale|redis|minio|minio-client)$' | tr '\n' ' ')"
    compose stop $app_services

    # The list above misses 1.x-only services (influx, worker-influx), and that worker
    # would keep writing under the old schema through the migration. Backup is done,
    # so they are removed rather than stopped: they carry `restart: always` and would
    # come back with the docker daemon, after which `make update` sees a 1.x image and
    # refuses to work on an installation that is already upgraded. Volumes stay.
    local proj known name svc
    proj="$(docker inspect "$(compose ps -q postgres)" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
    known="$(compose config --services)"
    if [ -n "$proj" ]; then
        docker ps --filter "label=com.docker.compose.project=$proj" \
                  --format '{{.Names}} {{.Label "com.docker.compose.service"}}' \
        | while read -r name svc; do
            printf '%s\n' "$known" | grep -qx "$svc" || docker rm -f "$name" >/dev/null 2>&1 || true
        done
    fi

    # Re-check with nothing writing: a registration between the check and the
    # migration would fail it after the backup had already run.
    if ! fix_users scan >/dev/null 2>&1; then
        say "Accounts changed since the check and no longer fit the 2.x schema." "$RED"
        echo "Nothing has been migrated, and the cloud is stopped. Two ways out:"
        echo
        echo "  repair and carry on, staying on this checkout:"
        echo "      make fix-users MODE=resolve && make upgrade"
        echo "  or go back to the old version, code first:"
        echo "      git checkout <old tag> && make run"
        echo
        # The old tag has no fix-users, so the two ways out exclude each other: repair
        # here first, or not at all. 'make run' on this checkout is refused meanwhile.
        echo "Note the old tag has no 'make fix-users' — repair here first, or not at all."
        exit 1
    fi

    step "applying database migrations."
    compose run --rm backend uv run --no-dev ./manage.py migrate

    step "starting $VERSION."
    compose up -d --build

    # Controllers only start reporting once the cloud hands them the collector
    # config, and that rollout is half-hourly — ask for it now instead.
    compose exec -T backend uv run --no-dev ./manage.py shell -c \
        "from organizations.tasks import update_lagging_metrics_configs; update_lagging_metrics_configs.delay()" \
        >/dev/null 2>&1 || true

    rm -f "$UPGRADE_MARKER"
    say "Upgrade to $VERSION complete." "$GREEN"
}

case "${1:-}" in
    backup)    backup ;;
    fix-users) fix_users "${2:-scan}" ;;
    upgrade)   upgrade ;;
    *) echo "usage: $0 {backup|fix-users [MODE]|upgrade}" >&2; exit 2 ;;
esac
