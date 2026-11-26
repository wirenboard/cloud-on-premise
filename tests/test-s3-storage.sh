#!/usr/bin/env bash
# Bundled S3 storage, needs Docker and internet: bash tests/test-s3-storage.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PROJECT="s3test$$"
failures=0

compose() { (cd "$WORK/stack" && docker compose -p "$PROJECT" "$@"); }
cleanup() {
    compose down -v --remove-orphans >/dev/null 2>&1
    docker volume rm "${PROJECT}_minioData" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # description, then the command that has to succeed
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then printf "  ok   %s\n" "$name"
    else printf "  FAIL %s\n" "$name"; failures=$((failures + 1)); fi
}
is() { [ "$1" = "$2" ]; }
has() { [[ $1 =~ $2 ]]; }
lacks() { ! has "$@"; }

echo "generate-env"
keys_case() { # existing .env content -> prints the S3 keys generate-s3-keys leaves
    rm -rf "$WORK/keys"; mkdir -p "$WORK/keys/scripts"
    cp "$ROOT/Makefile" "$ROOT/.env.example" "$ROOT/VERSION" "$WORK/keys/"
    cp "$ROOT/scripts/env.sh" "$WORK/keys/scripts/"
    printf 'ABSOLUTE_SERVER=cloud.example.com\n%s' "$1" > "$WORK/keys/.env"
    make -C "$WORK/keys" generate-s3-keys >/dev/null 2>&1
    grep -E '^MINIO_ROOT_(USER|PASSWORD)=' "$WORK/keys/.env" | tr '\n' ' '
}
first="$(keys_case '')"
check "a fresh .env gets S3 keys" has "$first" '^MINIO_ROOT_USER=[A-Za-z0-9]{20} MINIO_ROOT_PASSWORD=[A-Za-z0-9]{40} $'
check "the keys are random" lacks "$(keys_case '')" "^$first\$"
check "generate-env runs it" \
    awk '/^generate-env:/{f=1; next} f && /^[a-z]/{exit} f && /generate-s3-keys/{found=1} END {exit !found}' "$ROOT/Makefile"
check "keys already in .env are kept" \
    is "$(keys_case $'MINIO_ROOT_USER=legacy_user\nMINIO_ROOT_PASSWORD=legacy_password_123\n')" \
       "MINIO_ROOT_USER=legacy_user MINIO_ROOT_PASSWORD=legacy_password_123 "

# A 2.0.x .env: the storage credentials still carry the MinIO names.
mkdir -p "$WORK/stack" "$WORK/old"
cp "$ROOT/docker-compose.yml" "$WORK/stack/"
cat > "$WORK/stack/.env" <<EOF
VERSION=test
EMAIL_ENABLED=False
DOCKER_NET_NAME=${PROJECT}_net
MINIO_ROOT_USER=legacy_user
MINIO_ROOT_PASSWORD=legacy_password_123
EOF
cp "$WORK/stack/.env" "$WORK/old/"

echo
echo "compose"
config="$(compose config --format json 2>/dev/null)"
query() { printf '%s' "$config" | python3 -c "import json, sys; s = json.load(sys.stdin)['services']; print($1)"; }
check "no MinIO or mc image is left" lacks "$(query '"\n".join(v.get("image", "") for v in s.values())')" '[Mm][Ii][Nn][Ii][Oo]|/mc:'
check "backend gets MINIO_ROOT_USER as its S3 key" is "$(query 's["backend"]["environment"]["AWS_ACCESS_KEY_ID"]')" legacy_user
check "backend talks to seaweedfs" is "$(query 's["backend"]["environment"]["AWS_S3_ENDPOINT_URL"]')" http://seaweedfs:8333
check "backend and tunnel wait for the storage" \
    is "$(query '" ".join(sorted(n for n, v in s.items() if "seaweedfs" in v.get("depends_on", {})))')" "backend tunnel"

# upgrade.sh keeps these running while the application is stopped for the migration.
eval "$(grep '^DATA_SERVICES_RE=' "$ROOT/migration/upgrade.sh")"
check "upgrade.sh treats seaweedfs as data" has seaweedfs "$DATA_SERVICES_RE"
check "upgrade.sh still treats backend as the application" lacks backend "$DATA_SERVICES_RE"

echo
echo "update from 2.0.1"
git -C "$ROOT" show v2.0.1:docker-compose.yml > "$WORK/old/docker-compose.yml"
(cd "$WORK/old" && docker compose -p "$PROJECT" up -d --wait minio >/dev/null 2>&1 &&
                   docker compose -p "$PROJECT" up minio-client >/dev/null 2>&1)
service_containers() { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1"; }
check "2.0.1 MinIO is up before the update" has "$(service_containers minio)" .
# The very `down` `make restart` and scripts/update.sh run, against the 2.1.0 files.
down_cmd="$(awk '/^restart:/{f=1; next} f && /^[a-z]/{exit} f' "$ROOT/Makefile" | grep -o 'docker compose down[^&;]*')"
check "make restart has a docker compose down" has "$down_cmd" .
(cd "$WORK/stack" && export COMPOSE_PROJECT_NAME="$PROJECT" VERSION=test && eval "$down_cmd") >/dev/null 2>&1
check "make restart removes the MinIO container" is "$(service_containers minio)" ""
check "and the minio-client one" is "$(service_containers minio-client)" ""
check "the minioData volume is kept" docker volume inspect "${PROJECT}_minioData"

echo
echo "storage"
check "seaweedfs becomes healthy" compose up -d --wait seaweedfs

probe() {
    docker run --rm -i --network "${PROJECT}_net" python:3.12-alpine sh -c \
        'pip install -q --root-user-action=ignore --disable-pip-version-check boto3 >/dev/null 2>&1 && python - "$@"' -- "$@"
}

PROBE='
import io, sys, urllib.error, urllib.request
import boto3
from boto3.s3.transfer import TransferConfig

def client(key, secret):
    return boto3.client("s3", endpoint_url="http://seaweedfs:8333", aws_access_key_id=key,
                        aws_secret_access_key=secret, region_name="eu-west-1")

def status(url, method="GET", data=None):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method=method, data=data)) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

s3 = client("legacy_user", "legacy_password_123")
key = "diagnostic_data/probe.zip"
if sys.argv[1] == "write":
    body = b"PK\x03\x04" + bytes(range(256)) * 48 * 1024
    # 12 MiB crosses the multipart threshold, as large archives do from the backend.
    s3.upload_fileobj(io.BytesIO(body), "media", key, Config=TransferConfig(multipart_threshold=8 * 1024 * 1024))
    print("upload", "ok")
    print("download", "ok" if s3.get_object(Bucket="media", Key=key)["Body"].read() == body else "differs")
    url = s3.generate_presigned_url("get_object", Params={"Bucket": "media", "Key": key}, ExpiresIn=60)
    print("presigned", status(url))
    print("anonymous", status(f"http://seaweedfs:8333/media/{key}"))
    print("anonymous-list", status("http://seaweedfs:8333/media/"))
    print("filer-get", status(f"http://seaweedfs:8888/buckets/media/{key}"))
    print("filer-put", status("http://seaweedfs:8888/buckets/media/diagnostic_data/x.zip", "PUT", b"x"))
    try:
        client("minio_login", "minio_pass").head_object(Bucket="media", Key=key)
        print("default-creds", "accepted")
    except Exception:
        print("default-creds", "rejected")
else:
    print("after-recreate", "ok" if s3.head_object(Bucket="media", Key=key)["ContentLength"] > 0 else "empty")
'

out="$(probe write <<<"$PROBE" 2>&1)"
field() { printf '%s\n' "$out" | awk -v k="$1" '$1 == k {print $2}'; }
check "an archive uploads with the old .env credentials" is "$(field upload)" ok
check "and downloads intact" is "$(field download)" ok
check "a presigned link downloads it" is "$(field presigned)" 200
check "an anonymous GET is refused" is "$(field anonymous)" 403
check "an anonymous listing is refused" is "$(field anonymous-list)" 403
check "the filer does not serve it without a token" is "$(field filer-get)" 401
check "the filer does not take writes without a token" is "$(field filer-put)" 401
check "the built-in default credentials are refused" is "$(field default-creds)" rejected
is "$(field upload)" ok || printf '%s\n' "$out" | tail -5

weed_shell() {
    echo "$1" | compose run --rm -T --no-deps --entrypoint weed seaweedfs \
        shell -master=seaweedfs:9333 -filer=seaweedfs:8888 2>/dev/null
}
# The filer gRPC port stays open on the network and hands out chunk ids.
fid="$(weed_shell 'fs.meta.cat /buckets/media/diagnostic_data/probe.zip' | awk -F'"' '/"fileId"/ {print $4; exit}')"
check "the volume server does not serve a chunk without a token" \
    is "$(compose run --rm -T --no-deps --entrypoint curl seaweedfs -s -o /dev/null -w '%{http_code}' "http://seaweedfs:9340/$fid" 2>/dev/null)" 401

# Signing keys are generated per start; down + up, as `make update` does, drops the
# image's anonymous /data volume, so the archive survives only on the named one.
compose down >/dev/null 2>&1 && compose up -d --wait seaweedfs >/dev/null 2>&1
out="$(probe read <<<"$PROBE" 2>&1)"
check "the archive survives down and up" is "$(field after-recreate)" ok

echo
if [ "$failures" -ne 0 ]; then echo "FAILED: $failures check(s)"; exit 1; fi
echo "all checks passed"
