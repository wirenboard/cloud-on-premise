#!/usr/bin/env bash
# Downloads the DB-IP City Lite database used to show the country and city of a
# session. Runs from `make generate-env`; does nothing unless GEOIP_ENABLED is on.
set -euo pipefail

ENV_FILE=".env"
TARGET="geoip/dbip-city-lite.mmdb"
YELLOW='\033[0;33m'; GREEN='\033[0;32m'; NC='\033[0m'

enabled="$(grep -E '^[[:space:]]*GEOIP_ENABLED=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr '[:upper:]' '[:lower:]')"
case "$enabled" in
    true|on|yes|1) ;;
    *) exit 0 ;;
esac

printf "\n\033[0;37m%s\033[0m\n" "------ Session geolocation database ------"
[ -s "$TARGET" ] && { printf "%b%s%b\n" "$YELLOW" "$TARGET already present. Skipped." "$NC"; exit 0; }

url="https://download.db-ip.com/free/dbip-city-lite-$(date +%Y-%m).mmdb.gz"
mkdir -p geoip
if curl -fsSL --max-time 600 "$url" | gunzip > "$TARGET.part" 2>/dev/null && [ -s "$TARGET.part" ]; then
    mv "$TARGET.part" "$TARGET"
    printf "%b%s%b\n" "$GREEN" "Downloaded $TARGET" "$NC"
    exit 0
fi

rm -f "$TARGET.part"
printf "%b%s%b\n" "$YELLOW" "Could not download the database (no internet access?)." "$NC"
cat <<EOF
Sessions will simply show no country or city. To add it later, download
"IP to City Lite" (MMDB) from https://db-ip.com/db/download/ip-to-city-lite
on any machine with internet access, then put the unpacked file here:

    $TARGET

and restart the stack with 'make restart'.
EOF
