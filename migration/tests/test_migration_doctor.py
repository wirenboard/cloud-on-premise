#!/usr/bin/env python3
"""Runs migration_doctor against an in-memory user table. No Django, no containers.

    python3 migration/tests/test_migration_doctor.py
"""

import contextlib
import os
import pathlib
import sys
import types

DOCTOR = pathlib.Path(__file__).resolve().parent.parent / "migration_doctor.py"

rows = []


class _QS:
    def __init__(self, data):
        self._data = data

    def all(self):
        return _QS(self._data)

    def order_by(self, *fields):
        key = fields[0].lstrip("-")
        return _QS(sorted(self._data, key=lambda r: str(r[key])))

    def values_list(self, *fields):
        return [tuple(r[f] for f in fields) for r in self._data]

    def exclude(self, **kw):
        return _QS([r for r in self._data if r["pk"] != kw["pk"]])

    def filter(self, **kw):
        data = self._data
        for key, value in kw.items():
            if key == "email__iexact":
                data = [r for r in data if (r["email"] or "").lower() == value.lower()]
            elif key == "username":
                data = [r for r in data if r["username"] == value]
            elif key == "pk":
                data = [r for r in data if r["pk"] == value]
            else:
                raise AssertionError(f"unexpected filter {key}")
        return _QS(data)

    def exists(self):
        return bool(self._data)

    def update(self, **kw):
        for r in self._data:
            r.update(kw)
        return len(self._data)


class _User:
    class objects:
        @staticmethod
        def all():
            return _QS(rows)

        @staticmethod
        def filter(**kw):
            return _QS(rows).filter(**kw)

        @staticmethod
        def exclude(**kw):
            return _QS(rows).exclude(**kw)


def _install_django_stub():
    django = types.ModuleType("django")
    auth = types.ModuleType("django.contrib.auth")
    auth.get_user_model = lambda: _User
    db = types.ModuleType("django.db")
    db.transaction = types.SimpleNamespace(atomic=contextlib.contextmanager(lambda: iter([None])))
    contrib = types.ModuleType("django.contrib")
    contrib.auth = auth
    django.contrib = contrib
    django.db = db
    sys.modules.update({
        "django": django, "django.contrib": contrib,
        "django.contrib.auth": auth, "django.db": db,
    })


def run(mode, table, admin_email=""):
    """Run the doctor over `table`; return (exit code, resulting rows)."""
    global rows
    rows = [dict(r) for r in table]
    _install_django_stub()
    os.environ["ADMIN_EMAIL"] = admin_email
    sys.argv = ["migration_doctor", mode]
    code = None
    try:
        with contextlib.redirect_stdout(open(os.devnull, "w")):
            exec(compile(DOCTOR.read_text(), str(DOCTOR), "exec"), {"__name__": "doctor_under_test"})
    except SystemExit as exc:
        code = exc.code
    return code, rows


failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        failures.append(name)
        print(f"  FAIL {name}{'  — ' + detail if detail else ''}")


def by_pk(table, pk):
    return next(r for r in table if r["pk"] == pk)


print("scan: read-only, exit code carries the verdict")
clean = [{"pk": "1", "username": "a@x.com", "email": "a@x.com"}]
code, out = run("scan", clean)
check("clean table exits 0", code == 0)
check("scan changes nothing", out == clean)
code, out = run("scan", [{"pk": "1", "username": "admin", "email": ""}])
check("conflict exits 1", code == 1)
check("scan still changes nothing", out[0]["email"] == "")

print("\nauto: the three documented fixes")
code, out = run("auto", [{"pk": "1", "username": "admin", "email": ""}], admin_email="root@x.com")
check("blank admin email takes ADMIN_EMAIL", by_pk(out, "1")["email"] == "root@x.com")
check("and the username follows it", by_pk(out, "1")["username"] == "root@x.com")

code, out = run("auto", [{"pk": "1", "username": "u@x.com", "email": ""}])
check("blank email adopts an address-shaped login", by_pk(out, "1")["email"] == "u@x.com")

code, out = run("auto", [{"pk": "1", "username": "old-login", "email": "u@x.com"}])
check("on mismatch the email wins", by_pk(out, "1")["username"] == "u@x.com")

print("\nauto: what must be left to a human")
code, out = run("auto", [{"pk": "1", "username": "someone", "email": ""}])
check("blank email with nothing to derive stays", by_pk(out, "1")["email"] == "")
check("and still exits 1", code == 1)

dupes = [{"pk": "1", "username": "a", "email": "d@x.com"},
         {"pk": "2", "username": "b", "email": "D@x.com"}]
code, out = run("auto", dupes)
check("case-insensitive duplicates are not auto-resolved",
      {r["username"] for r in out} == {"a", "b"})
check("duplicates exit 1", code == 1)

code, out = run("auto", [{"pk": "1", "username": "u@x.com", "email": ""},
                         {"pk": "2", "username": "u@x.com", "email": "u@x.com"}])
check("an address already owned is not handed to a second row",
      by_pk(out, "1")["email"] == "" and by_pk(out, "2")["email"] == "u@x.com")

print("\ndeterminism: two rows competing for the same address")
pair = [{"pk": "2", "username": "Ivan@x.com", "email": ""},
        {"pk": "1", "username": "ivan@x.com", "email": ""}]
winners = set()
for _ in range(5):
    _, out = run("auto", pair)
    winners.add(next(r["pk"] for r in out if r["email"]))
check("the same row wins every run", len(winners) == 1, f"winners={winners}")
check("the winner is the lowest pk, not the table order", winners == {"1"})

_, out = run("auto", list(reversed(pair)))
check("and it does not depend on the input order",
      next(r["pk"] for r in out if r["email"]) == "1")

print("\nusername collision: the address is someone else's login")
# The unique key is on username: handing pk1 an address that pk2 already uses as
# its username must be skipped, not crash the whole run with an IntegrityError.
pair = [{"pk": "1", "username": "Frank@x.com", "email": ""},
        {"pk": "2", "username": "frank@x.com", "email": ""}]
code, out = run("auto", pair)
check("the exact-match row wins", by_pk(out, "2")["email"] == "frank@x.com")
check("the case-variant row is left to a human", by_pk(out, "1")["email"] == "")
code, out = run("auto", [{"pk": "1", "username": "old", "email": "eve@x.com"},
                         {"pk": "2", "username": "eve@x.com", "email": ""}])
check("a mismatch fix also respects foreign usernames", by_pk(out, "1")["username"] == "old")

print("\napply: only valid, free addresses are written")
code, out = run("scan", [{"pk": "1", "username": "a b", "email": "not-an-email"}])
check("an invalid address stays a conflict", code == 1)

print()


def test_migration_doctor():
    """Collected by pytest; the checks above already ran on import."""
    assert not failures, ", ".join(failures)


if __name__ == "__main__":
    if failures:
        print(f"FAILED: {len(failures)} — " + ", ".join(failures))
        sys.exit(1)
    print("all checks passed")
