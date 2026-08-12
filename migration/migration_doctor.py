#!/usr/bin/env python3
"""
migration_doctor — Wiren Board Cloud On-Premise 1.x → 2.0 user-table repair tool.

Why this exists
---------------
Cloud-backend migration ``users/0013_alter_user_options_alter_user_email_and_more``
makes ``email`` ``unique`` and adds a ``CheckConstraint(username == email)`` with
**no data migration**. On a populated 1.x database that migration aborts because:

  * the on-premise admin is created with ``username="admin"`` / ``email=""``
    (1.x default ``ADMIN_EMAIL=""``) → violates ``username == email``;
  * any blank / duplicate / mismatched emails break the ``unique`` / check steps.

There is no upstream repair migration, so we fix the data here, *before* migrate.

How it runs
-----------
This script is mounted into and executed **inside the backend container**, on the
still-running 1.x backend image (which boots without the new TimescaleDB env), via
Django's ``manage.py shell``::

    docker compose run --rm -v ./migration:/migration backend \\
        uv run --no-dev ./manage.py shell -c "exec(open('/migration/migration_doctor.py').read())" -- <args>

The ``make`` targets wrap that for you (``make fix-users``, ``make upgrade``).

It touches **only** ``username`` / ``email`` on the user table, through the Django
ORM (``get_user_model()``), so it works on both the 1.x and 2.0 images. It is
idempotent and resumable: re-run until it reports 0 conflicts. It exits non-zero
while any conflict remains, which is what gates ``make upgrade``.

Modes
-----
  scan                 read-only; print the per-row conflict table + counts.
  auto                 apply only the SAFE automatic fixes, then re-scan.
  resolve              auto-fix, then an interactive per-conflict wizard (TTY).
  dump   [FILE]        auto-fix, then write remaining conflicts to conflicts.yaml.
  apply  [FILE]        read conflicts.yaml back and apply the operator's emails.

A single detector + a single validator back every mode.
"""

import argparse
import os
import re
import sys

# ----------------------------------------------------------------------------
# Django bootstrap.
#
# When run via ``manage.py shell -c "exec(open(...).read())"`` Django is already
# configured, so this is a no-op. When run as a plain script inside the image we
# set it up ourselves so the file is also directly executable / importable.
# ----------------------------------------------------------------------------
try:
    from django.contrib.auth import get_user_model
    from django.db import transaction
except ImportError:  # pragma: no cover - only outside a Django image
    sys.stderr.write("ERROR: Django not importable. Run me inside the backend container.\n")
    raise

try:
    get_user_model()
except Exception:  # Django not yet set up (running as bare script)
    import django

    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "app.settings")
    django.setup()


# ----------------------------------------------------------------------------
# Validation — shared by every resolve mode.
# ----------------------------------------------------------------------------

# Deliberately simple and permissive; matches what Django's EmailField accepts in
# practice for the on-premise audience. We do NOT want to reject legitimate but
# unusual addresses the operator types.
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def normalize(value):
    """Trim + lowercase — mirrors cloud-backend ``app.utils.normalize_email``."""
    return (value or "").strip().lower()


def is_valid_email(value):
    return bool(_EMAIL_RE.match(value or ""))


def collides(User, email, exclude_pk):
    """True if another user already owns ``email`` (case-insensitive)."""
    return (
        User.objects.exclude(pk=exclude_pk)
        .filter(email__iexact=email)
        .exists()
    )


# ----------------------------------------------------------------------------
# Detector — the single source of truth for "what is wrong".
# ----------------------------------------------------------------------------

# Conflict kinds.
BLANK = "blank"        # email is NULL / empty
MISMATCH = "mismatch"  # username != email (case-insensitive)
DUPLICATE = "dup"      # email shared by >1 user (case-insensitive)


class Conflict:
    def __init__(self, pk, username, email, kinds):
        self.pk = pk
        self.username = username
        self.email = email
        self.kinds = kinds  # set of {BLANK, MISMATCH, DUPLICATE}

    @property
    def kinds_str(self):
        return ",".join(sorted(self.kinds))


def detect():
    """Return the list of Conflict rows currently violating the 2.0 invariants."""
    User = get_user_model()

    rows = list(User.objects.all().values_list("pk", "username", "email"))

    # Case-insensitive email -> count, to find duplicate groups.
    counts = {}
    for _pk, _username, email in rows:
        key = normalize(email)
        if key:
            counts[key] = counts.get(key, 0) + 1

    conflicts = []
    for pk, username, email in rows:
        kinds = set()
        norm_email = normalize(email)
        if not norm_email:
            kinds.add(BLANK)
        else:
            # The 2.0 CheckConstraint is exact equality (username == email), so any
            # difference at all — including case/whitespace — is a violation.
            if (username or "") != (email or ""):
                kinds.add(MISMATCH)
            if counts.get(norm_email, 0) > 1:
                kinds.add(DUPLICATE)
        if kinds:
            conflicts.append(Conflict(pk, username, email, kinds))
    return conflicts


def counts_by_kind(conflicts):
    blank = sum(1 for c in conflicts if BLANK in c.kinds)
    mismatch = sum(1 for c in conflicts if MISMATCH in c.kinds)
    dup_groups = len(
        {normalize(c.email) for c in conflicts if DUPLICATE in c.kinds}
    )
    return blank, mismatch, dup_groups


# ----------------------------------------------------------------------------
# Output helpers.
# ----------------------------------------------------------------------------

def print_table(conflicts):
    if not conflicts:
        print("No conflicts: every user has a unique email that equals the username.")
        return
    w_id = max(2, max(len(str(c.pk)) for c in conflicts))
    w_user = max(8, max(len(c.username or "") for c in conflicts))
    w_email = max(5, max(len(c.email or "") for c in conflicts))
    header = f"{'id':>{w_id}}  {'username':<{w_user}}  {'email':<{w_email}}  conflict"
    print(header)
    print("-" * len(header))
    for c in sorted(conflicts, key=lambda x: (sorted(x.kinds), str(x.pk))):
        # str(): the primary key is a UUID, which has no format-spec support.
        print(
            f"{str(c.pk):>{w_id}}  {c.username or '':<{w_user}}  "
            f"{(c.email or ''):<{w_email}}  {c.kinds_str}"
        )


def print_summary(conflicts):
    blank, mismatch, dup_groups = counts_by_kind(conflicts)
    print(
        f"\nConflicts: {len(conflicts)} "
        f"(blank {blank}, mismatch {mismatch}, dup-groups {dup_groups})"
    )


# ----------------------------------------------------------------------------
# Mutation helper.
# ----------------------------------------------------------------------------

def set_identity(User, pk, email):
    """Set both username and email to the (validated, normalized) email."""
    User.objects.filter(pk=pk).update(username=email, email=email)


# ----------------------------------------------------------------------------
# AUTO fixer — only the provably-safe cases.
# ----------------------------------------------------------------------------

def auto_fix():
    """
    Apply the safe automatic fixes and return how many rows were changed:

      1. admin row whose email is blank but ADMIN_EMAIL env is a valid, free email
         → set username = email = ADMIN_EMAIL.
      2. email and username differ only by case/whitespace → canonicalize both to
         the normalized email (no information lost, no new collision possible).
      3. email is non-blank, valid, equals username after normalization but stored
         with different case → lowercase both.

    Blank emails with no usable ADMIN_EMAIL, real mismatches, and genuine
    duplicates are intentionally left for a human.
    """
    User = get_user_model()
    admin_email = normalize(os.environ.get("ADMIN_EMAIL", ""))
    admin_username = normalize(os.environ.get("ADMIN_USERNAME", ""))

    changed = 0
    with transaction.atomic():
        for c in detect():
            norm_email = normalize(c.email)
            norm_user = normalize(c.username)

            # Case 1: blank admin email, ADMIN_EMAIL provided + valid + free.
            if BLANK in c.kinds:
                if (
                    admin_email
                    and is_valid_email(admin_email)
                    and (norm_user == admin_username or c.username == "admin")
                    and not collides(User, admin_email, c.pk)
                ):
                    set_identity(User, c.pk, admin_email)
                    changed += 1
                continue

            # Case 2/3: only case/whitespace differs between username and email,
            # and the normalized email is valid and not part of a duplicate group.
            if c.kinds <= {MISMATCH} and norm_user == norm_email:
                if is_valid_email(norm_email) and not collides(User, norm_email, c.pk):
                    set_identity(User, c.pk, norm_email)
                    changed += 1
                continue

            # Pure case-difference (email already valid, equals username modulo case)
            # handled above; everything else needs a human.
    return changed


# ----------------------------------------------------------------------------
# Interactive wizard.
# ----------------------------------------------------------------------------

def wizard():
    """Prompt the operator for a new email per remaining conflict."""
    User = get_user_model()
    conflicts = detect()
    if not conflicts:
        return
    print(
        "\nInteractive resolution. For each conflict, enter the correct email "
        "(it becomes both the username and the email). Press Enter to skip.\n"
    )
    for c in conflicts:
        while True:
            print(
                f"  id={c.pk}  username={c.username!r}  email={c.email!r}  "
                f"[{c.kinds_str}]"
            )
            try:
                raw = input("    new email> ").strip()
            except EOFError:
                print("\n(no more input — stopping wizard)")
                return
            if not raw:
                print("    skipped\n")
                break
            email = normalize(raw)
            if not is_valid_email(email):
                print(f"    invalid email {email!r}, try again")
                continue
            if collides(User, email, c.pk):
                print(f"    {email!r} already used by another user, try again")
                continue
            set_identity(User, c.pk, email)
            print(f"    set id={c.pk} → {email}\n")
            break


# ----------------------------------------------------------------------------
# File mode (headless): dump conflicts.yaml / apply it back.
# ----------------------------------------------------------------------------

DEFAULT_YAML = "/migration/conflicts.yaml"


def _load_yaml():
    try:
        import yaml  # PyYAML is present in the backend image
        return yaml
    except ImportError:
        sys.stderr.write("ERROR: PyYAML not available in this image for file mode.\n")
        raise


def dump_yaml(path):
    yaml = _load_yaml()
    conflicts = detect()
    records = [
        {
            # str(): safe_dump has no representer for UUID.
            "id": str(c.pk),
            "username": c.username,
            "current_email": c.email,
            "conflict": c.kinds_str,
            # Operator fills this in:
            "new_email": "",
        }
        for c in conflicts
    ]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(
            "# migration_doctor conflicts — edit 'new_email' for each row, then:\n"
            "#   make fix-users MODE=apply\n"
            "# Each new_email becomes BOTH the username and the email. Leave blank\n"
            "# to skip a row (it will still count as an unresolved conflict).\n"
        )
        yaml.safe_dump(records, fh, allow_unicode=True, sort_keys=False)
    print(f"Wrote {len(records)} conflict(s) to {path}")


def apply_yaml(path):
    yaml = _load_yaml()
    User = get_user_model()
    if not os.path.exists(path):
        sys.stderr.write(f"ERROR: {path} not found. Run dump first.\n")
        sys.exit(2)
    with open(path, encoding="utf-8") as fh:
        records = yaml.safe_load(fh) or []

    applied = 0
    errors = 0
    with transaction.atomic():
        for rec in records:
            pk = rec.get("id")
            new_email = normalize(rec.get("new_email", ""))
            if not new_email:
                continue
            if not is_valid_email(new_email):
                sys.stderr.write(f"  id={pk}: invalid new_email {new_email!r}, skipped\n")
                errors += 1
                continue
            if collides(User, new_email, pk):
                sys.stderr.write(f"  id={pk}: {new_email!r} collides with another user, skipped\n")
                errors += 1
                continue
            if not User.objects.filter(pk=pk).exists():
                sys.stderr.write(f"  id={pk}: no such user, skipped\n")
                errors += 1
                continue
            set_identity(User, pk, new_email)
            applied += 1
    print(f"Applied {applied} change(s); {errors} skipped.")


# ----------------------------------------------------------------------------
# CLI.
# ----------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(prog="migration_doctor", description=__doc__)
    parser.add_argument(
        "mode",
        choices=["scan", "auto", "resolve", "dump", "apply"],
        help="scan (read-only) | auto | resolve (wizard) | dump FILE | apply FILE",
    )
    parser.add_argument("file", nargs="?", default=DEFAULT_YAML, help="conflicts.yaml path")
    args = parser.parse_args(argv)

    if args.mode == "scan":
        conflicts = detect()
        print_table(conflicts)
        print_summary(conflicts)
        sys.exit(1 if conflicts else 0)

    if args.mode == "auto":
        n = auto_fix()
        print(f"Auto-fixed {n} row(s).")
        conflicts = detect()
        print_table(conflicts)
        print_summary(conflicts)
        sys.exit(1 if conflicts else 0)

    if args.mode == "resolve":
        n = auto_fix()
        print(f"Auto-fixed {n} row(s) before interactive resolution.")
        wizard()
        conflicts = detect()
        print_table(conflicts)
        print_summary(conflicts)
        sys.exit(1 if conflicts else 0)

    if args.mode == "dump":
        auto_fix()  # shrink the file to only the rows that need a human
        dump_yaml(args.file)
        conflicts = detect()
        print_summary(conflicts)
        sys.exit(1 if conflicts else 0)

    if args.mode == "apply":
        apply_yaml(args.file)
        conflicts = detect()
        print_table(conflicts)
        print_summary(conflicts)
        sys.exit(1 if conflicts else 0)


# Support both ``python migration_doctor.py <mode>`` and being exec()'d from
# ``manage.py shell -c`` (where argv after ``--`` is forwarded to us).
def _resolve_argv():
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    # Drop the leading script/-c sentinel; keep recognizable mode args.
    candidate = sys.argv[1:]
    valid = {"scan", "auto", "resolve", "dump", "apply"}
    for i, tok in enumerate(candidate):
        if tok in valid:
            return candidate[i:]
    return candidate


if __name__ == "__main__":
    main(_resolve_argv())
else:
    # Being exec()'d inside ``manage.py shell -c``.
    main(_resolve_argv())
