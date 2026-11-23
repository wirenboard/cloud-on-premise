"""`status`: version, state of every service, disk space, certificate expiry."""

import datetime
import json
import os
import shutil
import ssl

from . import __version__, core
from .core import FAIL, OK, WARN

HELP = "version, services, disk space and certificate expiry"

DISK_WARN_PERCENT = 15
DISK_FAIL_PERCENT = 5
CERT_WARN_DAYS = 14


def add_arguments(parser):
    pass


def item(name, status, detail):
    return {"name": name, "status": status, "detail": detail}


def git_describe(directory):
    # `describe --dirty` refreshes the index and rewrites .git/index, even with --no-optional-locks.
    code, out, err = core.git(["describe", "--tags", "--always"], directory)
    if "dubious ownership" in err:
        return f"unknown, {core.git_error(err, directory)}"
    if code != 0 or not out.strip():
        return None
    code, changes, _ = core.git(["--no-optional-locks", "status", "--porcelain", "--untracked-files=no"], directory)
    return out.strip() + ("-dirty" if code == 0 and changes.strip() else "")


def facts(directory):
    return {
        "directory": directory,
        "version": core.read_version(directory) or "unknown (VERSION is empty)",
        "git": git_describe(directory) or "not a git checkout",
        "wb-onprem": __version__,
    }


def _ps_rows(text):
    # NDJSON since compose 2.21, a single JSON array before.
    text = text.strip()
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def _one_shot(service):
    return service.get("restart", "no") == "no"


def _row_item(name, row, one_shot):
    state, health, code = row.get("State", ""), row.get("Health", ""), row.get("ExitCode") or 0
    if state == "exited":
        detail = f"exited, exit code {code}"
        if one_shot and code == 0:
            return item(name, OK, "completed (exited 0)")
        return item(name, FAIL, detail if one_shot else f"{detail}, should be running")
    detail = state + (f" ({health})" if health else "")
    if state != "running" or health == "unhealthy":
        return item(name, FAIL, detail)
    return item(name, WARN if health == "starting" else OK, detail)


def compose_config(directory):
    """(services of `docker compose config`, None) or (None, fail item); compose stderr may hold .env values."""
    code, out, _ = core.compose(directory, ["config", "--format", "json"])
    if code != 0:
        return None, item("services", FAIL, "docker compose config failed, run `make check-env`")
    try:
        services = json.loads(out)["services"]
    except (ValueError, KeyError, TypeError):
        return None, item("services", FAIL, "cannot parse `docker compose config` output")
    return services, None


def service_items(directory, services):
    """One item per service; compose stderr is never shown."""
    code, out, _ = core.compose(directory, ["ps", "--all", "--format", "json"])
    if code != 0:
        return [item("containers", FAIL, "docker compose ps failed, is Docker running?")]
    try:
        rows = _ps_rows(out)
    except ValueError:
        return [item("containers", FAIL, "cannot parse `docker compose ps` output")]
    if not rows:
        return [item("containers", FAIL, "stack is not running, start it with `make run`")]
    items = []
    for name in sorted(services):
        found = [_row_item(name, r, _one_shot(services[name])) for r in rows if r.get("Service") == name]
        if not found:
            items.append(item(name, FAIL, "no container"))
        else:
            items.append(max(found, key=lambda it: core.exit_code(it["status"])))
    return items


def device(path):
    return os.stat(path).st_dev


def docker_root():
    code, out, _ = core.run(["docker", "info", "--format", "{{.DockerRootDir}}"])
    path = out.strip()
    return path if code == 0 and os.path.isdir(path) else None


def disk_item(path):
    name = f"disk {path}"
    try:
        usage = shutil.disk_usage(path)
    except OSError as e:
        return item(name, WARN, f"cannot read free space: {e.strerror}")
    if not usage.total:
        return item(name, WARN, "cannot read disk size")
    percent = usage.free * 100 // usage.total
    status = FAIL if percent < DISK_FAIL_PERCENT else WARN if percent < DISK_WARN_PERCENT else OK
    return item(name, status, f"{usage.free / 2**30:.1f} GiB free of {usage.total / 2**30:.1f} GiB ({percent}%)")


def disk_items(directory):
    """`/`, the Docker root and the installation, each device once."""
    seen, items = set(), []
    for path in ("/", docker_root(), directory):
        if path and device(path) not in seen:
            seen.add(device(path))
            items.append(disk_item(path))
    return items


def cert_end(path):
    """notAfter of the first certificate in the file, or None if openssl cannot tell."""
    code, out, _ = core.run(["openssl", "x509", "-noout", "-enddate", "-in", path])
    if code != 0 or not out.startswith("notAfter="):
        return None
    try:
        seconds = ssl.cert_time_to_seconds(out.strip().removeprefix("notAfter="))
    except ValueError:
        return None
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc)


def cert_item(directory, now=None):
    """Expiry only; the full certificate check is `doctor`."""
    tls = tls_dir(directory)
    if not tls:
        return item("certificate", WARN, "cannot determine TLS_DIR from the Makefile")
    paths = [os.path.join(tls, name) for name in ("fullchain.pem", "cert.pem")]
    path = next((p for p in paths if os.path.isfile(p)), None)
    if path is None:
        return item("certificate", FAIL, f"{paths[0]} not found, run `make check-certs`")
    return expiry_item(path, now)


def tls_dir(directory):
    value = core.make_var(directory, "TLS_DIR")
    return os.path.normpath(os.path.join(directory, value)) if value else None


def expiry_item(path, now=None):
    end = cert_end(path)
    if end is None:
        return item("certificate", WARN, f"{path}: cannot read the expiry date with openssl")
    left = end - (now or datetime.datetime.now(datetime.timezone.utc))
    if left <= datetime.timedelta(0):
        return item("certificate", FAIL, f"{path}: expired {end:%Y-%m-%d}")
    status = WARN if left < datetime.timedelta(days=CERT_WARN_DAYS) else OK
    return item("certificate", status, f"{path}: expires {end:%Y-%m-%d} ({left.days} days left)")


def installation_item(directory):
    """None for 2.x. A 1.x Makefile has no check-not-1x; a 2.x one fails it on a 1.x .env or running 1.x images."""
    code, _, _ = core.run(["make", "-s", "check-not-1x"], cwd=directory)
    if code == 127:
        return item("installation", WARN, "make not found, cannot tell a 1.x installation from 2.x")
    if code != 0:
        return item("installation", FAIL, "1.x installation: run `make upgrade` first")
    return None


def build(directory, args):
    installation = installation_item(directory)
    if installation and installation["status"] == FAIL:
        items = [installation]
    else:
        services, failed = compose_config(directory)
        items = ([installation] if installation else []) + ([failed] if failed else service_items(directory, services))
        items += disk_items(directory)
        items.append(cert_item(directory))
    return {"status": core.worst(it["status"] for it in items), "items": items, "facts": facts(directory)}
