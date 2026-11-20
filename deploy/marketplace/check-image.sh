#!/usr/bin/env bash
# Проверка ВМ, запущенной из образа On-Premise, по требованиям площадок (Yandex Cloud Marketplace, AWS Marketplace).
# Запускать внутри ВМ от root: sudo bash check-image.sh [путь/к/yc-image-cleanup.sh]
# Площадка Yandex даёт свою проверку (github.com/yandex-cloud/marketplace, products-prepare/linux): если путь передан — запускается и она (-t).
set -uo pipefail
rc=0
ok()   { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; rc=1; }
chk()  { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
chk "вход по паролю в sshd выключен"            bash -c "sshd -T | grep -qi '^passwordauthentication no'"
chk "root по паролю не входит"                  bash -c "sshd -T | grep -qiE '^permitrootlogin (no|prohibit-password|without-password)'"
chk "ssh-сервер стартует сам (ssh.service или ssh.socket в Ubuntu 24.04)" bash -c "systemctl is-enabled ssh || systemctl is-enabled ssh.socket || systemctl is-enabled sshd"
chk "cloud-init установлен"                     command -v cloud-init
chk "серийная консоль ttyS0 включена"           bash -c "grep -q ttyS0 /proc/cmdline"
chk "swap в fstab нет"                          bash -c "! grep -Eq '[[:space:]]swap[[:space:]]' /etc/fstab"
chk "диск в fstab — по UUID/LABEL"              bash -c "! grep -E '^/dev/(vd|sd|xvd|nvme)' /etc/fstab"
chk "модули virtio загружены или встроены"      bash -c "lsmod | grep -q virtio_net || modinfo virtio_net"
chk "служба On-Premise включена (переживает перезагрузку)" systemctl is-enabled onprem.service
chk "Docker включён в автозапуск"               systemctl is-enabled docker
chk "в запечённом выпуске нет рабочего .env (паролей до первой настройки нет)" bash -c "[ ! -e /opt/onprem-release/.env ]"
chk "sudoers без NOPASSWD для всех"             bash -c "! grep -rhE '^[^#]*ALL=\\(ALL(:ALL)?\\) +NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v -E '^(%?(sudo|admin|ubuntu|root))'"
if [ -n "${1:-}" ]; then
  if bash "$1" -t; then ok "yc-image-cleanup.sh -t"; else bad "yc-image-cleanup.sh -t"; fi
fi
exit $rc
