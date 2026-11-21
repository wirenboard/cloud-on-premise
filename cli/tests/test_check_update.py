"""check-update against a temporary git remote with release tags and a clone without the new ones."""

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

from wb_onprem import cli

REPO = pathlib.Path(__file__).resolve().parents[2]
GIT = shutil.which("git")

FAKE_GIT = """#!/bin/sh
d="${{0%/*}}"
echo "GIT_TERMINAL_PROMPT=${{GIT_TERMINAL_PROMPT-unset}} $*" >> "$d/git-calls"
for a in "$@"; do
  if [ -f "$d/fail-$a" ]; then cat "$d/fail-$a" >&2; exit 128; fi
done
exec {git} "$@"
"""

CHANGELOG = {
    "2.0.1": "## [2.0.1] - 2026-09-30\n\n- two-zero-one notes\n",
    "2.1.0": "## [2.1.0] - 2026-11-01\n\n- two-one-zero notes\n",
    "3.0.0": "## [3.0.0] - 2026-12-01\n\n- three-zero-zero notes\n",
}
TOKEN_URL = "https://wbuser:s3cret-token@127.0.0.1:9/cloud-on-premise.git"
MARKERS = ("s3cret-token", "wbuser", "secret-a")


def git(cwd, *args):
    return subprocess.run([GIT, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                           "-c", "tag.gpgsign=false", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout


class CheckUpdateTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name).resolve()
        self.origin = self.root / "origin"
        self.origin.mkdir()
        git(self.origin, "init", "-q")
        shutil.copy(REPO / "Makefile", self.origin)
        shutil.copytree(REPO / "scripts", self.origin / "scripts")
        (self.origin / "docker-compose.yml").write_text("services: {}\n")
        (self.origin / ".gitignore").write_text(".env\n")
        self.release("2.0.1", "A=1\nB=2\n")
        self.install = self.root / "install"
        git(self.root, "clone", "-q", str(self.origin), str(self.install))
        (self.install / ".env").write_text("A=secret-a\n")
        self.release("2.1.0", "A=1\nB=2\nC=3\n#D=4\n")
        git(self.origin, "tag", "latest")
        self.release("3.0.0", "A=1\nB=2\nC=3\nE=5\n")
        git(self.origin, "tag", "v4.0.0-rc1")

        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "git").write_text(FAKE_GIT.format(git=GIT))
        (self.bin / "docker").write_text("#!/bin/sh\nexit 0\n")
        for name in ("git", "docker"):
            (self.bin / name).chmod(0o755)
        patcher = mock.patch.dict(os.environ, {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def release(self, version, example):
        (self.origin / "VERSION").write_text(version + "\n")
        (self.origin / ".env.example").write_text(example)
        notes = [CHANGELOG[v] for v in sorted(CHANGELOG, reverse=True) if v <= version]
        (self.origin / "CHANGELOG_EN.md").write_text("# Changelog\n\n" + "\n".join(notes))
        (self.origin / "CHANGELOG.md").write_text("## [9.9.9] - russian-only\n")
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "-qm", version)
        git(self.origin, "tag", "v" + version)

    def check(self, *extra, as_json=True):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["check-update", "--dir", str(self.install), *(["--json"] if as_json else []), *extra])
        for marker in MARKERS:
            self.assertNotIn(marker, err.getvalue())
        return code, (json.loads(out.getvalue()) if as_json else out.getvalue())

    def items(self, report):
        return {it["name"]: it for it in report["items"]}

    def git_calls(self):
        path = self.bin / "git-calls"
        return path.read_text().splitlines() if path.exists() else []

    def snapshot(self):
        git_dir = self.install / ".git"
        files = sorted((str(p.relative_to(git_dir)), p.stat().st_mtime_ns) for p in git_dir.rglob("*"))
        head = git(self.install, "rev-parse", "HEAD")
        state = git(self.install, "--no-optional-locks", "status", "--porcelain", "--ignored")
        return files, head, state

    def test_newer_major_release_with_changelog_and_new_variables(self):
        code, report = self.check()
        items = self.items(report)
        self.assertEqual(code, 1)
        self.assertEqual(report["facts"]["installed"], "2.0.1")
        self.assertEqual(report["facts"]["available"], "3.0.0")
        self.assertEqual(items["update"]["status"], "warn")
        self.assertIn("major", items["update"]["detail"])
        self.assertIn("release notes", items["update"]["detail"])
        self.assertEqual(items["env"]["status"], "warn")
        self.assertIn("new in v3.0.0: C, E", items["env"]["detail"])
        self.assertIn("three-zero-zero", report["changelog"])
        self.assertIn("two-one-zero", report["changelog"])
        self.assertNotIn("two-zero-one", report["changelog"])
        self.assertNotIn("russian-only", report["changelog"])
        self.assertNotIn("secret-a", json.dumps(report))

    def test_minor_release_lists_only_variables_absent_from_the_installed_example_and_env(self):
        git(self.origin, "tag", "-d", "v3.0.0")
        code, report = self.check()
        items = self.items(report)
        self.assertEqual(report["facts"]["available"], "2.1.0")
        self.assertEqual(items["update"]["status"], "ok")
        self.assertTrue(items["env"]["detail"].startswith("new in v2.1.0: C "), items["env"]["detail"])
        self.assertEqual(code, 1)
        (self.install / ".env").write_text("C=3\n")
        code, report = self.check()
        self.assertEqual(self.items(report)["env"]["status"], "ok")
        self.assertEqual(code, 0)

    def test_newest_release_installed(self):
        for tag in ("v2.1.0", "v3.0.0"):
            git(self.origin, "tag", "-d", tag)
        code, report = self.check()
        self.assertEqual(code, 0)
        self.assertEqual([it["name"] for it in report["items"]], ["update"])
        self.assertIn("newest", report["items"][0]["detail"])

    def test_testing_suffix_compares_as_the_release(self):
        git(self.origin, "tag", "-d", "v3.0.0")
        (self.install / "VERSION").write_text("2.1.0-testing\n")
        code, report = self.check()
        self.assertEqual(code, 0)
        self.assertIn("newest", self.items(report)["update"]["detail"])

    def test_one_x_installation_is_sent_to_make_upgrade(self):
        for env in ("A=1\nINFLUXDB_TOKEN=x\n", None):
            if env is None:
                (self.install / "Makefile").write_text("run:\n\tdocker compose up -d\n")
            else:
                (self.install / ".env").write_text(env)
            code, text = self.check(as_json=False)
            self.assertIn("make upgrade", text)
            self.assertNotIn("new in", text)
            self.assertNotIn(".env", text)
            self.assertEqual(code, 1)

    def test_installation_git_directory_is_not_changed(self):
        before = self.snapshot()
        code, report = self.check()
        self.assertEqual(report["facts"]["available"], "3.0.0")
        self.assertIn("three-zero-zero", report["changelog"])
        self.assertEqual(self.snapshot(), before)

    def test_every_git_call_disables_the_terminal_prompt(self):
        self.check()
        calls = self.git_calls()
        self.assertTrue(any(" ls-remote " in c for c in calls) and any(" fetch " in c for c in calls), calls)
        for call in calls:
            self.assertTrue(call.startswith("GIT_TERMINAL_PROMPT=0 "), call)
        fetch = next(c for c in calls if " fetch " in c)
        self.assertIn(f"include.path={self.install / '.git' / 'config'} fetch", fetch)

    def test_remote_option_reads_tags_from_another_repository(self):
        other = self.root / "other.git"
        git(self.root, "clone", "-q", "--bare", str(self.origin), str(other))
        git(other, "tag", "-d", "v3.0.0")
        code, report = self.check("--remote", str(other))
        self.assertEqual(report["facts"]["remote"], str(other))
        self.assertEqual(report["facts"]["available"], "2.1.0")

    def test_unreachable_remote_fails_without_credentials_in_the_output(self):
        git(self.install, "remote", "set-url", "origin", TOKEN_URL)
        for extra in ((), ("--remote", TOKEN_URL)):
            for as_json in (True, False):
                code, out = self.check(*extra, as_json=as_json)
                text = json.dumps(out) if as_json else out
                self.assertEqual(code, 2)
                self.assertIn("cannot list tags", text)
                self.assertIn("https://127.0.0.1:9/cloud-on-premise.git", text)
                self.assertNotIn("s3cret-token", text)
                self.assertNotIn("wbuser", text)

    def test_fetch_failure_after_the_tag_is_found_warns(self):
        (self.bin / "fail-fetch").write_text(f"fatal: unable to access '{TOKEN_URL}/': Could not resolve host\n")
        for as_json in (True, False):
            code, out = self.check(as_json=as_json)
            text = json.dumps(out) if as_json else out
            self.assertEqual(code, 1)
            self.assertIn("found v3.0.0, cannot read its notes", text)
            self.assertNotIn("new in", text)
            self.assertNotIn("s3cret-token", text)
            self.assertNotIn("wbuser", text)

    def test_tag_without_env_example_or_changelog_warns(self):
        git(self.origin, "rm", "-q", ".env.example", "CHANGELOG_EN.md")
        git(self.origin, "commit", "-qm", "4.0.0")
        git(self.origin, "tag", "v4.0.0")
        code, report = self.check()
        items = self.items(report)
        self.assertEqual(code, 1)
        self.assertEqual(items["env"]["status"], "warn")
        self.assertEqual(items["env"]["detail"], "cannot read .env.example of v4.0.0")
        self.assertEqual(items["notes"]["status"], "warn")
        self.assertIn("cannot read CHANGELOG_EN.md of v4.0.0", items["notes"]["detail"])
        self.assertNotIn("changelog", report)

    def test_git_error_is_its_first_fatal_line(self):
        shutil.rmtree(self.install / ".git")
        code, report = self.check()
        self.assertEqual(code, 2)
        detail = self.items(report)["remote"]["detail"]
        self.assertIn("fatal: 'origin' does not appear to be a git repository", detail)
        self.assertNotIn("repository exists", detail)
        (self.bin / "fail-ls-remote").write_text("warning: first\nerror: last line\n\n")
        code, report = self.check()
        self.assertTrue(self.items(report)["remote"]["detail"].endswith(": error: last line"), report)

    def test_dubious_ownership_suggests_safe_directory(self):
        (self.bin / "fail-get-url").write_text(
            f"fatal: detected dubious ownership in repository at '{self.install}'\n")
        code, report = self.check()
        self.assertEqual(code, 2)
        detail = report["items"][0]["detail"]
        self.assertIn(f"git config --global --add safe.directory {self.install}", detail)

    def test_text_output_shows_the_changelog(self):
        code, text = self.check("--remote", str(self.origin), as_json=False)
        self.assertEqual(code, 1)
        self.assertIn("available: 3.0.0\n", text)
        self.assertIn("- three-zero-zero notes", text)


if __name__ == "__main__":
    unittest.main()
