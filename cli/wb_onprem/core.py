"""Shared helpers: installation directory, command runner, report output."""

import json
import os
import subprocess
import sys

CONFIG_PATH = "/etc/wb-onprem/config"
DEFAULT_DIR = "/opt/cloud-on-premise"

OK, WARN, FAIL = "ok", "warn", "fail"
_RANK = {OK: 0, WARN: 1, FAIL: 2}
EXIT_START_ERROR = 3


class CliError(Exception):
    """Expected failure to start: printed without a traceback, exit code 3."""


def _is_installation(path):
    return all(os.path.isfile(os.path.join(path, name)) for name in ("docker-compose.yml", "VERSION"))


def _config_dir():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.partition("=")
                if sep and key.strip() == "dir":
                    return value.strip()
    except OSError:
        pass
    return None


def _checked(path, source):
    path = os.path.abspath(path)
    if not _is_installation(path):
        raise CliError(f"not an installation directory: {path} (from {source}; expected docker-compose.yml and VERSION)")
    return path


def find_dir(arg=None):
    """--dir, $WB_ONPREM_DIR, the current directory, the config file, the default directory."""
    if arg is not None:
        return _checked(arg, "--dir")
    if os.environ.get("WB_ONPREM_DIR"):
        return _checked(os.environ["WB_ONPREM_DIR"], "WB_ONPREM_DIR")
    if _is_installation(os.getcwd()):
        return os.getcwd()
    configured = _config_dir()
    if configured is not None:
        return _checked(configured, CONFIG_PATH)
    if _is_installation(DEFAULT_DIR):
        return DEFAULT_DIR
    raise CliError(f"installation directory not found: run from it or pass --dir (or WB_ONPREM_DIR, or dir= in {CONFIG_PATH})")


def worst(statuses):
    return max(statuses, key=lambda s: _RANK[s], default=OK)


def exit_code(status):
    return _RANK[status]


def emit(report, as_json, out=None):
    """report: {'status': ..., 'items': [{'name', 'status', 'detail'}], 'facts': {...}}"""
    out = out or sys.stdout
    if as_json:
        json.dump(report, out, ensure_ascii=False, indent=2)
        out.write("\n")
        return
    mark = {OK: "[ ok ]", WARN: "[warn]", FAIL: "[FAIL]"}
    for key, value in report.get("facts", {}).items():
        out.write(f"{key}: {value}\n")
    for it in report["items"]:
        out.write(f"{mark[it['status']]} {it['name']}: {it['detail']}\n")
    if report.get("changelog"):
        out.write("\nchangelog:\n" + report["changelog"] + "\n")
    out.write(f"overall: {report['status']}\n")


def run(cmd, cwd=None, input=None, timeout=60, env=None):
    """Run a command; never raises. Returns (returncode, stdout, stderr); 127 if missing, 126 if it cannot start."""
    try:
        p = subprocess.run(cmd, cwd=cwd, input=input, capture_output=True, text=True, errors="replace",
                           timeout=timeout, env=env and {**os.environ, **env})
    except FileNotFoundError as e:
        if e.filename == cmd[0]:
            return 127, "", f"{cmd[0]}: command not found"
        return 126, "", f"{cmd[0]}: {e.strerror}: {e.filename}"
    except OSError as e:
        return 126, "", f"{cmd[0]}: {e.strerror}"
    except subprocess.TimeoutExpired:
        return 124, "", f"{' '.join(cmd)}: timed out after {timeout}s"
    return p.returncode, p.stdout, p.stderr


# C locale: git_error matches English messages.
_GIT_ENV = {"GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}


def git(args, cwd, timeout=60):
    return run(["git", *args], cwd=cwd, env=_GIT_ENV, timeout=timeout)


def git_error(err, directory):
    lines = [line for line in err.splitlines() if line.strip()]
    text = next((line for line in lines if line.startswith("fatal:")), lines[-1] if lines else "git failed")
    if "dubious ownership" in err:
        text += f"; run wb-onprem as the owner of {directory}"
    return text


def read_version(directory):
    try:
        with open(os.path.join(directory, "VERSION"), encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def compose(directory, args, timeout=60):
    """`docker compose ...` in the installation with VERSION exported, as the Makefile does."""
    return run(["docker", "compose", *args], cwd=directory, env={"VERSION": read_version(directory) or ""},
               timeout=timeout)


# $(info) prints the value as make sees it; a shell echo would glob *.domain against the directory.
_PRINT_VAR = "print-var:\n\t$(info $($(VAR)))\n"


def make_var(directory, name):
    """Value of a variable of the installation Makefile, or None if make cannot tell."""
    code, out, _ = run(["make", "-s", "--no-print-directory", "-f", "Makefile", "-f", "-", "print-var", f"VAR={name}"],
                       cwd=directory, input=_PRINT_VAR)
    if code != 0:
        return None
    return out.rstrip("\n")
