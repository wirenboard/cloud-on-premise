"""Shared helpers: installation directory lookup, Makefile variables."""

import os
import pathlib
import shutil
import tempfile
import unittest
from unittest import mock

from wb_onprem import core

REPO = pathlib.Path(__file__).resolve().parents[2]


def make_installation(path):
    path.mkdir(parents=True, exist_ok=True)
    (path / "docker-compose.yml").write_text("services: {}\n")
    (path / "VERSION").write_text("2.0.1\n")
    return path


class FindDirTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name).resolve()
        self.config = self.root / "etc" / "config"
        self.default = self.root / "opt" / "cloud-on-premise"
        self.cwd = self.root / "cwd"
        self.cwd.mkdir()
        for patcher in (
            mock.patch.object(core, "CONFIG_PATH", str(self.config)),
            mock.patch.object(core, "DEFAULT_DIR", str(self.default)),
            mock.patch.dict(os.environ),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        os.environ.pop("WB_ONPREM_DIR", None)
        old = os.getcwd()
        os.chdir(self.cwd)
        self.addCleanup(os.chdir, old)

    def write_config(self, text):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(text)

    def test_dir_argument_wins_over_everything(self):
        arg = make_installation(self.root / "arg")
        os.environ["WB_ONPREM_DIR"] = str(make_installation(self.root / "env"))
        make_installation(self.cwd)
        self.assertEqual(core.find_dir(str(arg)), str(arg))

    def test_environment_wins_over_current_directory(self):
        env = make_installation(self.root / "env")
        os.environ["WB_ONPREM_DIR"] = str(env)
        make_installation(self.cwd)
        self.assertEqual(core.find_dir(None), str(env))

    def test_current_directory_wins_over_config(self):
        make_installation(self.cwd)
        self.write_config(f"dir={make_installation(self.root / 'conf')}\n")
        self.assertEqual(core.find_dir(None), str(self.cwd))

    def test_current_directory_without_version_is_skipped(self):
        (self.cwd / "docker-compose.yml").write_text("services: {}\n")
        conf = make_installation(self.root / "conf")
        self.write_config(f"# written by hand\n\ndir = {conf}\n")
        self.assertEqual(core.find_dir(None), str(conf))

    def test_config_wins_over_default(self):
        conf = make_installation(self.root / "conf")
        make_installation(self.default)
        self.write_config(f"dir={conf}\n")
        self.assertEqual(core.find_dir(None), str(conf))

    def test_default_when_nothing_else(self):
        make_installation(self.default)
        self.assertEqual(core.find_dir(None), str(self.default))

    def test_nothing_found_names_the_flag(self):
        with self.assertRaisesRegex(core.CliError, "--dir"):
            core.find_dir(None)
        pathlib.Path(self.default).mkdir(parents=True)
        with self.assertRaisesRegex(core.CliError, "--dir"):
            core.find_dir(None)

    def test_explicit_source_that_is_not_an_installation_is_an_error(self):
        make_installation(self.default)
        empty = self.root / "empty"
        empty.mkdir()
        for path in (empty, self.root / "missing", ""):
            with self.subTest(path=path), self.assertRaisesRegex(core.CliError, "not an installation"):
                core.find_dir(str(path))

    def test_broken_environment_is_reported_not_skipped(self):
        make_installation(self.default)
        os.environ["WB_ONPREM_DIR"] = str(self.root / "missing")
        with self.assertRaisesRegex(core.CliError, "WB_ONPREM_DIR"):
            core.find_dir(None)

    def test_broken_config_is_reported_not_skipped(self):
        make_installation(self.default)
        self.write_config(f"dir={self.root / 'missing'}\n")
        with self.assertRaisesRegex(core.CliError, "config"):
            core.find_dir(None)


class MakeVarTest(unittest.TestCase):
    """Values come from the repository Makefile itself, as on a real installation."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.install = pathlib.Path(tmp.name)
        shutil.copy(REPO / "Makefile", self.install)
        shutil.copytree(REPO / "scripts", self.install / "scripts")
        (self.install / "VERSION").write_text("2.0.1\n")

    def write_env(self, text):
        (self.install / ".env").write_text(text)

    def test_required_domains_are_not_globbed_against_the_directory(self):
        self.write_env("ABSOLUTE_SERVER=https://cloud.example.com\n")
        (self.install / "a.cloud.example.com").write_text("")
        self.assertEqual(
            core.make_var(str(self.install), "REQUIRED_DOMAINS").split(),
            ["cloud.example.com", "*.cloud.example.com", "*.ssh.cloud.example.com",
             "*.http.cloud.example.com", "*.apps.cloud.example.com"],
        )

    def test_tls_dir_default_and_from_env(self):
        self.write_env("ABSOLUTE_SERVER=cloud.example.com\n")
        self.assertEqual(core.make_var(str(self.install), "TLS_DIR"), "./tls")
        self.write_env("ABSOLUTE_SERVER=cloud.example.com\nTLS_CERTS_PATH=\"/srv/certs/\"\n")
        self.assertEqual(core.make_var(str(self.install), "TLS_DIR"), "/srv/certs/")

    def test_without_make_there_is_no_value(self):
        self.write_env("ABSOLUTE_SERVER=cloud.example.com\n")
        with mock.patch.dict(os.environ, {"PATH": str(self.install / "empty-path")}):
            self.assertIsNone(core.make_var(str(self.install), "TLS_DIR"))

    def test_broken_makefile_gives_no_value(self):
        (self.install / "Makefile").write_text("TLS_DIR := ./tls\nall:\n\techo\n  bad line\n")
        self.assertIsNone(core.make_var(str(self.install), "TLS_DIR"))


if __name__ == "__main__":
    unittest.main()
