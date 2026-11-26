#!/usr/bin/env python3
"""Anonymous registry checks for the on-premise images: pullability and the version label."""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

MANIFEST_TYPES = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
VERSION_LABEL = "on-premise.version"
BACKEND_IMAGES = ["wbc-backend", "wbc-worker", "wbc-agent-backend", "wbc-scheduler"]
TIMEOUT = 30


def compose_images(text, version):
    images = []
    for match in re.finditer(r"^\s+image:\s*[\"']?([^\s\"'#]+)", text, re.M):
        image = match.group(1).replace("${VERSION}", version)
        if "$" in image:
            raise ValueError(f"unresolved variable in image reference: {image}")
        if image not in images:
            images.append(image)
    return images


def parse_reference(image):
    name, tag = image, "latest"
    last = image.rsplit("/", 1)[-1]
    if ":" in last:
        name, tag = image.rsplit(":", 1)
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        registry, path = first, rest
    else:
        registry, path = "docker.io", name
    if registry == "docker.io":
        registry = "registry-1.docker.io"
        if "/" not in path:
            path = f"library/{path}"
    return registry, path, tag


def version_label_error(labels, version):
    value = (labels or {}).get(VERSION_LABEL)
    if value is None:
        return f"label {VERSION_LABEL} is missing"
    if value != version:
        hint = " (the image would show -testing after the retag, see cloud-backend#352)" if value.endswith("-testing") else ""
        return f"label {VERSION_LABEL}={value}, expected {version}{hint}"
    return None


def pick_platform(index, os_name="linux", arch="amd64"):
    for entry in index.get("manifests", []):
        platform = entry.get("platform", {})
        if platform.get("os") == os_name and platform.get("architecture") == arch:
            return entry["digest"]
    raise LookupError(f"no {os_name}/{arch} manifest in the index")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


class Registry:
    def __init__(self, registry, path):
        self.base = f"https://{registry}/v2/{path}"
        self.path = path
        self.token = None

    def _authorize(self, challenge):
        scheme, _, params = challenge.partition(" ")
        if scheme.lower() != "bearer":
            raise PermissionError(f"unsupported auth challenge: {challenge}")
        fields = dict(re.findall(r'(\w+)="([^"]*)"', params))
        query = {"scope": f"repository:{self.path}:pull"}
        if "service" in fields:
            query["service"] = fields["service"]
        url = f"{fields['realm']}?{urllib.parse.urlencode(query)}"
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
            body = json.load(response)
        self.token = body.get("token") or body.get("access_token")
        if not self.token:
            raise PermissionError(f"no anonymous token for {self.path}")

    def _open(self, method, url, accept):
        headers = {"Accept": accept} if accept else {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            with _opener.open(urllib.request.Request(url, method=method, headers=headers), timeout=TIMEOUT) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308):
                # Blob storage redirects reject the registry token, so follow them without it.
                with urllib.request.urlopen(error.headers["Location"], timeout=TIMEOUT) as response:
                    return response.read()
            raise

    def request(self, method, url, accept=None):
        try:
            return self._open(method, url, accept)
        except urllib.error.HTTPError as error:
            if error.code != 401 or self.token or "WWW-Authenticate" not in error.headers:
                raise
            self._authorize(error.headers["WWW-Authenticate"])
        return self._open(method, url, accept)

    def manifest(self, reference, method="GET"):
        return self.request(method, f"{self.base}/manifests/{reference}", MANIFEST_TYPES)

    def labels(self, tag):
        manifest = json.loads(self.manifest(tag))
        if "manifests" in manifest:
            manifest = json.loads(self.manifest(pick_platform(manifest)))
        config = json.loads(self.request("GET", f"{self.base}/blobs/{manifest['config']['digest']}"))
        return config.get("config", {}).get("Labels")


def describe(error):
    if isinstance(error, urllib.error.HTTPError):
        return f"HTTP {error.code}"
    return f"{type(error).__name__}: {error}"


def check_pullable(images):
    rows, failed = [], 0
    for image in images:
        registry, path, tag = parse_reference(image)
        try:
            Registry(registry, path).manifest(tag, method="HEAD")
            rows.append((image, "ok"))
        except Exception as error:
            rows.append((image, f"NOT PULLABLE: {describe(error)}"))
            failed += 1
    return rows, failed


def check_labels(images, version):
    rows, failed = [], 0
    for image in images:
        registry, path, tag = parse_reference(image)
        try:
            error = version_label_error(Registry(registry, path).labels(tag), version)
        except Exception as exc:
            error = describe(exc)
        rows.append((image, error or f"{VERSION_LABEL}={version}"))
        failed += error is not None
    return rows, failed


def report(title, rows, failed):
    width = max(len(image) for image, _ in rows)
    print(title)
    for image, result in rows:
        print(f"  {image:<{width}}  {result}")
    print(f"{failed} of {len(rows)} failed" if failed else f"all {len(rows)} passed")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"### {title}\n\n| image | result |\n|---|---|\n")
            out.writelines(f"| `{image}` | {result} |\n" for image, result in rows)
            out.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    pullable = sub.add_parser("pullable", help="every compose image resolves anonymously")
    pullable.add_argument("--compose", default="docker-compose.yml")
    pullable.add_argument("--version-file", default="VERSION")
    pullable.add_argument("extra", nargs="*", help="additional image references to check")

    label = sub.add_parser("label", help=f"backend images carry {VERSION_LABEL}=VERSION")
    label.add_argument("--version", required=True, help="X.Y.Z expected in the label")
    label.add_argument("--tag", required=True, help="image tag to inspect, e.g. X.Y.Z-testing")
    label.add_argument("--prefix", default="ghcr.io/wirenboard/on-premise")

    args = parser.parse_args(argv)
    if args.command == "pullable":
        with open(args.version_file, encoding="utf-8") as f:
            version = f.read().strip()
        with open(args.compose, encoding="utf-8") as f:
            images = compose_images(f.read(), version) + args.extra
        rows, failed = check_pullable(images)
        report(f"Anonymous pull of compose images ({version})", rows, failed)
    else:
        images = [f"{args.prefix}/{name}:{args.tag}" for name in BACKEND_IMAGES]
        rows, failed = check_labels(images, args.version)
        report(f"Version label of backend images ({args.tag})", rows, failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
