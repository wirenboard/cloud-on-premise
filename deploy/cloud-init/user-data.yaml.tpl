#cloud-config
# Рендерится модулем terraform/modules/user-data (templatefile). Значения env уже в кавычках для shell.
package_update: false
write_files:
  - path: /etc/onprem/install.env
    permissions: "0600"
    owner: root:root
    content: |
%{ for k, v in install_env ~}
      ${k}=${v}
%{ endfor ~}
  - path: /etc/onprem/acme.env
    permissions: "0600"
    owner: root:root
    content: |
      # ключи DNS-провайдера для lego (DNS-01)
%{ for k, v in acme_env ~}
      ${k}=${v}
%{ endfor ~}
  - path: /usr/local/sbin/install-onprem.sh
    permissions: "0755"
    owner: root:root
    encoding: b64
    content: ${install_script_b64}
%{ if tls_fullchain_b64 != "" ~}
  - path: /etc/onprem/tls/fullchain.pem
    permissions: "0644"
    owner: root:root
    encoding: b64
    content: ${tls_fullchain_b64}
  - path: /etc/onprem/tls/privkey.pem
    permissions: "0600"
    owner: root:root
    encoding: b64
    content: ${tls_privkey_b64}
%{ endif ~}
runcmd:
  - [ bash, -c, "/usr/local/sbin/install-onprem.sh || { echo 'onprem install failed, see /var/log/onprem-install.log'; exit 1; }" ]
final_message: "on-premise: cloud-init завершён за $UPTIME с"
