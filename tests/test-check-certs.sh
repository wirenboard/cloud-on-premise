#!/usr/bin/env bash
# check-certs: a matching key of any type passes; REQUIRED_DOMAINS are not globbed against the directory.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
DOMAIN=cloud.example.com
NAMES=("$DOMAIN" "*.$DOMAIN" "*.ssh.$DOMAIN" "*.http.$DOMAIN" "*.apps.$DOMAIN")

check() {
    if [ "$2" -eq 0 ]; then printf "  ok   %s\n" "$1"
    else printf "  FAIL %s\n" "$1"; failures=$((failures + 1)); fi
}

setup() {
    rm -rf "$WORK/case"; mkdir -p "$WORK/case/scripts" "$WORK/case/tls"
    cp "$ROOT/Makefile" "$ROOT/VERSION" "$WORK/case/"
    cp "$ROOT/scripts/env.sh" "$WORK/case/scripts/"
    printf 'ABSOLUTE_SERVER=%s\n' "$DOMAIN" > "$WORK/case/.env"
    cd "$WORK/case" || exit 1
}

cert() { # key type (ec|rsa), cert path, key path, SAN names...
    local type="$1" crt="$2" key="$3"; shift 3
    local algo=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1)
    [ "$type" = rsa ] && algo=(-newkey rsa:2048)
    local san; san="$(printf 'DNS:%s,' "$@")"
    openssl req -x509 "${algo[@]}" -nodes -keyout "$key" -out "$crt" -days 90 -subj /CN=t \
        -addext "subjectAltName=${san%,}" >/dev/null 2>&1
}

out=""
run_check() { out="$(make check-certs 2>&1)"; }
says() { printf '%s' "$out" | grep -qF -- "$1"; }   # captured: pipefail hides grep otherwise

echo "the key matches the certificate whatever its type"
for type in ec rsa; do
    setup
    cert "$type" tls/fullchain.pem tls/privkey.pem "${NAMES[@]}"
    run_check; rc=$?
    check "$type pair passes" "$([ $rc -eq 0 ] && says "Certificate check: PASSED"; echo $?)"

    setup
    cert "$type" tls/fullchain.pem tls/privkey.pem "${NAMES[@]}"
    cert "$type" "$WORK/other.pem" tls/privkey.pem "$DOMAIN"
    run_check; rc=$?
    check "$type certificate with another key is refused" \
        "$([ $rc -ne 0 ] && says "Certificate and private key do not match"; echo $?)"
done

echo
echo "files openssl cannot read are not a matching pair"
setup
echo "not pem" > tls/fullchain.pem
echo "not pem" > tls/privkey.pem
run_check; rc=$?
check "unreadable certificate and key are refused" \
    "$([ $rc -ne 0 ] && says "openssl cannot read the certificate or the private key" && ! says "Key and certificate match"; echo $?)"

echo
echo "a file named like a wildcard does not stand in for it"
setup
touch "a.$DOMAIN"
cert ec tls/fullchain.pem tls/privkey.pem "$DOMAIN" "a.$DOMAIN" "*.ssh.$DOMAIN" "*.http.$DOMAIN" "*.apps.$DOMAIN"
run_check; rc=$?
check "*.$DOMAIN missing from the SAN is refused" \
    "$([ $rc -ne 0 ] && says "does not cover required domain: *.$DOMAIN"; echo $?)"

echo
if [ "$failures" -ne 0 ]; then echo "FAILED: $failures check(s)"; exit 1; fi
echo "all checks passed"
