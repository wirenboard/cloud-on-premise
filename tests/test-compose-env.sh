#!/usr/bin/env bash
# What each container receives from .env, via `docker compose config` (no daemon): bash tests/test-compose-env.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}

if ! docker compose version >/dev/null 2>&1; then
    echo "  FAIL docker compose is not installed"; exit 1
fi

BASE_ENV='VERSION=test
ABSOLUTE_SERVER=cloud.example.com
EMAIL_ENABLED=False
'

# .env lines (appended to a minimal one) -> the resolved compose model as JSON, in $WORK/config.json
render() {
    rm -rf "$WORK/case"; mkdir -p "$WORK/case"
    cp "$ROOT/docker-compose.yml" "$WORK/case/"
    printf '%s%s\n' "$BASE_ENV" "$1" > "$WORK/case/.env"
    (cd "$WORK/case" && env -i PATH="$PATH" HOME="$HOME" docker compose config --format json 2>/dev/null) > "$WORK/config.json"
}

# Python expression over `s` (services) that has to be true.
holds() {
    python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))["services"]
# A variable without a value in compose is resolved at run time: null here means "not passed".
env = lambda name: {k: v for k, v in (s[name].get("environment") or {}).items() if v is not None}
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$WORK/config.json" "$1" >/dev/null 2>&1
    echo $?
}

BACKENDS='["backend", "tunnel-webhooks-backend", "agent_backend", "worker", "worker-metrics", "worker-grafana", "worker-email", "scheduler"]'
BRANDING='["SERVICE_NAME", "PRIMARY_COLOR", "SERVICE_STATUS_URL", "SERVICE_DOCS_URL", "SERVICE_DOCS_URL_EN", "FOOTER_SITE_URL", "FOOTER_SITE_LABEL_RU", "FOOTER_SITE_LABEL_EN"]'

echo "branding reaches the backend migration as the operator wrote it"
render ''
check "nothing set — no branding variable reaches any backend container" \
    "$(holds "all(v not in env(b) for b in $BACKENDS for v in $BRANDING + ['CARTO_API_KEY'])")"
render 'SERVICE_NAME="My Cloud"
PRIMARY_COLOR="#e2500a"
SERVICE_STATUS_URL=https://status.example.com/
SERVICE_DOCS_URL=https://docs.example.com/
SERVICE_DOCS_URL_EN=https://docs.example.com/en/
FOOTER_SITE_URL=https://example.com/
FOOTER_SITE_LABEL_RU=Сайт
FOOTER_SITE_LABEL_EN=Site
CARTO_API_KEY=carto-key'
check "everything set — every backend container gets the values" \
    "$(holds "all(env(b).get('SERVICE_NAME') == 'My Cloud' and env(b).get('FOOTER_SITE_URL') == 'https://example.com/' and env(b).get('FOOTER_SITE_LABEL_RU') == 'Сайт' and env(b).get('SERVICE_DOCS_URL_EN') == 'https://docs.example.com/en/' and env(b).get('CARTO_API_KEY') == 'carto-key' for b in $BACKENDS)")"
render 'FOOTER_SITE_URL=
SERVICE_DOCS_URL='
check "an explicitly empty link stays empty — the migration reads it as hidden" \
    "$(holds "env('backend').get('FOOTER_SITE_URL') == '' and env('backend').get('SERVICE_DOCS_URL') == '' and 'SERVICE_DOCS_URL_EN' not in env('backend')")"

echo
echo "the frontend still reads the footer, docs and status from its env; the map key comes from the backend"
FRONTEND_VARS="['BACKEND_APP_URL', 'FOOTER_LINKS', 'FOOTER_TRANSLATIONS_RU', 'FOOTER_TRANSLATIONS_EN', 'SERVICE_NAME', 'SERVICE_STATUS_URL', 'SERVICE_DOCS_URL', 'SERVICE_DOCS_URL_EN', 'PRIMARY_COLOR']"
render 'SERVICE_NAME="My Cloud"
SERVICE_STATUS_URL=https://status.example.com/
SERVICE_DOCS_URL=https://docs.example.com/
FOOTER_SITE_URL=https://example.com/
FOOTER_SITE_LABEL_RU=Сайт
PRIMARY_COLOR="#e2500a"
CARTO_API_KEY=carto-key'
check "frontend gets the footer, docs, status, name and color, and no CARTO_API_KEY" \
    "$(holds "set(env('frontend')) == set($FRONTEND_VARS) and env('frontend')['SERVICE_NAME'] == 'My Cloud' and env('frontend')['SERVICE_STATUS_URL'] == 'https://status.example.com/' and env('frontend')['PRIMARY_COLOR'] == '#e2500a'")"
check "the operator's footer link and labels reach it, one label serving both languages" \
    "$(holds "json.loads(env('frontend')['FOOTER_LINKS'])[0]['url'] == 'https://example.com/' and json.loads(env('frontend')['FOOTER_TRANSLATIONS_RU'])['mainSiteLink'] == 'Сайт' and json.loads(env('frontend')['FOOTER_TRANSLATIONS_EN'])['mainSiteLink'] == 'Сайт'")"
check "the English docs link falls back to SERVICE_DOCS_URL" \
    "$(holds "env('frontend')['SERVICE_DOCS_URL'] == 'https://docs.example.com/' and env('frontend')['SERVICE_DOCS_URL_EN'] == 'https://docs.example.com/'")"
render ''
check "nothing set — 2.0.1 defaults: product name, no status, Wiren Board site and wiki" \
    "$(holds "env('frontend')['SERVICE_NAME'] == 'Wiren Board Cloud' and env('frontend')['SERVICE_STATUS_URL'] == '' and json.loads(env('frontend')['FOOTER_LINKS'])[0]['url'] == 'https://wirenboard.com/' and env('frontend')['SERVICE_DOCS_URL'] == 'https://wirenboard.com/wiki/Wiren_Board_Cloud'")"
render 'FOOTER_SITE_URL=
SERVICE_DOCS_URL='
check "an empty FOOTER_SITE_URL and SERVICE_DOCS_URL stay empty — the UI hides those links" \
    "$(holds "json.loads(env('frontend')['FOOTER_LINKS'])[0]['url'] == '' and env('frontend')['SERVICE_DOCS_URL'] == '' and env('frontend')['SERVICE_DOCS_URL_EN'] == ''")"

echo
echo "branding files are written by the backend"
mounts='lambda name: {(v.get("target"), v.get("read_only", False)) for v in s[name].get("volumes", []) if v.get("type") == "bind"}'
check "backend mounts /branding writable" "$(holds "('/branding', False) in ($mounts)('backend')")"
check "frontend and webssh mount it read-only" \
    "$(holds "('/branding', True) in ($mounts)('frontend') and ('/branding', True) in ($mounts)('webssh')")"
check "backend starts only after branding-init handed /branding to nobody" \
    "$(holds "s['backend']['depends_on']['branding-init']['condition'] == 'service_completed_successfully' and str(s['branding-init'].get('user')) == '0:0' and 'chown nobody' in ' '.join(s['branding-init']['entrypoint'])")"
check "and leaves it readable to the frontend and webssh" \
    "$(holds "'chmod 755 /branding' in ' '.join(s['branding-init']['entrypoint'])")"

echo
echo "outbound proxy"
render ''
check "no proxy configured — HTTPS_PROXY is empty" "$(holds "env('backend').get('HTTPS_PROXY') == '' and env('worker').get('HTTPS_PROXY') == ''")"
render 'HTTPS_PROXY=http://proxy.corp:3128
NO_PROXY=.corp.local'
check "backend and worker go through the proxy" \
    "$(holds "env('backend')['HTTPS_PROXY'] == 'http://proxy.corp:3128' and env('worker')['HTTPS_PROXY'] == 'http://proxy.corp:3128'")"
INTERNAL='["localhost", "127.0.0.1", "postgres", "timescale", "redis", "seaweedfs", "clients-grafana", "tunnel", "tunnel-webhooks-backend", "backend", "webssh"]'
check "internal names bypass it, and the operator's NO_PROXY is kept" \
    "$(holds "all(h in env(b)['NO_PROXY'].split(',') for b in ['backend', 'worker'] for h in $INTERNAL + ['.corp.local'])")"

echo
echo "web console settings (CLOUD-980)"
WEBSSH='{"WS_RESUME_GRACE": "600", "WS_RESUME_GRACE_PAGE_CLOSED": "150", "WS_RESUME_BUFFER_SIZE": "65536", "WS_RESUME_MAX_DETACHED": "3", "WS_RESUME_BUSY_PING_TIMEOUT": "3", "SSH_CHANNEL_TIMEOUT": "15", "SFTP_TIMEOUT": "60", "DELETE_TIMEOUT": "120"}'
render 'WS_RESUME_GRACE=900
SFTP_TIMEOUT=90'
check "a set value reaches webssh" \
    "$(holds "env('webssh')['WS_RESUME_GRACE'] == '900' and env('webssh')['SFTP_TIMEOUT'] == '90'")"
render "$(python3 -I -c 'import json,sys; print("\n".join(k + "=" for k in json.loads(sys.argv[1])))' "$WEBSSH")"
check "an empty value never reaches webssh — its default is passed instead" \
    "$(holds "all(env('webssh').get(k) == v for k, v in $WEBSSH.items())")"

echo
echo "the rest of the backend settings"
render ''
check "agent_backend gets 2 minutes to finish long polls on stop" \
    "$(holds "s['agent_backend'].get('stop_grace_period') == '2m10s'")"
check "the backend and the workers get 30 seconds to stop" \
    "$(holds "all(s[n].get('stop_grace_period') == '30s' for n in ('backend', 'tunnel-webhooks-backend', 'worker', 'worker-metrics', 'worker-grafana', 'worker-email'))")"
check "EMAIL_FALLBACK_URLS empty by default, for the backend and the email worker" \
    "$(holds "env('backend')['EMAIL_FALLBACK_URLS'] == '' and env('worker-email')['EMAIL_FALLBACK_URLS'] == ''")"
check "the WB-internal telemetry flag is not in the shipped compose" \
    "$(holds "all('METRICS_INTERNAL_TESTING' not in env(n) for n in s)")"
render 'EMAIL_FALLBACK_URLS=smtp+tls://u:p@relay.example.com:587'
check "and EMAIL_FALLBACK_URLS is taken from .env" \
    "$(holds "env('worker-email')['EMAIL_FALLBACK_URLS'].startswith('smtp+tls://')")"

echo
if [ "$failures" -eq 0 ]; then echo "all compose env checks passed"; else echo "$failures compose env check(s) failed"; exit 1; fi
