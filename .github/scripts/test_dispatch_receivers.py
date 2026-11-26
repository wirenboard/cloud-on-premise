import calendar
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).with_name("dispatch-receivers.sh")

FAKE_GH = """#!{python}
import json, os, sys, time
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps({{"args": sys.argv[1:], "body": json.load(sys.stdin), "at": time.time()}}) + "\\n")
"""


class DispatchReceiversTest(unittest.TestCase):
    def test_records_time_right_before_dispatching_to_every_repository(self):
        tmp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        gh = tmp / "gh"
        gh.write_text(FAKE_GH.format(python=sys.executable))
        gh.chmod(0o755)
        log = tmp / "calls.jsonl"
        output = tmp / "output"
        env = dict(
            os.environ,
            PATH=f"{tmp}:{os.environ['PATH']}",
            FAKE_GH_LOG=str(log),
            GITHUB_OUTPUT=str(output),
            REGISTRY="ghcr.io",
            TARGET="testing",
            IMAGE_VERSION="2.1.0",
            REF='onprem-release/2.1.0", "TARGET": "release',
        )
        started = int(time.time())
        result = subprocess.run(
            ["bash", str(SCRIPT), "cloud-backend", "cloud-tunnel"], env=env, capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(
            [c["args"] for c in calls],
            [["api", "--method", "POST", f"repos/wirenboard/{r}/dispatches", "--input", "-"] for r in ("cloud-backend", "cloud-tunnel")],
        )
        self.assertEqual(
            calls[0]["body"],
            {
                "event_type": "build-on-premise",
                "client_payload": {
                    "REGISTRY": "ghcr.io",
                    "TARGET": "testing",
                    "IMAGE_VERSION": "2.1.0",
                    "GROUP": "on-premise",
                    "REF": 'onprem-release/2.1.0", "TARGET": "release',
                },
            },
        )

        since = output.read_text().strip().removeprefix("since=")
        since_ts = calendar.timegm(time.strptime(since, "%Y-%m-%dT%H:%M:%SZ"))
        self.assertGreaterEqual(since_ts, started)
        self.assertLessEqual(since_ts, calls[0]["at"])


if __name__ == "__main__":
    unittest.main()
