#!/usr/bin/env bash
# Идемпотентная установка Wiren Board On-Premise на чистую Ubuntu 24.04.
# Конфигурация — /etc/onprem/install.env (пишет cloud-init), TLS-ключи lego — /etc/onprem/acme.env.
# Повторный запуск безопасен: каждый шаг сначала проверяет, сделан ли он.
set -euo pipefail

CONF=${ONPREM_CONF:-/etc/onprem/install.env}
ACME_CONF=${ONPREM_ACME_CONF:-/etc/onprem/acme.env}
LOG=${ONPREM_LOG:-/var/log/onprem-install.log}
exec > >(tee -a "$LOG") 2>&1

log() { printf '[onprem %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ОШИБКА: $*"; exit 1; }

[ -r "$CONF" ] || die "нет $CONF"
set -a
# shellcheck disable=SC1090
. "$CONF"
set +a

: "${ABSOLUTE_SERVER:?}" "${ADMIN_EMAIL:?}" "${ADMIN_PASSWORD:?}"
: "${ONPREM_VERSION:?}" "${ONPREM_REPO_URL:=https://github.com/wirenboard/cloud-on-premise.git}"
: "${DATA_DEVICE:=auto}" "${DATA_MOUNT:=/data}" "${INSTALL_DIR:=/data/cloud-on-premise}"
: "${TLS_MODE:=letsencrypt-dns}" "${EMAIL_ENABLED:=False}"
DONE_DIR=/var/lib/onprem-install
mkdir -p "$DONE_DIR"

# ---------- 1. диск данных ----------
setup_data_disk() {
  if mountpoint -q "$DATA_MOUNT"; then log "диск данных уже смонтирован"; return; fi
  local dev=$DATA_DEVICE
  if [ "$dev" = auto ]; then
    local root_disk d
    root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
    dev=""
    while read -r d; do
      [ "$d" = "$root_disk" ] && continue
      # целый диск без разделов и без файловой системы — или с нашей меткой
      if [ -z "$(lsblk -no FSTYPE "/dev/$d" | tr -d '[:space:]')" ] || \
         [ "$(blkid -s LABEL -o value "/dev/$d" 2>/dev/null || true)" = onprem-data ]; then
        dev=/dev/$d; break
      fi
    done < <(lsblk -dbno NAME,TYPE,RM,SIZE | awk '$2=="disk" && $3==0 && $1!~/^(fd|loop|ram|sr)/ && $4>=1073741824{print $1}')
  fi
  if [ -z "$dev" ] || [ ! -b "$(readlink -f "$dev")" ]; then
    log "отдельного диска данных нет — данные остаются на корневом диске"
    mkdir -p "$DATA_MOUNT"; return
  fi
  if ! blkid "$dev" >/dev/null 2>&1; then
    log "форматирую $dev (ext4, метка onprem-data)"
    mkfs.ext4 -q -L onprem-data "$dev"
  fi
  mkdir -p "$DATA_MOUNT"
  grep -q 'LABEL=onprem-data' /etc/fstab || \
    echo "LABEL=onprem-data $DATA_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
  mount "$DATA_MOUNT"
  log "диск данных $dev → $DATA_MOUNT"
}

# ---------- 2. Docker ----------
install_docker() {
  if docker compose version >/dev/null 2>&1; then log "docker compose уже есть"; return; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git make openssl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

configure_docker_root() {
  local root=$DATA_MOUNT/docker
  if [ -f /etc/docker/daemon.json ] && grep -q "$root" /etc/docker/daemon.json; then return; fi
  mkdir -p "$root" /etc/docker
  # containerd-snapshotter выключен: иначе образы (≈15 ГБ) уходят в /var/lib/containerd на системный диск, мимо диска данных
  printf '{ "data-root": "%s", "features": { "containerd-snapshotter": false }, "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }\n' "$root" \
    > /etc/docker/daemon.json
  systemctl restart docker
  log "docker data-root → $root"
}

# ---------- 3. код выпуска ----------
fetch_release() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "репозиторий уже клонирован"
  else
    git clone --quiet "$ONPREM_REPO_URL" "$INSTALL_DIR"
  fi
  git -C "$INSTALL_DIR" fetch --quiet --tags
  git -C "$INSTALL_DIR" -c advice.detachedHead=false checkout --quiet "$ONPREM_VERSION"
  log "выпуск: $(git -C "$INSTALL_DIR" describe --tags --always)"
}

# ---------- 4. .env ----------
write_env() {
  cd "$INSTALL_DIR"
  [ -f .env ] && { log ".env уже есть — не перезаписываю"; return; }
  umask 077
  {
    echo "ABSOLUTE_SERVER=$ABSOLUTE_SERVER"
    echo "EMAIL_ENABLED=$EMAIL_ENABLED"
    echo "ADMIN_EMAIL=$ADMIN_EMAIL"
    echo "ADMIN_PASSWORD=$ADMIN_PASSWORD"
    echo "GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER:-grafana_admin}"
    echo "GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-$ADMIN_PASSWORD}"
    echo "TUNNEL_DASHBOARD_USER=${TUNNEL_DASHBOARD_USER:-tunnel_admin}"
    echo "TUNNEL_DASHBOARD_PASSWORD=${TUNNEL_DASHBOARD_PASSWORD:-$ADMIN_PASSWORD}"
    echo "POSTGRES_DB=${POSTGRES_DB:-wbcloud}"
    echo "POSTGRES_USER=${POSTGRES_USER:-wbcloud}"
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
    if [ "$EMAIL_ENABLED" != False ] && [ "$EMAIL_ENABLED" != false ]; then
      for v in EMAIL_HOST EMAIL_PORT EMAIL_HOST_USER EMAIL_HOST_PASSWORD EMAIL_NOTIFICATIONS_FROM EMAIL_USE_TLS; do
        if [ -n "${!v:-}" ]; then echo "$v=${!v}"; fi
      done
    fi
    if [ -n "${EXTRA_ENV:-}" ]; then printf '%b\n' "$EXTRA_ENV"; fi
  } > .env
  chmod 600 .env
  make generate-env
}

# ---------- 5. TLS ----------
setup_tls() {
  cd "$INSTALL_DIR"
  mkdir -p tls
  if [ -s tls/fullchain.pem ] && [ -s tls/privkey.pem ]; then log "сертификат уже лежит в tls/"; return; fi
  case "$TLS_MODE" in
    provided)
      [ -s /etc/onprem/tls/fullchain.pem ] || die "TLS_MODE=provided, но /etc/onprem/tls/fullchain.pem нет"
      install -m 0644 /etc/onprem/tls/fullchain.pem tls/fullchain.pem
      install -m 0600 /etc/onprem/tls/privkey.pem tls/privkey.pem ;;
    letsencrypt-dns)
      : "${ACME_EMAIL:?}" "${ACME_DNS_PROVIDER:?}"
      install_lego
      set -a
      # shellcheck disable=SC1090
      if [ -r "$ACME_CONF" ]; then . "$ACME_CONF"; fi
      set +a
      if [ "$ACME_DNS_PROVIDER" = yandexcloud ] && [ -z "${YANDEX_CLOUD_IAM_TOKEN:-}" ]; then
        write_yc_token_helper
        YANDEX_CLOUD_IAM_TOKEN=$(/usr/local/bin/onprem-yc-token)
        export YANDEX_CLOUD_IAM_TOKEN
      fi
      local args=(--accept-tos --email "$ACME_EMAIL" --dns "$ACME_DNS_PROVIDER" --path /etc/onprem/lego)
      if [ -n "${ACME_SERVER_URL:-}" ]; then args+=(--server "$ACME_SERVER_URL"); fi
      for d in "$ABSOLUTE_SERVER" "*.$ABSOLUTE_SERVER" "*.http.$ABSOLUTE_SERVER" "*.ssh.$ABSOLUTE_SERVER" "*.apps.$ABSOLUTE_SERVER"; do
        args+=(--domains "$d")
      done
      lego "${args[@]}" run
      install -m 0644 "/etc/onprem/lego/certificates/${ABSOLUTE_SERVER}.crt" tls/fullchain.pem
      install -m 0600 "/etc/onprem/lego/certificates/${ABSOLUTE_SERVER}.key" tls/privkey.pem
      install_renew_timer ;;
    none) log "TLS_MODE=none: сертификат должен быть положен в $INSTALL_DIR/tls вручную"; return 0 ;;
    *) die "неизвестный TLS_MODE=$TLS_MODE" ;;
  esac
}

install_lego() {
  command -v lego >/dev/null && return
  local ver=${LEGO_VERSION:-v4.21.0} arch
  arch=$(dpkg --print-architecture)
  curl -fsSL "https://github.com/go-acme/lego/releases/download/${ver}/lego_${ver}_linux_${arch}.tar.gz" | tar -xz -C /usr/local/bin lego
}

# IAM-токен сервисного аккаунта ВМ (живёт ~12 ч) из метаданных; нужен lego yandexcloud и при продлении
write_yc_token_helper() {
  cat > /usr/local/bin/onprem-yc-token <<'H'
#!/bin/sh
curl -fsS -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
H
  chmod 0755 /usr/local/bin/onprem-yc-token
}

install_renew_timer() {
  local yc_pre=""
  if [ "$ACME_DNS_PROVIDER" = yandexcloud ]; then
    write_yc_token_helper
    # $$ — systemd превращает в $, чтобы подстановку сделал bash, а не systemd
    # shellcheck disable=SC2016
    yc_pre='[ -n "$$YANDEX_CLOUD_IAM_TOKEN" ] || export YANDEX_CLOUD_IAM_TOKEN=$$(/usr/local/bin/onprem-yc-token);'
  fi
  cat > /etc/systemd/system/onprem-cert-renew.service <<UNIT
[Unit]
Description=Renew On-Premise TLS certificate (lego DNS-01)
[Service]
Type=oneshot
EnvironmentFile=-$ACME_CONF
ExecStart=/bin/bash -c '$yc_pre lego --accept-tos --email "$ACME_EMAIL" --dns "$ACME_DNS_PROVIDER" --path /etc/onprem/lego $(printf -- "--domains %q " "$ABSOLUTE_SERVER" "*.$ABSOLUTE_SERVER" "*.http.$ABSOLUTE_SERVER" "*.ssh.$ABSOLUTE_SERVER" "*.apps.$ABSOLUTE_SERVER") renew --days 30 && install -m 0644 /etc/onprem/lego/certificates/${ABSOLUTE_SERVER}.crt $INSTALL_DIR/tls/fullchain.pem && install -m 0600 /etc/onprem/lego/certificates/${ABSOLUTE_SERVER}.key $INSTALL_DIR/tls/privkey.pem && make -C $INSTALL_DIR reload-certs'
UNIT
  cat > /etc/systemd/system/onprem-cert-renew.timer <<UNIT
[Unit]
Description=Weekly TLS renewal check
[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now onprem-cert-renew.timer
}

# ---------- 6. запуск и автозапуск ----------
start_stack() {
  # docker compose читает VERSION из окружения (Makefile задаёт его из файла VERSION) — юнит без этого падает после перезагрузки
  cat > /usr/local/bin/onprem-compose <<WRAP
#!/bin/sh
cd "$INSTALL_DIR" || exit 1
VERSION=\$(tr -d '[:space:]' < VERSION)
export VERSION
exec /usr/bin/docker compose "\$@"
WRAP
  chmod 0755 /usr/local/bin/onprem-compose
  cat > /etc/systemd/system/onprem.service <<UNIT
[Unit]
Description=Wiren Board On-Premise (docker compose)
Requires=docker.service
After=docker.service network-online.target $(systemd-escape -p --suffix=mount "$DATA_MOUNT")
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/local/bin/onprem-compose up -d
ExecStop=/usr/local/bin/onprem-compose stop
TimeoutStartSec=900
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable onprem.service
  cd "$INSTALL_DIR"
  if [ "$TLS_MODE" = none ] && [ ! -s tls/fullchain.pem ]; then
    log "сертификата нет — запуск отложен (положите tls/*.pem и выполните make run)"; return
  fi
  make run
}

main() {
  setup_data_disk
  install_docker
  configure_docker_root
  fetch_release
  write_env
  setup_tls
  start_stack
  touch "$DONE_DIR/done"
  log "готово: https://$ABSOLUTE_SERVER"
}
main "$@"
