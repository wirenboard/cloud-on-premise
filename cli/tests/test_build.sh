#!/usr/bin/env bash
# build.sh: two builds are byte-identical, the checksum file verifies, the pyz reports the repository VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."
A="$(mktemp -d)"; B="$(mktemp -d)"; trap 'rm -rf "$A" "$B"' EXIT
./build.sh "$A" >/dev/null
sleep 2  # a wall-clock timestamp in the archive would differ
./build.sh "$B" >/dev/null
cmp "$A/wb-onprem.pyz" "$B/wb-onprem.pyz"
rm -f dist/wb-onprem.pyz dist/wb-onprem.pyz.sha256
./build.sh >/dev/null  # the release job builds into the default cli/dist
cmp "$A/wb-onprem.pyz" dist/wb-onprem.pyz
(cd "$A" && sha256sum -c wb-onprem.pyz.sha256 >/dev/null)
grep -qx '[0-9a-f]\{64\}  wb-onprem.pyz' "$A/wb-onprem.pyz.sha256"
[ "$(python3 "$A/wb-onprem.pyz" --version)" = "wb-onprem $(tr -d '[:space:]' < ../VERSION)" ]
echo "OK test_build"
