#!/usr/bin/env bash
# Builds .env from .env.example without an editor: values come from the
# environment, the rest is generated. Requires ABSOLUTE_SERVER and ADMIN_EMAIL;
# non-destructive unless --force. `make generate-env` still adds its own keys.
set -euo pipefail

ENV_FILE=".env"
TEMPLATE=".env.example"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }

FORCE=""
[ "${1:-}" = "--force" ] && FORCE=1

usage() {
    cat <<'EOF'
Usage: ABSOLUTE_SERVER=cloud.example.com ADMIN_EMAIL=admin@example.com ./scripts/init-env.sh [--force]

Read from the environment:
  ABSOLUTE_SERVER          (required) full public hostname of the cloud
  ADMIN_EMAIL              (required) cloud administrator, also the login
  ADMIN_PASSWORD           generated when unset
  EMAIL_ENABLED            True/False, default False (invites go through the admin panel)
  EMAIL_HOST EMAIL_PORT EMAIL_HOST_USER EMAIL_HOST_PASSWORD
  EMAIL_USE_TLS EMAIL_USE_SSL EMAIL_NOTIFICATIONS_FROM
  POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD          generated when unset
  GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD            generated when unset
  TUNNEL_DASHBOARD_USER TUNNEL_DASHBOARD_PASSWORD      generated when unset
  TUNNEL_PORT TUNNEL_DASHBOARD_PORT
  METRICS_RETENTION_DAYS GEOIP_ENABLED TLS_CERTS_PATH
  WORKER_CONCURRENCY METRICS_WORKER_CONCURRENCY GRAFANA_WORKER_CONCURRENCY EMAIL_WORKER_CONCURRENCY
  SERVICE_NAME PRIMARY_COLOR SERVICE_STATUS_URL SERVICE_DOCS_URL
  FOOTER_SITE_URL FOOTER_SITE_LABEL_RU FOOTER_SITE_LABEL_EN
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

[ -f "$TEMPLATE" ] || { say "ERROR: $TEMPLATE not found — run this from the repository root." "$RED"; exit 1; }

if [ -f "$ENV_FILE" ] && [ -z "$FORCE" ]; then
    say "$ENV_FILE already exists. Skipped — pass --force to rebuild it from $TEMPLATE." "$YELLOW"
    exit 0
fi

: "${ABSOLUTE_SERVER:?set ABSOLUTE_SERVER to the full public hostname of the cloud}"
: "${ADMIN_EMAIL:?set ADMIN_EMAIL to the cloud administrator email (it is also the login)}"

# Alphanumeric only: these end up inside DATABASE_URL and the Grafana management
# URL, where a raw '@' or '/' would split the URL.
gen_secret() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

# awk over sed: a value may hold characters sed would read as its own syntax.
set_var() {
    local key="$1" value="$2"
    # docker compose interpolates .env values, so a literal $ has to be doubled.
    # sed, not a bash substitution: there the replacement's $$ expands to the PID.
    local quoted
    quoted="$(printf '%s' "$value" | sed 's/\$/$$/g')"
    case "$value" in
        *[[:space:]#]*) quoted="\"$(printf '%s' "$quoted" | sed 's/["\\]/\\&/g')\"" ;;
    esac
    KEY="$key" VALUE="$quoted" awk '
        BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
        !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" k "=" { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
}

printf "\n\033[1;37m%s\033[0m\n" "=====================[ BUILDING $ENV_FILE ]====================="

cp "$TEMPLATE" "$ENV_FILE"
chmod 600 "$ENV_FILE"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_secret 20)}"
EMAIL_ENABLED="${EMAIL_ENABLED:-False}"

set_var ABSOLUTE_SERVER "$ABSOLUTE_SERVER"
set_var ADMIN_EMAIL "$ADMIN_EMAIL"
set_var ADMIN_PASSWORD "$ADMIN_PASSWORD"
set_var EMAIL_ENABLED "$EMAIL_ENABLED"

case "$(printf '%s' "$EMAIL_ENABLED" | tr '[:upper:]' '[:lower:]')" in
    false|off|no|0)
        # check-env does not demand EMAIL_* with email off, and a half-filled
        # block reads like a working configuration. Drop it instead.
        grep -vE '^[[:space:]]*EMAIL_(HOST|PORT|HOST_USER|HOST_PASSWORD|USE_TLS|USE_SSL|NOTIFICATIONS_FROM)=' \
            "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
        say "Email is off: invitations and password resets go through the admin panel." "$YELLOW"
        ;;
    *)
        : "${EMAIL_HOST:?EMAIL_ENABLED is on — set EMAIL_HOST or turn email off with EMAIL_ENABLED=False}"
        : "${EMAIL_NOTIFICATIONS_FROM:?EMAIL_ENABLED is on — set EMAIL_NOTIFICATIONS_FROM}"
        set_var EMAIL_HOST "$EMAIL_HOST"
        set_var EMAIL_PORT "${EMAIL_PORT:-587}"
        set_var EMAIL_HOST_USER "${EMAIL_HOST_USER:-}"
        set_var EMAIL_HOST_PASSWORD "${EMAIL_HOST_PASSWORD:-}"
        set_var EMAIL_NOTIFICATIONS_FROM "$EMAIL_NOTIFICATIONS_FROM"
        # 587 speaks STARTTLS, 465 is TLS from the first byte — never both.
        if [ "${EMAIL_USE_SSL:-False}" = "True" ]; then
            set_var EMAIL_USE_SSL True
            set_var EMAIL_USE_TLS False
        else
            set_var EMAIL_USE_TLS "${EMAIL_USE_TLS:-True}"
        fi
        ;;
esac

set_var POSTGRES_DB "${POSTGRES_DB:-wbc}"
set_var POSTGRES_USER "${POSTGRES_USER:-wbc}"
set_var POSTGRES_PASSWORD "${POSTGRES_PASSWORD:-$(gen_secret)}"

set_var GRAFANA_ADMIN_USER "${GRAFANA_ADMIN_USER:-grafana_admin}"
set_var GRAFANA_ADMIN_PASSWORD "${GRAFANA_ADMIN_PASSWORD:-$(gen_secret)}"

set_var TUNNEL_DASHBOARD_USER "${TUNNEL_DASHBOARD_USER:-tunnel_admin}"
set_var TUNNEL_DASHBOARD_PASSWORD "${TUNNEL_DASHBOARD_PASSWORD:-$(gen_secret)}"
set_var TUNNEL_PORT "${TUNNEL_PORT:-7107}"
set_var TUNNEL_DASHBOARD_PORT "${TUNNEL_DASHBOARD_PORT:-7501}"

for opt in METRICS_RETENTION_DAYS GEOIP_ENABLED TLS_CERTS_PATH \
           WORKER_CONCURRENCY METRICS_WORKER_CONCURRENCY GRAFANA_WORKER_CONCURRENCY EMAIL_WORKER_CONCURRENCY \
           SERVICE_NAME PRIMARY_COLOR SERVICE_STATUS_URL SERVICE_DOCS_URL \
           FOOTER_SITE_URL FOOTER_SITE_LABEL_RU FOOTER_SITE_LABEL_EN; do
    [ -n "${!opt:-}" ] && set_var "$opt" "${!opt}"
done

# Last, not right after the copy: every rewrite above goes through a temporary
# file, and the mode travels with it.
chmod 600 "$ENV_FILE"

say "$ENV_FILE is ready for $ABSOLUTE_SERVER." "$GREEN"
say "Secrets not set explicitly were generated — read them back from $ENV_FILE." "$YELLOW"
