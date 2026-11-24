import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("wait-receivers.sh")
SINCE = "2026-11-27T10:00:00Z"

# Serves runs from a fixture through the real jq, so the script's query and --jq expressions are what is tested.
FAKE_GH = """#!{python}
import json, os, subprocess, sys, urllib.parse
path = sys.argv[2]
expr = sys.argv[sys.argv.index("--jq") + 1]
state_file = os.environ["FAKE_GH_STATE"]
state = json.load(open(state_file))
repo = state[path.split("/")[2]]
repo.setdefault("queries", []).append(path)
error = repo.get("errors", []) and repo["errors"].pop(0)
json.dump(state, open(state_file, "w"))
if error:
    sys.stderr.write(error + "\\n")
    sys.exit(1)
url = urllib.parse.urlsplit(path)
if "/workflows/" in url.path:
    query = urllib.parse.parse_qs(url.query)
    since = query["created"][0].removeprefix(">=")
    body = {{"workflow_runs": [r for r in repo["runs"] if r["created_at"] >= since]}}
else:
    body = next(r for r in repo["runs"] if r["id"] == int(url.path.rsplit("/", 1)[1]))
sys.exit(subprocess.run(["jq", "-r", expr], input=json.dumps(body), text=True).returncode)
"""


def run(run_id, created_at, conclusion="success"):
    return {
        "id": run_id,
        "created_at": created_at,
        "status": "completed",
        "conclusion": conclusion,
        "html_url": f"https://github.com/wirenboard/x/actions/runs/{run_id}",
    }


class WaitReceiversTest(unittest.TestCase):
    def run_script(self, repos):
        tmp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        gh = tmp / "gh"
        gh.write_text(FAKE_GH.format(python=sys.executable))
        gh.chmod(0o755)
        state = tmp / "state.json"
        state.write_text(json.dumps(repos))
        summary = tmp / "summary.md"
        env = dict(
            os.environ,
            PATH=f"{tmp}:{os.environ['PATH']}",
            FAKE_GH_STATE=str(state),
            GITHUB_STEP_SUMMARY=str(summary),
            POLL="0",
            START_TIMEOUT="-1",
        )
        result = subprocess.run(["bash", str(SCRIPT), SINCE, *repos], env=env, capture_output=True, text=True, timeout=30)
        self.state = json.loads(state.read_text())
        return result.returncode, summary.read_text()

    def test_all_builds_succeeded(self):
        code, summary = self.run_script(
            {"cloud-backend": {"runs": [run(7, "2026-11-27T10:00:05Z")]}, "cloud-tunnel": {"runs": [run(8, "2026-11-27T10:00:06Z")]}}
        )
        self.assertEqual(code, 0)
        self.assertIn("| cloud-backend | success | https://github.com/wirenboard/x/actions/runs/7 |", summary)

    def test_takes_the_oldest_dispatch_run_created_since_the_dispatch(self):
        runs = [
            run(333, "2026-11-27T10:03:00Z", "success"),
            run(222, "2026-11-27T10:00:02Z", "failure"),
            run(111, "2026-11-27T09:59:58Z", "success"),
        ]
        code, summary = self.run_script({"cloud-backend": {"runs": runs}})
        self.assertEqual(code, 1)
        self.assertIn("| cloud-backend | failure | https://github.com/wirenboard/x/actions/runs/222 |", summary)
        query = self.state["cloud-backend"]["queries"][0]
        self.assertIn("event=repository_dispatch", query)
        self.assertIn(f"created=%3E%3D{SINCE}", query)

    def test_failed_build_fails_the_job(self):
        code, summary = self.run_script(
            {
                "cloud-backend": {"runs": [run(7, "2026-11-27T10:00:05Z")]},
                "cloud-tunnel": {"runs": [run(8, "2026-11-27T10:00:05Z", "failure")]},
            }
        )
        self.assertEqual(code, 1)
        self.assertIn("| cloud-tunnel | failure |", summary)

    def test_receiver_that_never_started_fails_the_job(self):
        code, summary = self.run_script({"cloud-webssh": {"runs": [run(5, "2026-11-27T09:00:00Z")]}})
        self.assertEqual(code, 1)
        self.assertIn("| cloud-webssh | not started |", summary)

    def test_single_rate_limit_answer_is_retried(self):
        code, summary = self.run_script(
            {
                "cloud-backend": {
                    "runs": [run(7, "2026-11-27T10:00:05Z")],
                    "errors": ["HTTP 403: You have exceeded a secondary rate limit"],
                }
            }
        )
        self.assertEqual(code, 0)
        self.assertIn("| cloud-backend | success |", summary)

    def test_lasting_403_names_token_and_workflow_and_summary_written(self):
        code, summary = self.run_script(
            {
                "cloud-backend": {"runs": [run(7, "2026-11-27T10:00:05Z")]},
                "cloud-frontend": {"runs": [], "errors": ["HTTP 403: Resource not accessible by personal access token"] * 3},
            }
        )
        self.assertEqual(code, 1)
        self.assertIn(
            "GHCR_TOKEN lacks Actions: read or build_onpremise_dispatch.yml is missing in wirenboard/cloud-frontend", summary
        )
        self.assertIn("| cloud-backend | success |", summary)

    def test_lasting_api_failure_still_writes_summary(self):
        code, summary = self.run_script(
            {"cloud-backend": {"runs": [run(7, "2026-11-27T10:00:05Z")], "errors": ["HTTP 502: Bad Gateway"] * 3}}
        )
        self.assertEqual(code, 1)
        self.assertIn("gh api failed: HTTP 502", summary)


if __name__ == "__main__":
    unittest.main()
