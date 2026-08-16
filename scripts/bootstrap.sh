#!/usr/bin/env bash
# Installs the cloud on a clean Ubuntu host: Docker, the release, .env, TLS,
# first start. Unattended and safe to re-run. Cloud-agnostic on purpose — the
# AWS-specific parts happen before this script runs.
set -euo pipefail

WB_CLOUD_DIR="${WB_CLOUD_DIR:-/opt/wb-cloud}"
WB_CLOUD_VERSION="${WB_CLOUD_VERSION:-latest}"
WB_CLOUD_REPO="${WB_CLOUD_REPO:-wirenboard/cloud-on-premise}"
# route53 — issue a wildcard certificate over the DNS-01 challenge;
# manual — the certificate is put into $WB_CLOUD_DIR/tls by other means.
WB_CLOUD_TLS_MODE="${WB_CLOUD_TLS_MODE:-manual}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; WHITE='\033[1;37m'; NC='\033[0m'
say() { printf "%b%s%b\n" "$2" "$1" "$NC"; }
step() { printf "\n%b%s%b\n" "$WHITE" "=====================[ $1 ]=====================" "$NC"; }

[ "$(id -u)" = "0" ] || { say "ERROR: run as root." "$RED"; exit 1; }
: "${ABSOLUTE_SERVER:?set ABSOLUTE_SERVER to the full public hostname of the cloud}"
: "${ADMIN_EMAIL:?set ADMIN_EMAIL to the cloud administrator email}"

# x86-64-v2 is a hard requirement of the images; a VM without host-passthrough
# fails here rather than halfway through the first start.
step "CHECKING THE CPU"
if ! grep -qw sse4_2 /proc/cpuinfo || ! grep -qw popcnt /proc/cpuinfo; then
    say "ERROR: the CPU does not report x86-64-v2 (sse4.2, popcnt)." "$RED"
    say "On a VM enable host-passthrough (or CPU=host) and try again." "$YELLOW"
    exit 1
fi
say "CPU is fine." "$GREEN"

step "INSTALLING PACKAGES"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg make openssl tar

if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$(dpkg --print-architecture)" "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    say "Docker installed." "$GREEN"
else
    say "Docker already present." "$YELLOW"
fi
systemctl enable --now docker

step "FETCHING THE RELEASE"
if [ "$WB_CLOUD_VERSION" = "latest" ]; then
    WB_CLOUD_VERSION="$(curl -fsSL "https://api.github.com/repos/${WB_CLOUD_REPO}/releases/latest" |
        grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')"
    [ -n "$WB_CLOUD_VERSION" ] || { say "ERROR: could not resolve the latest release." "$RED"; exit 1; }
fi

if [ -f "$WB_CLOUD_DIR/docker-compose.yml" ]; then
    say "$WB_CLOUD_DIR already holds an installation ($(cat "$WB_CLOUD_DIR/VERSION" 2>/dev/null || echo unknown))." "$YELLOW"
    say "Leaving it as it is — upgrade with 'make upgrade' inside that directory." "$YELLOW"
else
    mkdir -p "$WB_CLOUD_DIR"
    # The tag tarball, not the release assets: the Makefile calls scripts/ that
    # the asset list does not carry.
    curl -fsSL "https://github.com/${WB_CLOUD_REPO}/archive/refs/tags/v${WB_CLOUD_VERSION}.tar.gz" |
        tar -xz -C "$WB_CLOUD_DIR" --strip-components=1
    say "Release v${WB_CLOUD_VERSION} unpacked into $WB_CLOUD_DIR." "$GREEN"
fi
cd "$WB_CLOUD_DIR"

step "BUILDING .env"
# Plain call: init-env.sh reads the whole configuration out of the environment
# this script was given.
bash ./scripts/init-env.sh

step "TLS CERTIFICATE"
mkdir -p "$WB_CLOUD_DIR/tls"
case "$WB_CLOUD_TLS_MODE" in
    route53)
        apt-get install -y -qq certbot python3-certbot-dns-route53
        # Traefik reads the files it is given, and check-certs compares an RSA
        # modulus — certbot's ECDSA default would fail that check.
        if [ ! -d "/etc/letsencrypt/live/${ABSOLUTE_SERVER}" ]; then
            certbot certonly --dns-route53 --key-type rsa \
                --non-interactive --agree-tos -m "${CERTBOT_EMAIL:-$ADMIN_EMAIL}" \
                --cert-name "$ABSOLUTE_SERVER" \
                -d "$ABSOLUTE_SERVER" \
                -d "*.$ABSOLUTE_SERVER" \
                -d "*.ssh.$ABSOLUTE_SERVER" \
                -d "*.http.$ABSOLUTE_SERVER" \
                -d "*.apps.$ABSOLUTE_SERVER"
            say "Certificate issued." "$GREEN"
        else
            say "Certificate for $ABSOLUTE_SERVER already exists." "$YELLOW"
        fi

        # Copied, not bind-mounted: /etc/letsencrypt/live holds symlinks into
        # ../../archive, and a symlink bind-mounted into a container dangles.
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/wb-cloud.sh <<EOF
#!/usr/bin/env bash
# Installs a renewed certificate into the cloud and makes Traefik re-read it.
set -euo pipefail
cp -L "/etc/letsencrypt/live/${ABSOLUTE_SERVER}/fullchain.pem" "${WB_CLOUD_DIR}/tls/fullchain.pem"
cp -L "/etc/letsencrypt/live/${ABSOLUTE_SERVER}/privkey.pem" "${WB_CLOUD_DIR}/tls/privkey.pem"
chmod 644 "${WB_CLOUD_DIR}/tls/fullchain.pem"
chmod 600 "${WB_CLOUD_DIR}/tls/privkey.pem"
cd "${WB_CLOUD_DIR}" && make reload-certs
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/wb-cloud.sh
        cp -L "/etc/letsencrypt/live/${ABSOLUTE_SERVER}/fullchain.pem" "$WB_CLOUD_DIR/tls/fullchain.pem"
        cp -L "/etc/letsencrypt/live/${ABSOLUTE_SERVER}/privkey.pem" "$WB_CLOUD_DIR/tls/privkey.pem"
        chmod 644 "$WB_CLOUD_DIR/tls/fullchain.pem"
        chmod 600 "$WB_CLOUD_DIR/tls/privkey.pem"
        # certbot ships its own renewal timer; the deploy hook above does the rest.
        systemctl enable --now certbot.timer 2>/dev/null || true
        ;;
    manual)
        if [ ! -s "$WB_CLOUD_DIR/tls/fullchain.pem" ] || [ ! -s "$WB_CLOUD_DIR/tls/privkey.pem" ]; then
            say "No certificate in $WB_CLOUD_DIR/tls — put fullchain.pem and privkey.pem there," "$YELLOW"
            say "then start the cloud with: cd $WB_CLOUD_DIR && make run" "$YELLOW"
            exit 0
        fi
        ;;
    *)
        say "ERROR: unknown WB_CLOUD_TLS_MODE='$WB_CLOUD_TLS_MODE' (expected route53 or manual)." "$RED"
        exit 1
        ;;
esac

step "STARTING THE CLOUD"
make run

say "" "$NC"
say "The cloud is starting at https://${ABSOLUTE_SERVER}" "$GREEN"
say "Administrator: ${ADMIN_EMAIL} (the password is in ${WB_CLOUD_DIR}/.env)" "$GREEN"
