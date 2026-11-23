#!/usr/bin/env bash
# Builds <out>/wb-onprem.pyz and wb-onprem.pyz.sha256 (default out: cli/dist).
set -euo pipefail

OUT="${1:-$(dirname "$0")/dist}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
[ -n "$VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }

python3 - wb_onprem "$OUT/wb-onprem.pyz" "$VERSION" <<'PY'
import hashlib, os, sys, zipfile

src, dst, version = sys.argv[1:]
# Fixed time and mode: two builds on one machine give the same bytes.
stamp = (1980, 1, 1, 0, 0, 0)
files = {"__main__.py": b"import sys\nfrom wb_onprem.cli import main\nsys.exit(main())\n",
         "wb_onprem/_version.py": f'__version__ = "{version}"\n'.encode()}
for root, dirs, names in os.walk(src):
    dirs[:] = [d for d in dirs if d != "__pycache__"]
    for name in names:
        if name.endswith(".py") and name != "_version.py":
            path = os.path.join(root, name)
            with open(path, "rb") as f:
                files[os.path.relpath(path).replace(os.sep, "/")] = f.read()
with open(dst, "wb") as out:
    out.write(b"#!/usr/bin/env python3\n")
    with zipfile.ZipFile(out, "w") as z:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, files[name])
os.chmod(dst, 0o755)
with open(dst, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
with open(dst + ".sha256", "w") as f:
    f.write(f"{digest}  {os.path.basename(dst)}\n")
PY

echo "built: $OUT/wb-onprem.pyz ($VERSION)"
