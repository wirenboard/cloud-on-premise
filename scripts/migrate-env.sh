#!/usr/bin/env bash
# Rebuilds .env from .env.example, carrying over the values of the previous
# release: same-named variables as they are, renamed ones under their new names,
# generated secrets (keys, tokens) untouched. Whatever this release added and
# cannot derive is left EMPTY, and check-env stops the upgrade on the empty value
# itself — no marker to notice and delete. The previous file is kept alongside.
set -euo pipefail

ENV_FILE=".env"
TEMPLATE=".env.example"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }

# 1.x -> 2.x renames. EMAIL_PROTOCOL is handled separately: it turns into a flag.
renamed_from() {
    case "$1" in
        EMAIL_HOST)          echo EMAIL_SERVER ;;
        EMAIL_HOST_USER)     echo EMAIL_LOGIN ;;
        EMAIL_HOST_PASSWORD) echo EMAIL_PASSWORD ;;
    esac
}
# Variables the release dropped: they stay in the backup and are not carried over.
OBSOLETE="ADMIN_USERNAME EMAIL_URL EMAIL_PROTOCOL EMAIL_SERVER EMAIL_LOGIN EMAIL_PASSWORD
          INFLUXDB_USERNAME INFLUXDB_PASSWORD INFLUXDB_TOKEN GRAFANA_DB_NAME GRAFANA_DB_USER
          GRAFANA_DB_PASSWORD POSTGRES_BACKUP_BUCKET POSTGRES_BACKUP_PREFIX
          POSTGRES_BACKUP_SCHEDULE POSTGRES_BACKUP_KEEP_DAYS HTML_TITLE"

# With email switched off the EMAIL_* variables are optional — the same rule
# check-env follows — so they are carried over commented out, never demanded.
email_off() {
    case "$(grep -E '^[[:space:]]*EMAIL_ENABLED=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr '[:upper:]' '[:lower:]' || true)" in
        false|off|no|0) return 0 ;;
    esac
    return 1
}

[ -f "$ENV_FILE" ] || { say "No $ENV_FILE — nothing to migrate." "$YELLOW"; exit 0; }
[ -f "$TEMPLATE" ] || { say "No $TEMPLATE — cannot migrate." "$RED"; exit 1; }

SRC="$(mktemp)"; cp "$ENV_FILE" "$SRC"
trap 'rm -f "$SRC"' EXIT

# Present in the old file is enough to carry a value over, empty included: an empty
# value can be the operator's deliberate choice (a relay without a password), and
# only a variable this release introduced is worth demanding.
has_old()   { grep -qE "^[[:space:]]*$1=" "$SRC"; }
# check-env is the single source of truth for what must be set, so the list is read
# from the Makefile instead of being duplicated here. Variables allowed to stay empty
# are not demanded either.
MAKEFILE="Makefile"
required_vars() {
    [ -f "$MAKEFILE" ] || return 0
    awk '/^(EMAIL_)?REQUIRED_VARS[[:space:]]*[:+]?=/{f=1} f{print; if ($0 !~ /\\$/) f=0}' "$MAKEFILE" \
      | grep -oE '[A-Z][A-Z0-9_]{2,}' | grep -vE '^(EMAIL_)?REQUIRED_VARS$' | sort -u
    awk '/^ALLOW_EMPTY_VARS[[:space:]]*[:+]?=/{print}' "$MAKEFILE" \
      | grep -oE '[A-Z][A-Z0-9_]{2,}' | grep -v '^ALLOW_EMPTY_VARS$' | sed 's/^/-/'
}
REQ="$(required_vars || true)"
is_required() {
    printf '%s\n' "$REQ" | grep -qx -- "-$1" && return 1
    printf '%s\n' "$REQ" | grep -qx -- "$1"
}
old_value() { grep -E "^[[:space:]]*$1=" "$SRC" | tail -1 | cut -d= -f2-; }
old_names() { grep -oE '^[[:space:]]*[A-Z_][A-Z0-9_]*=' "$SRC" | tr -d '= \t'; }
is_obsolete() { printf '%s' "$OBSOLETE" | grep -qw -- "$1"; }

# Nothing to do when the file already matches this release.
missing=0
for var in $(grep -oE '^[A-Z_][A-Z0-9_]*=' "$TEMPLATE" | tr -d '='); do
    [ "$var" != "${var#EMAIL_}" ] && email_off && continue
    has_old "$var" || missing=1
done
leftovers=0
for var in $(old_names); do is_obsolete "$var" && leftovers=1; done
if [ "$missing" -eq 0 ] && [ "$leftovers" -eq 0 ]; then
    exit 0
fi

backup="$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
cp "$ENV_FILE" "$backup"

carried=""; renamed=""; todo=""; dropped=""; extra=""
tmp="$(mktemp)"

while IFS= read -r line; do
    if [[ "$line" =~ ^(#?)([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
        commented="${BASH_REMATCH[1]}"; var="${BASH_REMATCH[2]}"
        src="$(renamed_from "$var")"
        if has_old "$var"; then
            printf '%s=%s\n' "$var" "$(old_value "$var")" >> "$tmp"
            carried="$carried $var"
        elif [ -n "$src" ] && has_old "$src"; then
            printf '%s=%s\n' "$var" "$(old_value "$src")" >> "$tmp"
            renamed="$renamed|$src -> $var"
        elif [ "$var" = "EMAIL_USE_TLS" ] && has_old EMAIL_PROTOCOL; then
            # Bare smtp means an unencrypted relay (port 25): forcing TLS on it would
            # silently stop the mail.
            case "$(old_value EMAIL_PROTOCOL | tr '[:upper:]' '[:lower:]')" in
                *ssl*) printf 'EMAIL_USE_TLS=False\nEMAIL_USE_SSL=True\n' >> "$tmp" ;;
                smtp)  printf 'EMAIL_USE_TLS=False\n' >> "$tmp" ;;
                *)     printf 'EMAIL_USE_TLS=True\n' >> "$tmp" ;;
            esac
            renamed="$renamed|EMAIL_PROTOCOL -> EMAIL_USE_TLS/EMAIL_USE_SSL"
        elif [ -z "$commented" ] && [ "$var" != "${var#EMAIL_}" ] && email_off; then
            printf '#%s\n' "$line" >> "$tmp"
        elif [ -z "$commented" ] && is_required "$var"; then
            # Left empty on purpose: check-env refuses an empty required variable, so
            # the upgrade stops on the value itself instead of on a comment to notice.
            printf '%s=\n' "$var" >> "$tmp"
            todo="$todo $var"
        elif [ -z "$commented" ]; then
            # Not required: the example value is a working default, keep it.
            printf '%s\n' "$line" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    else
        printf '%s\n' "$line" >> "$tmp"
    fi
done < "$TEMPLATE"

# Generated secrets and any custom overrides live outside the template: losing
# them would log everyone out and break the tunnels, so they are kept verbatim.
for var in $(old_names); do
    grep -qE "^#?$var=" "$TEMPLATE" && continue
    if is_obsolete "$var"; then dropped="$dropped $var"; continue; fi
    extra="$extra $var"
done
if [ -n "$extra" ]; then
    { echo ""; echo "#----- Kept from the previous configuration -----"; } >> "$tmp"
    for var in $(printf '%s\n' $extra | sort); do
        printf '%s=%s\n' "$var" "$(old_value "$var")" >> "$tmp"
    done
fi

cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"

say "Configuration migrated. The previous file is kept as $backup" "$GREEN"
echo "  carried over: $(printf '%s\n' $carried | grep -c .) variable(s)"
[ -n "$renamed" ] && { echo "  renamed:"; printf '%s' "$renamed" | tr '|' '\n' | grep . | sed 's/^/    /'; }
[ -n "$extra" ] && echo "  kept as-is (secrets and custom values): $(printf '%s\n' $extra | grep -c .)"
[ -n "$dropped" ] && { echo "  no longer used (left in the backup):"; printf '    %s\n' $dropped; }

if [ -n "$todo" ]; then
    echo
    say "This release added variables that cannot be derived from the old file." "$YELLOW"
    say "They are left EMPTY in $ENV_FILE — set a value for each and re-run 'make upgrade':" "$YELLOW"
    printf '    %s=\n' $todo
    exit 1
fi
