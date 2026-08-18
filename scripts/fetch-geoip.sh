#!/usr/bin/env bash
# Downloads the DB-IP City Lite database used to show the country and city of a
# session. Runs from `make generate-env` and fetches it only when missing; with
# --force (make update-geoip) it refreshes an existing one — DB-IP publishes a new
# database every month. Does nothing unless GEOIP_ENABLED is on.
set -euo pipefail

FORCE=""
[ "${1:-}" = "--force" ] && FORCE=1

ENV_FILE=".env"
TARGET="geoip/dbip-city-lite.mmdb"
YELLOW='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }

# `|| true`: no match must read as "disabled", not abort the script under set -e.
enabled="$(grep -E '^[[:space:]]*GEOIP_ENABLED=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr '[:upper:]' '[:lower:]' || true)"
case "$enabled" in
    true|on|ok|y|yes|1) ;;
    *)
        [ -n "$FORCE" ] && say "Session geolocation is off: set GEOIP_ENABLED=True in $ENV_FILE first." "$YELLOW"
        exit 0
        ;;
esac

printf "\n\033[0;37m%s\033[0m\n" "------ Session geolocation database ------"
if [ -z "$FORCE" ] && [ -s "$TARGET" ]; then
    say "$TARGET already present. Skipped — run 'make update-geoip' to refresh it." "$YELLOW"
    exit 0
fi

url="https://download.db-ip.com/free/dbip-city-lite-$(date +%Y-%m).mmdb.gz"
mkdir -p geoip
if curl -fsSL --max-time 600 "$url" | gunzip > "$TARGET.part" 2>/dev/null && [ -s "$TARGET.part" ]; then
    # Replaced only after a complete download: a failed refresh keeps the old copy.
    mv "$TARGET.part" "$TARGET"
    say "Downloaded $TARGET" "$GREEN"
    exit 0
fi

rm -f "$TARGET.part"
say "Could not download the database (no internet access?)." "$YELLOW"
if [ -s "$TARGET" ]; then
    say "The database already in place is kept, geolocation keeps working." "$YELLOW"
    exit 0
fi
cat <<EOF
Sessions will simply show no country or city. To add it later, download
"IP to City Lite" (MMDB) from https://db-ip.com/db/download/ip-to-city-lite
on any machine with internet access, then put the unpacked file here:

    $TARGET

and restart the stack with 'make restart'.
EOF
