#!/usr/bin/env bash
# Тест рендера user-data: tofu apply (без провайдеров) → cloud-init schema → shell-разбор env → shellcheck.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "${TOOLS_ENV:-/work/tools/env.sh}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -r "$here/../../deploy" "$tmp/deploy"   # чтобы не оставлять .terraform в репозитории
cd "$tmp/deploy/tests/render"
tofu init -input=false >/dev/null
tofu apply -auto-approve -input=false >/dev/null
tofu output -raw user_data > "$tmp/user-data.yaml"
fail() { echo "FAIL: $*"; exit 1; }

head -1 "$tmp/user-data.yaml" | grep -qx '#cloud-config' || fail "нет #cloud-config"
cloud-init schema --config-file "$tmp/user-data.yaml" | grep -q 'Valid schema' || fail "cloud-init schema"
echo "ok schema"

python3 -I - "$tmp/user-data.yaml" "$tmp" <<'PY'
import sys, yaml, base64
d = yaml.safe_load(open(sys.argv[1])); out = sys.argv[2]
f = {w["path"]: w for w in d["write_files"]}
open(out + "/install.env", "w").write(f["/etc/onprem/install.env"]["content"])
open(out + "/acme.env", "w").write(f["/etc/onprem/acme.env"]["content"])
open(out + "/install.sh", "wb").write(base64.b64decode(f["/usr/local/sbin/install-onprem.sh"]["content"]))
print("size", len(open(sys.argv[1]).read()))
PY
# значения с кавычками, $ и пробелами доходят до shell без искажений
bash -c 'set -a; . "$1"; [ "$ADMIN_PASSWORD" = "p'"'"'a ss\$w\"d" ] && [ "$ABSOLUTE_SERVER" = cloud.example.com ] && [ "$EMAIL_ENABLED" = True ] && [ "$EMAIL_HOST" = smtp.example.com ] && [ "$EXTRA_ENV" = "WORKER_CONCURRENCY=2" ]' _ "$tmp/install.env" || fail "install.env разбор"
bash -c 'set -a; . "$1"; [ "$YANDEX_CLOUD_IAM_TOKEN" = "t\$ok'"'"'en" ]' _ "$tmp/acme.env" || fail "acme.env разбор"
echo "ok env-quoting"
cmp "$tmp/install.sh" "$here/../cloud-init/install-onprem.sh" || fail "скрипт в user-data отличается от файла"
[ "$(wc -c < "$tmp/user-data.yaml")" -lt 16000 ] || fail "user-data > 16 КБ (лимит AWS)"
echo "ok size"
shellcheck -s bash "$here/../cloud-init/install-onprem.sh" || fail shellcheck
echo "ok shellcheck"
# регрессия Q4.3: автопоиск диска данных не берёт дисковод fd0, cdrom, seed-диск < 1 ГиБ
filt=$(grep -o "awk '\$2==\"disk\"[^']*'" "$here/../cloud-init/install-onprem.sh" | head -1 | sed "s/^awk '//; s/'\$//")
[ -n "$filt" ] || fail "фильтр дисков не найден в install-onprem.sh"
got=$(printf 'fd0 disk 1 4096\nsr0 rom 1 1073741312\nvda disk 0 32212254720\nvdb disk 0 26843545600\nvdc disk 0 395264\nloop0 disk 0 99999999999\n' | awk "$filt" | tr '\n' ' ')
[ "$got" = "vda vdb " ] || fail "фильтр дисков вернул: $got"
echo "ok disk-filter"
# регрессия Q4.8: юнит автозапуска вызывает compose через обёртку, которая берёт VERSION из файла (без неё — «invalid reference format»)
grep -q '^ExecStart=/usr/local/bin/onprem-compose up -d$' "$here/../cloud-init/install-onprem.sh" || fail "юнит не использует onprem-compose"
mkdir -p "$tmp/inst"; printf 'v9.9.9\n' > "$tmp/inst/VERSION"
body=$(sed -n '/<<WRAP$/,/^WRAP$/p' "$here/../cloud-init/install-onprem.sh" | sed '1d;$d')
INSTALL_DIR="$tmp/inst" eval "cat <<WRAP
$body
WRAP" | sed "s#/usr/bin/docker#$tmp/fakedocker#" > "$tmp/wrap.sh"
printf '#!/bin/sh\necho "VERSION=$VERSION args=$*"\n' > "$tmp/fakedocker"; chmod +x "$tmp/fakedocker"
[ "$(sh "$tmp/wrap.sh" up -d)" = "VERSION=v9.9.9 args=compose up -d" ] || fail "обёртка не передаёт VERSION"
echo "ok compose-wrapper"
echo PASS
