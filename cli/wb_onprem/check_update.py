"""`check-update`: a newer release, its CHANGELOG_EN.md excerpt and the .env variables new in it."""

import os
import re
import tempfile

from . import core, status
from .core import FAIL, OK, WARN
from .status import item

HELP = "newer release, its changelog and the .env variables new in it"

_VERSION = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-testing)?$")
_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
_CREDENTIALS = re.compile(r"(\w+://)[^/\s]*@")
_QUERY_FRAGMENT = re.compile(r"(\w+://[^\s?#'\"]*)[?#][^\s'\"]*")
_NAME = re.compile(r"^\s*(#?)([A-Za-z_][A-Za-z0-9_]*)=", re.M)


def add_arguments(parser):
    parser.add_argument("--remote", default="origin", help="git remote name, URL or path with release tags "
                                                         "(default: origin)")


def redact(text):
    return _QUERY_FRAGMENT.sub(r"\1", _CREDENTIALS.sub(r"\1", text))


def parse_version(text):
    m = _VERSION.match((text or "").strip())
    return tuple(int(x) for x in m.groups()) if m else None


def remote_url(directory, remote):
    """URL of the remote, or `remote` itself when it is not a remote name. (url, error)."""
    code, out, err = core.git(["remote", "get-url", remote], directory)
    if code == 0:
        return out.strip(), None
    if "dubious ownership" in err:
        return None, core.git_error(err, directory)
    # ls-remote runs in the installation, fetch in a temporary directory: a relative path must mean the same.
    path = os.path.join(directory, remote)
    return (os.path.abspath(path) if os.path.exists(path) else remote), None


def list_tags(directory, url):
    """[(version, tag)] of vX.Y.Z tags, oldest first. (tags, error)."""
    code, out, err = core.git(["ls-remote", "--tags", "--refs", "--", url], directory, timeout=30)
    if code != 0:
        return None, core.git_error(err, directory)
    tags = []
    for line in out.splitlines():
        tag = line.rpartition("refs/tags/")[2]
        m = _TAG.match(tag)
        if m:
            tags.append((tuple(int(x) for x in m.groups()), tag))
    return sorted(tags), None


def read_tag(url, config, tag, paths):
    """Files of the tag (None if absent) via a temporary bare repository; the installation .git is not touched."""
    with tempfile.TemporaryDirectory() as tmp:
        code, _, err = core.git(["init", "-q", "--bare", tmp], tmp)
        if code == 0:
            code, _, err = core.git(["-c", f"include.path={config}", "fetch", "-q", "--depth", "1",
                                     "--end-of-options", url, "tag", tag], tmp, timeout=120)
        if code != 0:
            return None, core.git_error(err, tmp)
        files = {}
        for path in paths:
            code, out, _ = core.git(["show", f"{tag}:{path}"], tmp)
            files[path] = out if code == 0 else None
        return files, None


def changelog_between(text, current, target):
    """Sections `## [X.Y.Z]` with current < X.Y.Z <= target."""
    keep = []
    for part in re.split(r"(?m)^(?=## \[)", text):
        m = re.match(r"## \[([^\]]+)\]", part)
        version = parse_version(m.group(1)) if m else None
        if version and current < version <= target:
            keep.append(part.rstrip() + "\n")
    return "\n".join(keep)


def names(text, commented=False):
    """Names of `NAME=value` lines, or of `#NAME=value` ones with `commented`; values are never kept."""
    return [name for mark, name in _NAME.findall(text) if bool(mark) == commented]


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def env_items(directory, tag, example):
    if example is None:
        return [item(".env", WARN, f"cannot read .env.example of {tag}")]
    installed = [read_text(os.path.join(directory, name)) for name in (".env.example", ".env")]
    known = {name for text in installed for name in names(text)}
    new = [name for name in names(example) if name not in known]
    if new:
        items = [item(".env", WARN, f"new in {tag}: {', '.join(new)} (see .env.example of {tag})")]
    else:
        items = [item(".env", OK, f"no new uncommented variables in .env.example of {tag}")]
    known |= {name for text in installed for name in names(text, commented=True)} | set(names(example))
    optional = [name for name in names(example, commented=True) if name not in known]
    if optional:
        items.append(item(".env optional", OK, f"new optional variables in {tag}: {', '.join(optional)}"))
    return items


def check(directory, remote, facts):
    installation, one_x = status.installation_item(directory)
    if one_x:
        return [item("update", WARN, "1.x installation: run `make upgrade` to move to 2.x")], None
    items = [installation] if installation else []
    installed = core.read_version(directory)
    current = parse_version(installed)
    if current is None:
        return items + [item("version", FAIL, f"cannot read a release version from VERSION ({installed!r})")], None
    url, error = remote_url(directory, remote)
    if error:
        return items + [item("remote", FAIL, f"cannot read the URL of '{remote}': {error}")], None
    facts["remote"] = url
    tags, error = list_tags(directory, url)
    if error:
        return items + [item("remote", FAIL, f"cannot list tags of {url}: {error}")], None
    newer = [(version, tag) for version, tag in tags if version > current]
    if not newer:
        return items + [item("update", OK, f"{installed} is the newest release")], None
    target, tag = newer[-1]
    available = facts["available"] = tag[1:]
    if target[0] > current[0]:
        items.append(item("update", WARN, f"{installed} -> {available} is a major release: "
                                          f"read its release notes before updating"))
    else:
        items.append(item("update", OK, f"{installed} -> {available} is available"))
    files, error = read_tag(url, os.path.join(directory, ".git", "config"), tag, ["CHANGELOG_EN.md", ".env.example"])
    if error:
        return items + [item("notes", WARN, f"found {tag}, cannot read its notes: {error}")], None
    items += env_items(directory, tag, files[".env.example"])
    if files["CHANGELOG_EN.md"] is None:
        return items + [item("notes", WARN, f"cannot read CHANGELOG_EN.md of {tag}")], None
    return items, changelog_between(files["CHANGELOG_EN.md"], current, target)


def build(directory, args):
    facts = status.facts(directory)
    items, changelog = check(directory, args.remote, facts)
    items = [{**it, "detail": redact(it["detail"])} for it in items]
    report = {"status": core.worst(it["status"] for it in items), "items": items,
              "facts": {key: redact(value) for key, value in facts.items()}}
    if changelog:
        report["changelog"] = changelog
    return report
