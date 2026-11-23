"""status with a fake `docker` in PATH and the repository Makefile."""

import collections
import contextlib
import datetime
import io
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from wb_onprem import __version__, cli, status

REPO = pathlib.Path(__file__).resolve().parents[2]

FAKE_DOCKER = """#!/bin/sh
d="${0%/*}"
echo "VERSION=$VERSION $*" >> "$d/calls"
[ "$1" = ps ] && [ -f "$d/ps.hang" ] && exec sleep 5
case "$1 $2" in
  "info "*) key=info ;;
  "compose config") key=config ;;
  "compose ps") key=ps ;;
  *) exit 0 ;;
esac
[ -f "$d/$key.out" ] && cat "$d/$key.out"
[ -f "$d/$key.err" ] && cat "$d/$key.err" >&2
exit "$(cat "$d/$key.rc" 2>/dev/null || echo 0)"
"""

Usage = collections.namedtuple("Usage", "total used free")


def make_cert(path, days):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-keyout", os.devnull, "-out", str(path), "-days", str(days), "-subj", "/CN=t"],
                   check=True, capture_output=True)


def running(service, health=""):
    return {"Service": service, "State": "running", "Health": health, "ExitCode": 0}


def exited(service, code):
    return {"Service": service, "State": "exited", "Health": "", "ExitCode": code}


class StatusTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name).resolve()
        self.install = self.root / "install"
        self.install.mkdir()
        shutil.copy(REPO / "Makefile", self.install)
        shutil.copytree(REPO / "scripts", self.install / "scripts")
        (self.install / "docker-compose.yml").write_text("services: {}\n")
        (self.install / "VERSION").write_text("2.0.1\n")
        (self.install / ".env").write_text("ABSOLUTE_SERVER=cloud.example.com\n")
        (self.install / "tls").mkdir()
        make_cert(self.install / "tls" / "fullchain.pem", 90)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "docker").write_text(FAKE_DOCKER)
        (self.bin / "docker").chmod(0o755)
        self.fake("info", out=str(self.root))
        self.set_services({"backend": "always", "postgres": "always"},
                          [running("backend", "healthy"), running("postgres")])
        self.free(5000, 10000)
        patcher = mock.patch.dict(os.environ, {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake(self, key, out=None, err=None, rc=0):
        for suffix, value in (("out", out), ("err", err), ("rc", rc)):
            path = self.bin / f"{key}.{suffix}"
            if value is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(f"{value}\n")

    def set_services(self, restart, rows):
        """restart: service -> its `restart` value, None when the key is absent."""
        services = {name: ({"restart": policy} if policy else {}) for name, policy in restart.items()}
        self.fake("config", out=json.dumps({"name": "install", "services": services}))
        self.fake("ps", out="\n".join(json.dumps(r) for r in rows))

    def free(self, free, total):
        patcher = mock.patch.object(status.shutil, "disk_usage", return_value=Usage(total, total - free, free))
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_status(self, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(["status", "--dir", str(self.install), "--json", *extra])
        return code, json.loads(out.getvalue())

    def items(self, report):
        return {it["name"]: it for it in report["items"]}

    def calls(self):
        path = self.bin / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_running_services_and_completed_one_shots_are_ok(self):
        self.set_services(
            {"backend": "always", "postgres": "always", "timescale-init": "no", "minio-client": None},
            [running("backend", "healthy"), running("postgres"), exited("timescale-init", 0), exited("minio-client", 0)],
        )
        code, report = self.run_status()
        self.assertEqual((code, report["status"]), (0, "ok"), report)
        self.assertEqual(
            {name: it["status"] for name, it in self.items(report).items()
             if name in ("backend", "postgres", "timescale-init", "minio-client")},
            {"backend": "ok", "postgres": "ok", "timescale-init": "ok", "minio-client": "ok"},
        )
        self.assertIn("VERSION=2.0.1 compose ps --all --format json", self.calls())
        self.assertEqual(report["facts"]["directory"], str(self.install))
        self.assertEqual(report["facts"]["version"], "2.0.1")
        self.assertEqual(report["facts"]["wb-onprem"], __version__)

    def test_service_state_decision_table(self):
        cases = [
            ("always", running("svc", "healthy"), "ok", 0),
            ("always", running("svc"), "ok", 0),
            ("always", running("svc", "starting"), "warn", 1),
            ("always", running("svc", "unhealthy"), "fail", 2),
            ("always", {"Service": "svc", "State": "restarting", "ExitCode": 1}, "fail", 2),
            ("always", exited("svc", 0), "fail", 2),
            ("always", exited("svc", 1), "fail", 2),
            ("always", None, "fail", 2),
            ("no", running("svc"), "ok", 0),
            ("no", exited("svc", 0), "ok", 0),
            ("no", exited("svc", 1), "fail", 2),
            ("no", None, "fail", 2),
            (None, exited("svc", 0), "ok", 0),
            (None, exited("svc", 3), "fail", 2),
            ("always", [running("svc"), exited("svc", 1)], "fail", 2),
            ("always", [exited("svc", 1), running("svc")], "fail", 2),
            ("always", [running("svc"), running("svc", "starting")], "warn", 1),
        ]
        for restart, rows, expected, code in cases:
            with self.subTest(restart=restart, rows=rows):
                rows = rows if isinstance(rows, list) else [rows] if rows else []
                self.set_services({"backend": "always", "svc": restart}, [running("backend")] + rows)
                got, report = self.run_status()
                self.assertEqual(self.items(report)["svc"]["status"], expected, report)
                self.assertEqual(got, code)

    def test_ps_as_a_json_array(self):
        self.set_services({"backend": "always", "init": "no"}, [])
        self.fake("ps", out=json.dumps([running("backend"), exited("init", 1)]))
        code, report = self.run_status()
        self.assertEqual((self.items(report)["backend"]["status"], self.items(report)["init"]["status"]),
                         ("ok", "fail"), report)
        self.assertEqual(code, 2)

    def test_stopped_stack_is_one_item(self):
        self.set_services({"backend": "always", "postgres": "always", "init": "no"}, [])
        code, report = self.run_status()
        self.assertEqual(code, 2)
        services = [it for it in report["items"] if it["name"] in ("backend", "postgres", "init", "containers")]
        self.assertEqual(services, [{"name": "containers", "status": "fail",
                                     "detail": "stack is not running, start it with `make run`"}])

    def test_compose_errors_do_not_reach_the_output(self):
        marker = "POSTGRES_PASSWORD=leaked-marker-7f3a"
        for key in ("config", "ps"):
            with self.subTest(failing=key):
                self.set_services({"backend": "always"}, [running("backend")])
                self.fake(key, err=f"invalid interpolation: {marker}", rc=1)
                for extra in ((), ("--json",)):
                    out = io.StringIO()
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                        code = cli.main(["status", "--dir", str(self.install), *extra])
                    self.assertEqual(code, 2)
                    self.assertNotIn("leaked-marker", out.getvalue())
                    self.assertIn("docker compose", out.getvalue())

    def disk_items(self, report):
        return [it for it in report["items"] if it["name"].startswith("disk ")]

    def test_free_space_thresholds(self):
        for free, expected, code in ((1500, "ok", 0), (1499, "warn", 1), (500, "warn", 1), (499, "fail", 2)):
            with self.subTest(free=free):
                self.free(free, 10000)
                got, report = self.run_status()
                disks = self.disk_items(report)
                self.assertTrue(disks)
                self.assertEqual({it["status"] for it in disks}, {expected}, disks)
                self.assertEqual(got, code)

    def test_free_space_percent_is_rounded_down(self):
        for free, expected, percent in ((1499, "warn", 14), (1500, "ok", 15), (499, "fail", 4), (500, "warn", 5)):
            with self.subTest(free=free):
                self.free(free, 10000)
                _, report = self.run_status()
                disk = self.disk_items(report)[0]
                self.assertEqual(disk["status"], expected)
                self.assertTrue(disk["detail"].endswith(f"({percent}%)"), disk)

    def test_zero_disk_size_warns(self):
        self.free(0, 0)
        code, report = self.run_status()
        self.assertEqual({(it["status"], it["detail"]) for it in self.disk_items(report)},
                         {("warn", "cannot read disk size")})
        self.assertEqual(code, 1)

    def test_root_docker_and_installation_disks_counted_once_per_device(self):
        docker_root = self.root / "docker"
        docker_root.mkdir()
        self.fake("info", out=str(docker_root))
        for devices, expected in (
            ({"/": 1, str(docker_root): 1, str(self.install): 1}, ["disk /"]),
            ({"/": 1, str(docker_root): 2, str(self.install): 1}, ["disk /", f"disk {docker_root}"]),
            ({"/": 1, str(docker_root): 2, str(self.install): 3},
             ["disk /", f"disk {docker_root}", f"disk {self.install}"]),
        ):
            with self.subTest(devices=devices), mock.patch.object(status, "device", devices.get):
                _, report = self.run_status()
                self.assertEqual([it["name"] for it in self.disk_items(report)], expected)

    def test_docker_root_unknown_still_checks_root_and_installation(self):
        # The real CLI exits 0 with empty output from `info --format` when the daemon is unreachable.
        self.fake("info", err="Cannot connect to the Docker daemon", rc=0)
        devices = {"/": 1, str(self.install): 2}
        with mock.patch.object(status, "device", devices.get):
            _, report = self.run_status()
        self.assertEqual([it["name"] for it in self.disk_items(report)], ["disk /", f"disk {self.install}"])

    def test_certificate_expiry_boundaries(self):
        tls = self.install / "tls"
        end = status.cert_end(str(tls / "fullchain.pem"))
        day = datetime.timedelta(days=1)
        second = datetime.timedelta(seconds=1)
        for now, expected in ((end - 14 * day, "ok"), (end - 14 * day + second, "warn"),
                              (end - second, "warn"), (end, "fail"), (end + day, "fail")):
            with self.subTest(left=end - now):
                self.assertEqual(status.cert_item(str(self.install), now=now)["status"], expected)

    def test_unreadable_certificate_expiry_warns(self):
        (self.install / "tls" / "fullchain.pem").write_text("not a certificate\n")
        item = status.cert_item(str(self.install))
        self.assertEqual(item["status"], "warn")
        self.assertIn("cannot read the expiry date", item["detail"])

    def test_unparsable_compose_config_fails(self):
        self.fake("config", out="not json")
        code, report = self.run_status()
        self.assertEqual(code, 2)
        self.assertEqual(self.items(report)["services"],
                         {"name": "services", "status": "fail", "detail": "cannot parse `docker compose config` output"})

    def test_certificate_expiring_soon_warns_through_the_command(self):
        make_cert(self.install / "tls" / "fullchain.pem", 5)
        code, report = self.run_status()
        self.assertEqual((code, self.items(report)["certificate"]["status"]), (1, "warn"))
        self.assertIn("days left", self.items(report)["certificate"]["detail"])

    def test_certificate_file_and_directory(self):
        tls = self.install / "tls"
        other = self.root / "certs"
        other.mkdir()
        make_cert(other / "cert.pem", 60)
        (tls / "fullchain.pem").unlink()
        cases = (
            ("ABSOLUTE_SERVER=cloud.example.com\n", "fail", "tls/fullchain.pem"),
            (f"ABSOLUTE_SERVER=cloud.example.com\nTLS_CERTS_PATH={other}\n", "ok", f"{other}/cert.pem"),
        )
        for env, expected, path in cases:
            with self.subTest(env=env):
                (self.install / ".env").write_text(env)
                item = status.cert_item(str(self.install))
                self.assertEqual(item["status"], expected, item)
                self.assertIn(path, item["detail"])

    def test_certificate_directory_unknown_warns(self):
        with mock.patch.object(status.core, "make_var", return_value=None):
            item = status.cert_item(str(self.install))
        self.assertEqual(item["status"], "warn")
        self.assertIn("TLS_DIR", item["detail"])

    def assert_upgrade_first(self):
        code, report = self.run_status()
        self.assertEqual(code, 2)
        self.assertEqual(report["items"], [{"name": "installation", "status": "fail",
                                            "detail": "1.x installation: run `make upgrade` first"}])
        self.assertEqual(report["facts"]["version"], "2.0.1")
        self.assertFalse([c for c in self.calls() if " compose " in f" {c} "], self.calls())

    def test_one_x_env_under_a_two_x_makefile(self):
        (self.install / ".env").write_text("ABSOLUTE_SERVER=cloud.example.com\nINFLUXDB_TOKEN=x\n")
        self.assert_upgrade_first()

    def test_one_x_makefile_without_the_check(self):
        (self.install / "Makefile").write_text("run:\n\tdocker compose up -d\n")
        self.assert_upgrade_first()

    def test_without_make_the_rest_is_still_checked(self):
        tools = self.root / "tools"
        tools.mkdir()
        (tools / "cat").symlink_to(shutil.which("cat"))
        with mock.patch.dict(os.environ, {"PATH": f"{self.bin}{os.pathsep}{tools}"}):
            code, report = self.run_status()
        items = self.items(report)
        self.assertEqual(items["installation"]["status"], "warn")
        self.assertIn("make", items["installation"]["detail"])
        self.assertEqual(items["backend"]["status"], "ok")
        self.assertEqual(code, 1)

    def test_hung_docker_is_not_a_one_x_installation(self):
        (self.bin / "ps.hang").write_text("")
        with mock.patch.object(status, "CHECK_TIMEOUT", 1):
            code, report = self.run_status()
        items = self.items(report)
        self.assertEqual(items["installation"], {"name": "installation", "status": "warn",
                                                 "detail": "`make check-not-1x` timed out, Docker may be hung"})
        self.assertEqual(items["backend"]["status"], "ok")
        self.assertEqual(code, 1)

    def test_missing_makefile_is_not_a_one_x_installation(self):
        (self.install / "Makefile").unlink()
        code, report = self.run_status()
        items = self.items(report)
        self.assertEqual(items["installation"]["status"], "fail")
        self.assertIn("Makefile not found", items["installation"]["detail"])
        self.assertEqual(items["backend"]["status"], "ok")
        self.assertEqual(code, 2)

    def test_facts_and_json_before_the_command(self):
        self.commit_installation()
        (self.install / "VERSION").write_text("2.1.0\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["--json", "--dir", str(self.install), "status"])
        report = json.loads(out.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(set(report), {"status", "items", "facts"})
        self.assertEqual(report["facts"], {"directory": str(self.install), "version": "2.1.0",
                                           "git": "v2.0.1-dirty", "wb-onprem": __version__})

    def commit_installation(self):
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-C", str(self.install)]
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "release"], ["tag", "v2.0.1"]):
            subprocess.run(git + args, check=True, capture_output=True)

    def test_status_and_doctor_do_not_write_the_git_index(self):
        self.commit_installation()
        (self.install / "VERSION").write_text("2.0.1\n")
        (self.install / "docker-compose.yml").write_text("services: {x: {}}\n")
        index = self.install / ".git" / "index"
        before = (index.stat().st_ino, index.stat().st_mtime_ns)
        for command in ("status", "doctor"):
            with self.subTest(command), contextlib.redirect_stdout(io.StringIO()) as out, \
                    contextlib.redirect_stderr(io.StringIO()):
                cli.main([command, "--dir", str(self.install), "--json"])
                self.assertEqual((index.stat().st_ino, index.stat().st_mtime_ns), before)
                self.assertEqual(json.loads(out.getvalue())["facts"]["git"], "v2.0.1-dirty")

    def test_clean_checkout_is_not_dirty(self):
        self.commit_installation()
        _, report = self.run_status()
        self.assertEqual(report["facts"]["git"], "v2.0.1")

    def test_dubious_ownership_is_not_called_a_missing_checkout(self):
        (self.bin / "git").write_text(f"#!/bin/sh\necho \"fatal: detected dubious ownership in repository at '{self.install}'\" >&2\n"
                                      "exit 128\n")
        (self.bin / "git").chmod(0o755)
        _, report = self.run_status()
        self.assertIn(f"run wb-onprem as the owner of {self.install}", report["facts"]["git"])

    def test_text_output(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["status", "--dir", str(self.install)])
        self.assertEqual(code, 0)
        self.assertIn("version: 2.0.1\n", out.getvalue())
        self.assertIn("[ ok ] backend: running (healthy)\n", out.getvalue())


if __name__ == "__main__":
    unittest.main()
