#!/usr/bin/env bash
# Последний шаг сборки: образ не должен нести секретов и состояния сборки.
set -euo pipefail
# служебного пользователя сборки (qemu) удаляет shutdown_command: из-под его же ssh-сессии это не сделать
rm -rf /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys /tmp/install-onprem.sh /tmp/cleanup.sh /tmp/bake.env
rm -f /etc/ssh/ssh_host_*
# Требования площадок (Yandex Marketplace): вход по паролю выключен, истории и аренд DHCP нет, swap в fstab нет.
# 50-cloud-init.conf остаётся от сборки (ssh_pwauth: true в seed Packer) и перебивает 60-cloudimg-settings.conf
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
rm -f /root/.bash_history /home/*/.bash_history /var/lib/dhcp/dhclient.* /var/lib/dhcp/*.leases
rm -f /var/lib/systemd/network/*.lease 2>/dev/null || true
sed -i '/\sswap\s/d' /etc/fstab
cloud-init clean --logs --seed --machine-id
rm -f /var/log/onprem-bake.log.old
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --rotate >/dev/null 2>&1 || true; journalctl --vacuum-time=1s >/dev/null 2>&1 || true
# ключи ssh-хоста создаст cloud-init при первой загрузке
sync
