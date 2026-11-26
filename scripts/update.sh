#!/usr/bin/env bash
# `make update`: bring the files of the latest release and switch the running cloud to them.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/env.sh

MAKE="${MAKE:-make}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }

if [ -z "${UPDATE_FILES_PULLED:-}" ]; then
    if git symbolic-ref -q HEAD >/dev/null; then
        say "------ Release files: git pull ------" "$NC"
        git pull --ff-only || {
            say "ERROR: git pull did not go through; nothing was changed. See 'git status', then run 'make update' again." "$RED"
            exit 1
        }
    else
        say "The files are a checked-out tag ($(git describe --tags 2>/dev/null || echo detached)): updating to it without git pull." "$YELLOW"
    fi
    # The pulled release may have changed this script and the Makefile: run its own.
    UPDATE_FILES_PULLED=1 exec "$MAKE" update
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
# The one release 2.1.0 migrates from; an older 2.x goes through it first.
UPDATE_FROM="2.0.1"
LOGIN_CHECK="upgrade/2.1.0/logins-differ-only-by-case.sql"
KEEP_DUMPS=3

compose() { VERSION="$VERSION" docker compose "$@"; }
export VERSION

running="$(stack_versions --status running)"

if [ -z "$running" ]; then
    present="$(stack_versions -a)"
    say "ERROR: the cloud is not running, so there is nothing to back up and switch." "$RED"
    if [ "${present%%-*}" = "${VERSION%%-*}" ]; then
        say "Its containers are already $present: start them with 'make run' and see 'docker compose logs'." "$YELLOW"
    else
        say "Start the version it ran with its own files, return to these and update:" "$YELLOW"
        say "  git checkout v${present:-<previous>} && make run && git checkout - && make update" "$YELLOW"
        say "A new installation starts with 'make run'." "$YELLOW"
    fi
    exit 1
fi
case "$running" in
    *" "*) say "ERROR: the running containers are of several versions: $running." "$RED"
           say "Start the stack with the files of one version, then update." "$YELLOW"
           exit 1 ;;
esac

# A rebuild of the same release, e.g. -testing images on the test server.
if [ "${running%%-*}" = "${VERSION%%-*}" ]; then
    switching=0
elif [ "${running%%-*}" = "$UPDATE_FROM" ]; then
    switching=1
else
    say "ERROR: $VERSION updates from $UPDATE_FROM, the cloud runs $running." "$RED"
    say "Update to $UPDATE_FROM first, then to $VERSION:" "$YELLOW"
    say "  git checkout v$UPDATE_FROM && make update && git checkout - && make update" "$YELLOW"
    exit 1
fi

if [ "$switching" = 1 ]; then
    say "------ Logins that differ only by letter case ------" "$NC"
    pairs="$(compose exec -T postgres psql -U "$(env_value POSTGRES_USER)" -d "$(env_value POSTGRES_DB)" \
        -v ON_ERROR_STOP=1 -At -F ' ' < "$LOGIN_CHECK")" || {
        say "ERROR: could not run the login check on the database; nothing was changed." "$RED"
        exit 1
    }
    if [ -n "$pairs" ]; then
        say "ERROR: these logins differ only by letter case, and migration users.0020 of $VERSION fails on them (id, login):" "$RED"
        printf '%s\n' "$pairs"
        say "Rename or delete one login of each pair in the admin panel, then run 'make update' again. Nothing was changed." "$YELLOW"
        exit 1
    fi
    say "None." "$GREEN"
fi

"$MAKE" generate-env
"$MAKE" check-certs

# Pulled while the old version still serves: a failed pull leaves it running.
compose pull || {
    say "ERROR: could not pull the $VERSION images; $running keeps running, nothing was switched." "$RED"
    exit 1
}

"$MAKE" backup
dumps="$(find backups -maxdepth 1 -name 'pg-*.sql.gz' 2>/dev/null | sort)"
dump="$(printf '%s\n' "$dumps" | tail -1)"
printf '%s\n' "$dumps" | awk -v keep="$KEEP_DUMPS" '{ all[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print all[i] }' |
    while IFS= read -r old; do [ -n "$old" ] && rm -f -- "$old"; done

failed() {
    say "ERROR: the update to $VERSION stopped: $1." "$RED"
    say "A dump of the database taken before the update: $dump." "$YELLOW"
    say "See 'docker compose logs'; how to roll back is in the README section \"Обновление\" / \"Updating\"." "$YELLOW"
    exit 1
}

compose down --remove-orphans || failed "the old containers did not stop"
docker image prune -f || true
docker container prune -f || true

if [ "$switching" = 1 ]; then
    # organizations.0037 unlinks Grafana organizations shared by two cloud organizations;
    # the duplicates left by that race go before it, while the shared ones are still linked.
    say "------ Duplicate Grafana organizations ------" "$NC"
    if compose up -d --wait postgres clients-grafana &&
       compose run --rm --no-deps backend uv run --no-dev ./manage.py delete_duplicate_grafana_orgs --apply; then
        :
    else
        say "WARNING: duplicate Grafana organizations were not removed; the update goes on." "$YELLOW"
        say "Look at the plan and remove them later:" "$YELLOW"
        say "  docker compose run --rm backend uv run --no-dev ./manage.py delete_duplicate_grafana_orgs [--apply]" "$YELLOW"
    fi
fi

compose up -d --build --remove-orphans || failed "the containers of $VERSION did not start"
printf '%s\n' "$VERSION" > "$RUN_RECORD" ||
    say "WARNING: could not write $RUN_RECORD: the next start without containers will be refused." "$YELLOW"
"$MAKE" check-metrics-schema
say "The cloud runs $VERSION." "$GREEN"
