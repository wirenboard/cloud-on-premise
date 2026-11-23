"""`doctor`: the usual breakages, each with what to do about it."""

import os
import re

from . import core, status
from .core import FAIL, OK, WARN
from .status import item

HELP = "find the usual breakages and say how to fix them"

TAIL_LINES = 8
DOCKER_PROCESSES = ("docker-proxy", "dockerd", "rootlesskit")


def add_arguments(parser):
    pass


def docker_item():
    # `docker info --format` exits 0 with empty output when the daemon is unreachable; `docker version` exits 1.
    code, out, err = core.run(["docker", "version", "--format", "{{.Server.Version}}"])
    if code == 127:
        return item("docker", FAIL, "docker not found, install Docker Engine with the compose plugin")
    if code != 0 or not out.strip():
        if "permission denied" in err.lower():
            return item("docker", FAIL, "permission denied on the Docker socket, run as root")
        return item("docker", FAIL, "Docker is not running, start it with `systemctl start docker`")
    return item("docker", OK, f"engine {out.strip()}")


def log_command(service):
    return f"VERSION=$(cat VERSION) docker compose logs {service}"


def log_tail(directory, service):
    _, out, _ = core.compose(directory, ["logs", "--no-color", "--tail", str(TAIL_LINES), service])
    # Escape sequences from a container log would drive the terminal.
    return ["".join(c if c.isprintable() else "?" for c in line) for line in out.strip().splitlines()[-TAIL_LINES:]]


def container_items(directory, services, with_logs):
    """(items, ok services): broken ones with the log command and, if `with_logs`, the tail; all ok is one item."""
    items = status.service_items(directory, services)
    healthy = {it["name"] for it in items if it["status"] == OK and it["name"] in services}
    broken = [it for it in items if it["status"] != OK]
    if not broken:
        return [item("containers", OK, f"{len(items)} services running or completed")], healthy
    for it in broken:
        if it["name"] not in services:
            continue
        tail = log_tail(directory, it["name"]) if with_logs else []
        it["detail"] += f"; log: `{log_command(it['name'])}`, after the fix `make run`"
        it["detail"] += "".join(f"\n    | {line}" for line in tail)
    return broken, healthy


def env_item(directory):
    path = os.path.join(directory, ".env")
    if not os.path.isfile(path) or not os.path.getsize(path):
        return item(".env", FAIL, "missing or empty, copy .env.example and run `make check-env`")
    code, out, _ = core.run(["make", "-s", "check-env"], cwd=directory)
    if code == 127:
        return item(".env", WARN, "make not found, cannot run `make check-env`")
    if code != 0:
        # Only the ERROR lines: they name the variable, and print values only of non-secret ones.
        lines = (re.sub(r"\x1b\[[0-9;]*m", "", line).strip() for line in out.splitlines())
        errors = [line.removeprefix("ERROR: ") for line in lines if line.startswith("ERROR: ")]
        return item(".env", FAIL, "; ".join(errors + ["run `make check-env`"]))
    return item(".env", OK, "make check-env passed")


def public_key(cmd):
    code, out, _ = core.run(cmd)
    return out.strip() if code == 0 and "BEGIN PUBLIC KEY" in out else None


def key_item(cert, privkey):
    if not os.access(privkey, os.R_OK):
        return item("certificate key", WARN, f"cannot read {privkey}, run as root")
    cert_key = public_key(["openssl", "x509", "-noout", "-pubkey", "-in", cert])
    if cert_key is None:
        return item("certificate key", FAIL, f"{cert}: openssl cannot read the certificate")
    key = public_key(["openssl", "pkey", "-pubout", "-passin", "pass:", "-in", privkey])
    if key is None:
        return item("certificate key", FAIL, f"{privkey}: openssl cannot read the private key")
    if key != cert_key:
        return item("certificate key", FAIL,
                    f"{privkey} does not match {cert}, put the matching pair there and run `make reload-certs`")
    return item("certificate key", OK, f"{privkey} matches the certificate")


def rsa_only_check_certs(directory):
    """Whether `make check-certs` of the installation compares RSA moduli (2.0.x) rather than public keys."""
    try:
        with open(os.path.join(directory, "Makefile"), encoding="utf-8", errors="replace") as f:
            recipe = re.search(r"(?m)^check-certs:.*\n((?:\t.*\n|\n)*)", f.read())
    except OSError:
        return False
    return bool(recipe) and "pkey -pubout" not in recipe.group(1)


def rsa_key_item(directory, privkey, key):
    if key["status"] != OK or not rsa_only_check_certs(directory):
        return key
    code, _, _ = core.run(["openssl", "rsa", "-noout", "-modulus", "-passin", "pass:", "-in", privkey])
    if code == 0:
        return key
    return item("certificate key", WARN, f"{privkey} matches the certificate, but this release's `make check-certs` "
                                         f"accepts only RSA keys: use an RSA key or update the installation")


def cert_names(path):
    """DNS names of the subjectAltName, or None; parsed from `-text` the way `make check-certs` does."""
    code, out, _ = core.run(["openssl", "x509", "-noout", "-text", "-in", path])
    if code != 0:
        return None
    lines = out.splitlines()
    return [name.strip().removeprefix("DNS:") for i, line in enumerate(lines[:-1])
            if "X509v3 Subject Alternative Name" in line for name in lines[i + 1].split(",")]


def names_item(directory, cert):
    value = core.make_var(directory, "REQUIRED_DOMAINS")
    required = (value or "").split()
    if not required or any(name.endswith(".") for name in required):
        return item("certificate names", WARN,
                    "cannot determine required names (REQUIRED_DOMAINS from the Makefile, ABSOLUTE_SERVER in .env)")
    names = cert_names(cert)
    if names is None:
        return item("certificate names", WARN, f"{cert}: openssl cannot read the names")
    missing = [name for name in required if name not in names]
    if missing:
        return item("certificate names", FAIL,
                    f"{cert} does not cover {', '.join(missing)}, issue one that does and run `make reload-certs`")
    return item("certificate names", OK, f"covers {', '.join(required)}")


def cert_items(directory, now=None):
    """`make check-certs` without writing fullchain.pem."""
    tls = status.tls_dir(directory)
    if not tls:
        return [item("certificate", WARN, "cannot determine TLS_DIR from the Makefile")]
    privkey, fullchain, cert, chain = (os.path.join(tls, name)
                                       for name in ("privkey.pem", "fullchain.pem", "cert.pem", "chain.pem"))
    for path in (privkey, fullchain):
        if os.path.isdir(path):
            return [item("certificate files", FAIL, f"{path} is a directory, Docker created it when the stack started "
                                                    f"without the file: `rmdir` it, put the file there, "
                                                    f"run `make reload-certs`")]
    if not os.path.isfile(privkey):
        return [item("certificate files", FAIL, f"{privkey} not found, put the key there and run `make reload-certs`")]
    if os.path.isfile(fullchain):
        path, files = fullchain, item("certificate files", OK, f"{fullchain}, {privkey}")
    elif os.path.isfile(cert) and os.path.isfile(chain):
        path, files = cert, item("certificate files", WARN, f"{fullchain} not found, "
                                 "run `make check-certs` to build it from cert.pem and chain.pem")
    else:
        return [item("certificate files", FAIL,
                     f"{fullchain} not found, put the certificate there and run `make reload-certs`")]
    expiry = status.expiry_item(path, now)
    if expiry["status"] != OK:
        expiry["detail"] += ", renew it and run `make reload-certs`"
    return [files, rsa_key_item(directory, privkey, key_item(path, privkey)), expiry, names_item(directory, path)]


def disk_items(directory):
    items = status.disk_items(directory)
    for it in items:
        if it["status"] != OK:
            it["detail"] += ", free up space or grow the disk"
    return items


def published_ports(services):
    """{port: services publishing it}"""
    ports = {}
    for name, service in services.items():
        for port in service.get("ports") or ():
            if str(port.get("published", "")).isdigit():
                ports.setdefault(int(port["published"]), set()).add(name)
    return ports


def listeners():
    """{port: process names, None among them when ss hides one (not root)}, or None if ss failed."""
    code, out, _ = core.run(["ss", "-H", "-ltnp"])
    if code != 0:
        return None
    found = {}
    for line in out.splitlines():
        cols = line.split()
        port = re.search(r":(\d+)$", cols[3]) if len(cols) > 3 else None
        if port:
            process = re.search(r'users:\(\("([^"]+)"', line)
            found.setdefault(int(port.group(1)), set()).add(process.group(1) if process else None)
    return found


def port_items(services, healthy):
    """`healthy`: services that are running; a hidden owner of a port they publish is taken to be Docker."""
    ports = published_ports(services)
    found = listeners()
    if found is None:
        return [item("ports", WARN, "cannot list listening ports with `ss -ltnp`")]
    if not ports:
        return [item("ports", OK, "the stack publishes no ports")]
    items = []
    for port, publishers in sorted(ports.items()):
        owners = found.get(port, set())
        foreign = sorted(owners - {None, *DOCKER_PROCESSES})
        down = sorted(publishers - healthy)
        if foreign:
            items.append(item(f"port {port}", FAIL,
                              f"taken by {', '.join(foreign)}, stop it or publish the stack on another port"))
        elif None in owners and down:
            items.append(item(f"port {port}", WARN,
                              f"in use while {', '.join(down)} is not running, run as root to see by whom"))
    return items or [item("ports", OK, ", ".join(map(str, sorted(ports))) + " free or used by Docker")]


def clock_item():
    code, out, _ = core.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    if code != 0:
        return item("clock", WARN, "cannot check time synchronization with timedatectl")
    if out.strip() != "yes":
        return item("clock", WARN, "not synchronized, enable it with `timedatectl set-ntp true`")
    return item("clock", OK, "synchronized")


def build(directory, args):
    installation, one_x = status.installation_item(directory)
    if one_x:
        items = [installation]
    else:
        items = [installation] if installation else []
        docker = docker_item()
        items.append(docker)
        services = None
        if docker["status"] == OK:
            services, failed = status.compose_config(directory)
            if failed:
                items.append(failed)
            else:
                containers, healthy = container_items(directory, services, not getattr(args, "json", False))
                items += containers
        items.append(env_item(directory))
        items += cert_items(directory)
        items += disk_items(directory)
        if services is not None:
            items += port_items(services, healthy)
        items.append(clock_item())
    return {"status": core.worst(it["status"] for it in items), "items": items, "facts": status.facts(directory)}
