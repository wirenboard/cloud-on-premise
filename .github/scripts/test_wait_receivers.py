import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("wait-receivers.sh")

FAKE_GH = """#!{python}
import json, os, sys
path = sys.argv[2]
repo = path.split("/")[2]
mode = json.load(open(os.environ["FAKE_GH_MODES"]))[repo]
if mode == "forbidden":
    sys.stderr.write("HTTP 403: Resource not accessible by personal access token\\n")
    sys.exit(1)
if mode == "flaky":
    sys.stderr.write("HTTP 502: Bad Gateway\\n")
    sys.exit(1)
if "/workflows/" in path:
    print("" if mode == "not-started" else f"7 https://github.com/wirenboard/{{repo}}/actions/runs/7")
else:
    print(f"completed {{mode}}")
"""


class WaitReceiversTest(unittest.TestCase):
    def run_script(self, modes):
        tmp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        gh = tmp / "gh"
        gh.write_text(FAKE_GH.format(python=sys.executable))
        gh.chmod(0o755)
        (tmp / "modes.json").write_text(json.dumps(modes))
        summary = tmp / "summary.md"
        env = dict(
            os.environ,
            PATH=f"{tmp}:{os.environ['PATH']}",
            FAKE_GH_MODES=str(tmp / "modes.json"),
            GITHUB_STEP_SUMMARY=str(summary),
            POLL="0",
            START_TIMEOUT="-1",
        )
        result = subprocess.run(
            ["bash", str(SCRIPT), "2026-11-27T10:00:00Z", *modes], env=env, capture_output=True, text=True, timeout=30
        )
        return result.returncode, summary.read_text()

    def test_all_builds_succeeded(self):
        code, summary = self.run_script({"cloud-backend": "success", "cloud-tunnel": "success"})
        self.assertEqual(code, 0)
        self.assertIn("| cloud-backend | success | https://github.com/wirenboard/cloud-backend/actions/runs/7 |", summary)

    def test_failed_build_fails_the_job(self):
        code, summary = self.run_script({"cloud-backend": "success", "cloud-tunnel": "failure"})
        self.assertEqual(code, 1)
        self.assertIn("| cloud-tunnel | failure |", summary)

    def test_receiver_that_never_started_fails_the_job(self):
        code, summary = self.run_script({"cloud-webssh": "not-started"})
        self.assertEqual(code, 1)
        self.assertIn("| cloud-webssh | not started |", summary)

    def test_token_without_actions_read_is_named_and_summary_written(self):
        code, summary = self.run_script({"cloud-backend": "success", "cloud-frontend": "forbidden"})
        self.assertEqual(code, 1)
        self.assertIn("GHCR_TOKEN needs Actions: read in wirenboard/cloud-frontend", summary)
        self.assertIn("| cloud-backend | success |", summary)

    def test_api_failure_still_writes_summary(self):
        code, summary = self.run_script({"cloud-backend": "flaky"})
        self.assertEqual(code, 1)
        self.assertIn("gh api failed: HTTP 502", summary)


if __name__ == "__main__":
    unittest.main()
