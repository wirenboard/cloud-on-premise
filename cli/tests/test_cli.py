"""wb-onprem entry point: version, common flags, exit codes."""

import contextlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

from wb_onprem import cli, core

REPO = pathlib.Path(__file__).resolve().parents[2]


def run_main(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main(argv)
    return code, out.getvalue(), err.getvalue()


class VersionTest(unittest.TestCase):
    def test_version_from_clone_is_repository_version(self):
        code, out, _ = run_main(["--version"])
        self.assertEqual(code, 0)
        self.assertEqual(out, "wb-onprem %s\n" % (REPO / "VERSION").read_text().strip())


def probe_command(statuses):
    def build(directory, args):
        items = [{"name": f"check {i}", "status": s, "detail": directory} for i, s in enumerate(statuses)]
        return {"status": core.worst(statuses), "items": items, "facts": {"directory": directory}}

    return types.SimpleNamespace(HELP="test command", add_arguments=lambda parser: None, build=build)


class CommandTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.install = pathlib.Path(tmp.name).resolve()
        (self.install / "docker-compose.yml").write_text("services: {}\n")
        (self.install / "VERSION").write_text("2.0.1\n")

    def run_probe(self, argv, statuses=("ok",)):
        with mock.patch.dict(cli.COMMANDS, {"probe": probe_command(statuses)}):
            return run_main(argv)

    def test_json_and_dir_before_or_after_the_command(self):
        for argv in (
            ["--json", "--dir", str(self.install), "probe"],
            ["probe", "--json", "--dir", str(self.install)],
            ["--dir", str(self.install), "probe", "--json"],
        ):
            with self.subTest(argv=argv):
                code, out, _ = self.run_probe(argv)
                self.assertEqual(code, 0)
                report = json.loads(out)
                self.assertEqual(report["status"], "ok")
                self.assertEqual(report["facts"], {"directory": str(self.install)})
                self.assertEqual(len(report["items"]), 1)

    def test_text_output_without_json(self):
        code, out, _ = self.run_probe(["probe", "--dir", str(self.install)], ("ok", "warn"))
        self.assertEqual(code, 1)
        self.assertIn(f"directory: {self.install}\n", out)
        self.assertIn("[warn] check 1:", out)
        self.assertTrue(out.endswith("overall: warn\n"))

    def test_exit_code_follows_the_worst_item(self):
        for statuses, expected in ((("ok",), 0), (("ok", "warn"), 1), (("warn", "fail", "ok"), 2)):
            with self.subTest(statuses=statuses):
                code, _, _ = self.run_probe(["probe", "--dir", str(self.install)], statuses)
                self.assertEqual(code, expected)

    def test_installation_not_found_is_a_start_error(self):
        code, out, err = self.run_probe(["probe", "--json", "--dir", str(self.install / "missing")])
        self.assertEqual((code, out), (3, ""))
        self.assertIn("not an installation directory", err)

    def test_usage_errors_are_start_errors(self):
        for argv in ([], ["no-such-command"], ["probe", "--no-such-flag"]):
            with self.subTest(argv=argv):
                code, _, _ = self.run_probe(argv)
                self.assertEqual(code, 3)

    def test_command_help_describes_it(self):
        code, out, _ = self.run_probe(["probe", "--help"])
        self.assertEqual(code, 0)
        self.assertIn("\ntest command\n", out)

    def test_closed_output_pipe_is_not_an_error(self):
        script = ("import sys, types; from wb_onprem import cli; "
                  "items = [{'name': str(i), 'status': 'ok', 'detail': 'x' * 100} for i in range(10000)]; "
                  "cli.COMMANDS['probe'] = types.SimpleNamespace(HELP='', add_arguments=lambda p: None, "
                  "build=lambda d, a: {'status': 'ok', 'items': items, 'facts': {}}); "
                  "sys.exit(cli.main(['probe', '--dir', sys.argv[1]]))")
        with subprocess.Popen([sys.executable, "-c", script, str(self.install)], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env={**os.environ, "PYTHONPATH": str(REPO / "cli")}) as p:
            p.stdout.readline()
            p.stdout.close()
            err = p.stderr.read().decode()
        self.assertEqual(p.returncode, 0, err)
        self.assertEqual(err, "")

    def test_crash_inside_a_command_is_a_start_error(self):
        broken = types.SimpleNamespace(HELP="broken", add_arguments=lambda parser: None, build=lambda d, a: 1 / 0)
        with mock.patch.dict(cli.COMMANDS, {"broken": broken}):
            code, _, err = run_main(["broken", "--dir", str(self.install)])
        self.assertEqual(code, 3)
        self.assertIn("ZeroDivisionError", err)


if __name__ == "__main__":
    unittest.main()
