"""doctor with fake docker, ss and timedatectl in PATH, the repository Makefile and openssl certificates."""

import collections
import contextlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from wb_onprem import cli, doctor, status

REPO = pathlib.Path(__file__).resolve().parents[2]
DOMAIN = "cloud.example.com"
NAMES = [DOMAIN, f"*.{DOMAIN}", f"*.ssh.{DOMAIN}", f"*.http.{DOMAIN}", f"*.apps.{DOMAIN}"]
SECRET = "leaked-marker-7f3a"

# Like the real CLI with daemon.err in place: `info --format` exits 0 with empty output, `version` exits 1.
FAKE_DOCKER = """#!/bin/sh
d="${0%/*}"
if [ -f "$d/daemon.err" ]; then
  case "$1" in
    info) cat "$d/daemon.err" >&2; exit 0 ;;
    version) cat "$d/daemon.err" >&2; exit 1 ;;
  esac
fi
case "$*" in
  "version --format {{.Server.Version}}") key=version ;;
  "info --format {{.DockerRootDir}}") key=root ;;
  "compose config"*) key=config ;;
  "compose ps"*) key=ps ;;
  "compose logs"*) key=logs ;;
  *) exit 0 ;;
esac
[ -f "$d/$key.out" ] && cat "$d/$key.out"
[ -f "$d/$key.err" ] && cat "$d/$key.err" >&2
exit "$(cat "$d/$key.rc" 2>/dev/null || echo 0)"
"""

FAKE_TOOL = """#!/bin/sh
d="${0%/*}"
n="${0##*/}"
[ -f "$d/$n.out" ] && cat "$d/$n.out"
exit "$(cat "$d/$n.rc" 2>/dev/null || echo 0)"
"""

ENV = {
    "ABSOLUTE_SERVER": DOMAIN, "EMAIL_ENABLED": "False", "ADMIN_EMAIL": "admin@example.com", "ADMIN_PASSWORD": "a",
    "TUNNEL_DASHBOARD_USER": "u", "TUNNEL_DASHBOARD_PASSWORD": "p", "POSTGRES_USER": "u", "POSTGRES_PASSWORD": "p",
    "POSTGRES_DB": "db", "GRAFANA_ADMIN_USER": "u", "GRAFANA_ADMIN_PASSWORD": "p", "TUNNEL_AUTH_TOKEN": "t",
    "SECRET_KEY": "k", "ABSOLUTE_SERVER_REGEX": "r", "PRIVATE_KEY": "k", "PUBLIC_KEY": "k", "TIMESCALE_PASSWORD": "p",
    "TELEGRAF_TIMESCALE_PASSWORD": "p", "GRAFANA_TIMESCALE_PASSWORD": "p",
}

Usage = collections.namedtuple("Usage", "total used free")


def make_cert(cert, key, days=90, names=NAMES, algorithm=("-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"),
              subject="/CN=t"):
    san = ",".join(f"DNS:{name}" for name in names)
    subprocess.run(["openssl", "req", "-x509", *algorithm, "-nodes", "-keyout", str(key), "-out", str(cert),
                    "-days", str(days), "-subj", subject, "-addext", f"subjectAltName={san}"],
                   check=True, capture_output=True)


def running(service, health=""):
    return {"Service": service, "State": "running", "Health": health, "ExitCode": 0}


def ss_line(port, process=None):
    users = f' users:(("{process}",pid=1,fd=4))' if process else ""
    return f"LISTEN 0 4096 0.0.0.0:{port} 0.0.0.0:*{users}"


class DoctorTest(unittest.TestCase):
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
        self.write_env(ENV)
        self.tls = self.install / "tls"
        self.tls.mkdir()
        make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "docker").write_text(FAKE_DOCKER)
        for name in ("ss", "timedatectl"):
            (self.bin / name).write_text(FAKE_TOOL)
        for name in ("docker", "ss", "timedatectl"):
            (self.bin / name).chmod(0o755)
        self.fake("version", out="27.0.3")
        self.fake("root", out=str(self.root))
        self.fake("logs", out="\n".join(f"worker-1  | line {i}" for i in range(20)))
        self.set_services({"traefik": ["443"], "tunnel": ["7107", "7501"], "backend": []},
                          [running("traefik"), running("tunnel"), running("backend", "healthy")])
        self.fake("ss", out="\n".join(ss_line(port, "docker-proxy") for port in (443, 7107, 7501)))
        self.fake("timedatectl", out="yes")
        patcher = mock.patch.object(status.shutil, "disk_usage", return_value=Usage(10000, 5000, 5000))
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.dict(os.environ, {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_env(self, env):
        (self.install / ".env").write_text("".join(f"{k}={v}\n" for k, v in env.items()))

    def fake(self, key, out=None, err=None, rc=0):
        for suffix, value in (("out", out), ("err", err), ("rc", rc)):
            path = self.bin / f"{key}.{suffix}"
            if value is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(f"{value}\n")

    def set_services(self, ports, rows):
        """ports: service -> its published ports; every service has `restart: always`."""
        services = {name: {"restart": "always", "ports": [{"target": 1, "published": p, "protocol": "tcp"}
                                                          for p in published]}
                    for name, published in ports.items()}
        self.fake("config", out=json.dumps({"name": "install", "services": services}))
        self.fake("ps", out="\n".join(json.dumps(r) for r in rows))

    def run_doctor(self, as_json=True):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["doctor", "--dir", str(self.install), *(["--json"] if as_json else [])])
        return code, json.loads(out.getvalue()) if as_json else out.getvalue() + err.getvalue()

    def items(self, report):
        return {it["name"]: it for it in report["items"]}

    def statuses(self, report):
        return {it["name"]: it["status"] for it in report["items"]}

    def test_healthy_installation(self):
        code, report = self.run_doctor()
        self.assertEqual((code, report["status"]), (0, "ok"), report)
        self.assertEqual(list(self.items(report)), [
            "docker", "containers", ".env", "certificate files", "certificate key", "certificate",
            "certificate names", "disk /", "ports", "clock"])
        self.assertIn("443, 7107, 7501", self.items(report)["ports"]["detail"])
        self.assertEqual(report["facts"]["version"], "2.0.1")

    def test_docker_unreachable(self):
        cases = {
            "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?":
                "systemctl start docker",
            "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock":
                "run as root",
        }
        for err, hint in cases.items():
            with self.subTest(hint):
                (self.bin / "daemon.err").write_text(err + "\n")
                code, report = self.run_doctor()
                self.assertEqual(code, 2)
                self.assertEqual(self.items(report)["docker"]["status"], "fail")
                self.assertIn(hint, self.items(report)["docker"]["detail"])
                self.assertFalse({"containers", "ports"} & set(self.items(report)))
                self.assertEqual(self.items(report)[".env"]["status"], "ok")

    def test_empty_server_version_is_not_ok(self):
        self.fake("version", out="")
        self.assertEqual(doctor.docker_item()["status"], "fail")

    def test_docker_not_installed(self):
        with mock.patch.dict(os.environ, {"PATH": str(self.root / "empty")}):
            got = doctor.docker_item()
        self.assertEqual((got["status"], got["detail"]),
                         ("fail", "docker not found, install Docker Engine with the compose plugin"))

    def test_failing_container_log_tail_only_in_text(self):
        self.set_services({"traefik": ["443"], "worker": []},
                          [running("traefik"), {"Service": "worker", "State": "restarting", "ExitCode": 1}])
        self.fake("logs", out="\n".join(f"worker-1  | line {i}" for i in range(20)), err="compose-stderr-marker")
        code, report = self.run_doctor()
        self.assertEqual(code, 2)
        worker = self.items(report)["worker"]
        self.assertEqual(worker["status"], "fail")
        self.assertIn("`VERSION=$(cat VERSION) docker compose logs worker`", worker["detail"])
        self.assertIn("make run", worker["detail"])
        self.assertNotIn("line 19", json.dumps(report))
        self.assertNotIn("traefik", self.items(report))
        code, text = self.run_doctor(as_json=False)
        self.assertEqual(code, 2)
        self.assertIn("    | worker-1  | line 19\n", text)
        self.assertIn("    | worker-1  | line 12\n", text)
        self.assertNotIn("line 11\n", text)
        self.assertNotIn("compose-stderr-marker", text)

    def test_log_tail_control_characters_are_not_printed(self):
        self.set_services({"worker": []}, [{"Service": "worker", "State": "restarting", "ExitCode": 1}])
        self.fake("logs", out="worker-1  | \x1b]0;title\x07\x1b[2Jcleared")
        _, text = self.run_doctor(as_json=False)
        self.assertIn("cleared", text)
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\x07", text)

    def test_log_tail_that_is_not_utf8(self):
        self.set_services({"worker": []}, [{"Service": "worker", "State": "restarting", "ExitCode": 1}])
        (self.bin / "logs.out").write_bytes(b"worker-1  | \xff\xfe broken bytes\n")
        code, text = self.run_doctor(as_json=False)
        self.assertEqual(code, 2)
        self.assertIn("broken bytes", text)

    def test_stopped_stack_is_one_item(self):
        self.set_services({"traefik": ["443"], "backend": []}, [])
        self.fake("ss", out="")
        code, report = self.run_doctor()
        self.assertEqual(code, 2)
        self.assertEqual(self.items(report)["containers"], {"name": "containers", "status": "fail",
                                                            "detail": "stack is not running, start it with `make run`"})
        self.assertFalse({"traefik", "backend"} & set(self.items(report)))

    def test_secrets_stay_out_of_the_output(self):
        self.write_env({**ENV, "POSTGRES_PASSWORD": f"{SECRET}/x"})
        self.fake("logs", out=f"worker-1  | password={SECRET}")
        self.set_services({"worker": []}, [{"Service": "worker", "State": "exited", "ExitCode": 1}])
        _, report = self.run_doctor()
        self.assertEqual(self.items(report)[".env"]["status"], "fail")
        self.assertIn("POSTGRES_PASSWORD", self.items(report)[".env"]["detail"])
        self.assertIn("make check-env", self.items(report)[".env"]["detail"])
        self.assertNotIn(SECRET, json.dumps(report))
        for key in ("config", "ps"):
            with self.subTest(failing=key):
                self.set_services({"worker": []}, [{"Service": "worker", "State": "exited", "ExitCode": 1}])
                self.fake(key, err=f"invalid interpolation: POSTGRES_PASSWORD={SECRET}", rc=1)
                for as_json in (True, False):
                    code, out = self.run_doctor(as_json)
                    self.assertEqual(code, 2)
                    self.assertIn("docker compose", json.dumps(out))
                    self.assertNotIn(SECRET, json.dumps(out))

    def test_env_check_names_the_missing_variable(self):
        self.write_env({k: v for k, v in ENV.items() if k != "SECRET_KEY"})
        code, report = self.run_doctor()
        self.assertEqual(code, 2)
        env = self.items(report)[".env"]
        self.assertEqual(env["status"], "fail")
        self.assertIn("Required variable 'SECRET_KEY' is missing", env["detail"])
        self.assertNotIn("\x1b", env["detail"])

    def test_env_check_shows_only_its_error_lines(self):
        (self.bin / "make").write_text(f"""#!/bin/sh
case "$*" in
  *check-env*) printf '\\033[0;31mERROR: Required variable X is missing\\033[0m\\n'
               echo "POSTGRES_PASSWORD={SECRET}"; exit 2 ;;
esac
exec {shutil.which("make")} "$@"
""")
        (self.bin / "make").chmod(0o755)
        for as_json in (True, False):
            _, out = self.run_doctor(as_json)
            text = json.dumps(out) if as_json else out
            self.assertIn("Required variable X is missing; run `make check-env`", text)
            self.assertNotIn(SECRET, text)

    def test_env_missing_or_empty(self):
        for content in (None, ""):
            with self.subTest(content=content):
                env = self.install / ".env"
                env.unlink(missing_ok=True)
                if content is not None:
                    env.write_text(content)
                _, report = self.run_doctor()
                self.assertEqual(self.items(report)[".env"]["status"], "fail")
                self.assertIn("missing or empty", self.items(report)[".env"]["detail"])

    def cert(self, now=None):
        return {it["name"]: (it["status"], it["detail"]) for it in doctor.cert_items(str(self.install), now=now)}

    def test_certificate_decision_table(self):
        other = self.root / "other"
        other.mkdir()
        make_cert(other / "cert.pem", other / "key.pem")
        cases = {
            "ok": (lambda: None, {"certificate files": "ok", "certificate key": "ok", "certificate": "ok",
                                  "certificate names": "ok"}),
            "rsa": (lambda: make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem",
                                      algorithm=("-newkey", "rsa:2048")), {"certificate key": "ok"}),
            "no fullchain": (lambda: (self.tls / "fullchain.pem").unlink(), {"certificate files": "fail"}),
            "fullchain is a directory": (lambda: ((self.tls / "fullchain.pem").unlink(),
                                                  (self.tls / "fullchain.pem").mkdir()), {"certificate files": "fail"}),
            "privkey is a directory": (lambda: ((self.tls / "privkey.pem").unlink(),
                                                (self.tls / "privkey.pem").mkdir()), {"certificate files": "fail"}),
            "no privkey": (lambda: (self.tls / "privkey.pem").unlink(), {"certificate files": "fail"}),
            "another key": (lambda: shutil.copy(other / "key.pem", self.tls / "privkey.pem"),
                            {"certificate key": "fail"}),
            "expires soon": (lambda: make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem", days=5),
                             {"certificate": "warn"}),
            "names not covered": (lambda: make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem",
                                                    names=NAMES[:-1]), {"certificate names": "fail"}),
        }
        for case, (prepare, expected) in cases.items():
            with self.subTest(case):
                shutil.rmtree(self.tls)
                self.tls.mkdir()
                make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem")
                prepare()
                got = self.cert()
                self.assertEqual({name: got[name][0] for name in expected if name in got}, expected, got)
                if "fail" in expected.values():
                    self.assertTrue(any("make reload-certs" in detail for _, detail in got.values()), got)

    def test_unreadable_key_or_certificate(self):
        for name, expected in (("privkey.pem", "openssl cannot read the private key"),
                               ("fullchain.pem", "openssl cannot read the certificate")):
            with self.subTest(name):
                make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem")
                (self.tls / name).write_text("not pem\n")
                self.assertEqual(self.cert()["certificate key"], ("fail", f"{self.tls / name}: {expected}"))
        self.assertEqual(self.cert()["certificate names"],
                         ("warn", f"{self.tls / 'fullchain.pem'}: openssl cannot read the names"))

    def test_empty_openssl_output_is_not_a_match(self):
        (self.bin / "openssl").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "openssl").chmod(0o755)
        got = doctor.key_item(str(self.tls / "fullchain.pem"), str(self.tls / "privkey.pem"))
        self.assertEqual(got["status"], "fail")

    def test_encrypted_key_does_not_wait_for_a_password(self):
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-aes256",
                        "-pass", "pass:x", "-out", str(self.tls / "privkey.pem")], check=True, capture_output=True)
        (self.bin / "openssl").write_text(f'#!/bin/sh\necho "$*" >> "${{0%/*}}/openssl-calls"\n'
                                          f'exec {shutil.which("openssl")} "$@"\n')
        (self.bin / "openssl").chmod(0o755)
        self.assertEqual(self.cert()["certificate key"][0], "fail")
        pkey = [c for c in (self.bin / "openssl-calls").read_text().splitlines() if c.startswith("pkey ")]
        self.assertTrue(pkey and all("-passin pass: " in c for c in pkey), pkey)

    def test_names_agree_with_make_check_certs(self):
        cases = {
            "all names": ({}, "ok"),
            "one missing": ({"names": NAMES[:-1]}, "fail"),
            "common name like the SAN header": ({"subject": "/CN=X509v3 Subject Alternative Name"}, "ok"),
            "file named like a wildcard": ({"names": [DOMAIN, f"a.{DOMAIN}"] + NAMES[2:]}, "fail"),
        }
        (self.install / f"a.{DOMAIN}").write_text("")
        for case, (kwargs, expected) in cases.items():
            with self.subTest(case):
                make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem", **kwargs)
                got = self.cert()["certificate names"][0]
                make = subprocess.run(["make", "-s", "check-certs"], cwd=self.install, capture_output=True, text=True)
                self.assertEqual(got, expected)
                self.assertEqual(make.returncode == 0, got == "ok", make.stdout + make.stderr)

    def test_key_type_refused_by_the_check_certs_of_2_0_x(self):
        makefile = self.install / "Makefile"
        # 2.0.x compares RSA moduli (`git show v2.0.1:Makefile`), the tags are not in a CI checkout
        makefile.write_text(makefile.read_text()
                            .replace("openssl x509 -noout -pubkey", "openssl x509 -noout -modulus")
                            .replace("openssl pkey -pubout", "openssl rsa -noout -modulus"))
        for algorithm, expected in ((("-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"), "warn"),
                                    (("-newkey", "rsa:2048"), "ok")):
            with self.subTest(algorithm[1]):
                make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem", algorithm=algorithm)
                status_, detail = self.cert()["certificate key"]
                self.assertEqual(status_, expected, detail)
                if expected == "warn":
                    self.assertIn("this release's `make check-certs` accepts only RSA keys", detail)

    def test_directory_stops_the_certificate_check(self):
        for name in ("fullchain.pem", "privkey.pem"):
            with self.subTest(name):
                make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem")
                (self.tls / name).unlink()
                (self.tls / name).mkdir()
                got = self.cert()
                self.assertEqual(list(got), ["certificate files"])
                self.assertIn(f"{name} is a directory", got["certificate files"][1])
                self.assertIn("rmdir", got["certificate files"][1])
                (self.tls / name).rmdir()

    def test_cert_without_chain_is_not_a_pair(self):
        (self.tls / "fullchain.pem").rename(self.tls / "cert.pem")
        got = self.cert()
        self.assertEqual(list(got), ["certificate files"])
        self.assertEqual(got["certificate files"][0], "fail")
        self.assertIn("fullchain.pem not found", got["certificate files"][1])

    @unittest.skipUnless(os.geteuid() != 0, "root reads a mode 000 file")
    def test_unreadable_key_asks_for_root(self):
        (self.tls / "privkey.pem").chmod(0)
        self.assertEqual(self.cert()["certificate key"],
                         ("warn", f"cannot read {self.tls / 'privkey.pem'}, run as root"))

    def test_expired_certificate(self):
        end = status.cert_end(str(self.tls / "fullchain.pem"))
        status_, detail = self.cert(now=end)["certificate"]
        self.assertEqual(status_, "fail")
        self.assertIn("expired", detail)
        self.assertIn("make reload-certs", detail)

    def test_cert_and_chain_without_fullchain(self):
        (self.tls / "fullchain.pem").rename(self.tls / "cert.pem")
        (self.tls / "chain.pem").write_text("")
        for names, expected in ((NAMES, "ok"), (NAMES[:2], "fail")):
            with self.subTest(names=names):
                make_cert(self.tls / "cert.pem", self.tls / "privkey.pem", days=5, names=names)
                got = self.cert()
                self.assertEqual(got["certificate files"][0], "warn")
                self.assertIn("make check-certs", got["certificate files"][1])
                self.assertEqual((got["certificate key"][0], got["certificate"][0], got["certificate names"][0]),
                                 ("ok", "warn", expected), got)
                self.assertIn("cert.pem", got["certificate"][1])
                self.assertFalse((self.tls / "fullchain.pem").exists())

    def test_names_file_matching_a_wildcard_does_not_change_the_names(self):
        (self.install / f"a.{DOMAIN}").write_text("")
        make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem", names=[DOMAIN, f"a.{DOMAIN}"])
        status_, detail = self.cert()["certificate names"]
        self.assertEqual(status_, "fail")
        self.assertIn(f"*.{DOMAIN}", detail)
        make_cert(self.tls / "fullchain.pem", self.tls / "privkey.pem")
        self.assertEqual(self.cert()["certificate names"], ("ok", "covers " + ", ".join(NAMES)))

    def test_required_names_unknown_warns(self):
        cases = {"no domain": lambda: self.write_env({k: v for k, v in ENV.items() if k != "ABSOLUTE_SERVER"}),
                 "empty list": lambda: (self.install / "Makefile").write_text(
                     (REPO / "Makefile").read_text().replace("\nREQUIRED_DOMAINS := ", "\nREQUIRED_DOMAINS :=#"))}
        for case, prepare in cases.items():
            with self.subTest(case):
                prepare()
                status_, detail = self.cert()["certificate names"]
                self.assertEqual(status_, "warn")
                self.assertIn("cannot determine required names", detail)

    def test_without_make_the_rest_is_still_checked(self):
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("cat", "openssl"):
            (tools / name).symlink_to(shutil.which(name))
        with mock.patch.dict(os.environ, {"PATH": f"{self.bin}{os.pathsep}{tools}"}):
            code, report = self.run_doctor()
        got = self.statuses(report)
        self.assertEqual((got["installation"], got[".env"], got["certificate"]), ("warn", "warn", "warn"), report)
        self.assertEqual((got["docker"], got["containers"], got["ports"]), ("ok", "ok", "ok"))
        self.assertEqual(code, 1)

    def test_low_disk_space(self):
        with mock.patch.object(status.shutil, "disk_usage", return_value=Usage(10000, 9600, 400)):
            code, report = self.run_doctor()
        self.assertEqual(code, 2)
        self.assertEqual(self.items(report)["disk /"]["status"], "fail")
        self.assertIn("free up space", self.items(report)["disk /"]["detail"])

    def test_ports(self):
        self.set_services({"traefik": ["8443"], "tunnel": ["7107"]}, [running("traefik"), running("tunnel")])
        cases = (
            ([ss_line(8443, "docker-proxy"), ss_line(7107, "docker-proxy"), ss_line(443, "nginx")], 0, {"ports": "ok"}),
            ([ss_line(8443, "nginx"), ss_line(7107, "docker-proxy")], 2, {"port 8443": "fail"}),
            ([ss_line(7107, "sshd")], 2, {"port 7107": "fail"}),
            ([ss_line(8443), ss_line(7107)], 0, {"ports": "ok"}),
            ([ss_line(8443, "dockerd"), ss_line(7107, "rootlesskit")], 0, {"ports": "ok"}),
            (["LISTEN 0 4096", ss_line(8443, "docker-proxy"), ss_line(7107, "docker-proxy")], 0, {"ports": "ok"}),
        )
        for lines, code, expected in cases:
            with self.subTest(lines=lines):
                self.fake("ss", out="\n".join(lines))
                got, report = self.run_doctor()
                self.assertEqual(got, code, report)
                self.assertEqual({k: v for k, v in self.statuses(report).items() if k.startswith("port")}, expected)
        self.fake("ss", out=ss_line(8443, "nginx"))
        _, report = self.run_doctor()
        self.assertIn("taken by nginx", self.items(report)["port 8443"]["detail"])

    def test_port_shared_with_docker_is_still_taken(self):
        self.set_services({"traefik": ["8443"]}, [running("traefik")])
        lines = [ss_line(8443, "nginx"), ss_line(8443, "docker-proxy").replace("0.0.0.0:8443", "[::]:8443")]
        for order in (lines, lines[::-1]):
            with self.subTest(order=order):
                self.fake("ss", out="\n".join(order))
                _, report = self.run_doctor()
                self.assertEqual(self.items(report)["port 8443"]["status"], "fail")
                self.assertIn("taken by nginx", self.items(report)["port 8443"]["detail"])

    def test_no_published_ports(self):
        self.set_services({"backend": []}, [running("backend")])
        _, report = self.run_doctor()
        self.assertEqual(self.items(report)["ports"], {"name": "ports", "status": "ok",
                                                       "detail": "the stack publishes no ports"})

    def test_port_owner_hidden_while_the_stack_is_stopped(self):
        self.set_services({"traefik": ["443"]}, [])
        self.fake("ss", out=ss_line(443))
        _, report = self.run_doctor()
        self.assertEqual(self.items(report)["port 443"]["status"], "warn")
        self.assertIn("run as root", self.items(report)["port 443"]["detail"])

    def test_port_owner_hidden_while_its_service_is_down(self):
        self.set_services({"traefik": ["443"], "tunnel": ["7107"]},
                          [{"Service": "traefik", "State": "restarting", "ExitCode": 1}, running("tunnel")])
        self.fake("ss", out="\n".join([ss_line(443), ss_line(7107)]))
        _, report = self.run_doctor()
        self.assertEqual(self.items(report)["port 443"],
                         {"name": "port 443", "status": "warn",
                          "detail": "in use while traefik is not running, run as root to see by whom"})
        self.assertNotIn("port 7107", self.items(report))

    def test_docker_owned_port_while_its_service_is_down(self):
        self.set_services({"traefik": ["443"], "tunnel": ["7107"]},
                          [{"Service": "traefik", "State": "exited", "ExitCode": 1}, running("tunnel")])
        for owner in doctor.DOCKER_PROCESSES:
            with self.subTest(owner):
                self.fake("ss", out="\n".join([ss_line(443, owner), ss_line(7107, owner)]))
                code, report = self.run_doctor()
                self.assertEqual(self.items(report)["port 443"], {
                    "name": "port 443", "status": "fail",
                    "detail": "taken by another container or Docker process while traefik is down"})
                self.assertNotIn("port 7107", self.items(report))
                self.assertEqual(code, 2)

    def test_docker_owned_port_of_a_starting_or_unhealthy_service_is_its_own(self):
        for health in ("starting", "unhealthy"):
            with self.subTest(health):
                self.set_services({"traefik": ["443"]},
                                  [{"Service": "traefik", "State": "running", "Health": health}])
                self.fake("ss", out=ss_line(443, "docker-proxy"))
                _, report = self.run_doctor()
                self.assertNotIn("port 443", self.items(report))

    def test_ss_failure_warns(self):
        self.fake("ss", rc=1)
        _, report = self.run_doctor()
        self.assertEqual(self.items(report)["ports"]["status"], "warn")

    def test_clock(self):
        for out, rc, expected, text in (
            ("yes", 0, "ok", "synchronized"),
            ("no", 0, "warn", "not synchronized, enable it with `timedatectl set-ntp true`"),
            (None, 1, "warn", "cannot check time synchronization"),
        ):
            with self.subTest(out=out, rc=rc):
                self.fake("timedatectl", out=out, rc=rc)
                code, report = self.run_doctor()
                self.assertEqual((code, self.items(report)["clock"]["status"]), (int(expected == "warn"), expected))
                self.assertTrue(self.items(report)["clock"]["detail"].startswith(text), report)

    def assert_upgrade_first(self):
        code, report = self.run_doctor()
        self.assertEqual(code, 2)
        self.assertEqual(report["items"], [{"name": "installation", "status": "fail",
                                            "detail": "1.x installation: run `make upgrade` first"}])

    def test_one_x_env_under_a_two_x_makefile(self):
        self.write_env({**ENV, "INFLUXDB_TOKEN": "x"})
        self.assert_upgrade_first()

    def test_one_x_makefile_without_the_check(self):
        (self.install / "Makefile").write_text("run:\n\tdocker compose up -d\n")
        self.assert_upgrade_first()


if __name__ == "__main__":
    unittest.main()
