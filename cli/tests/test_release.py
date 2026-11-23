"""make_release.yml: every `files:` pattern of the release step matches a file."""

import glob
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github" / "workflows" / "make_release.yml"


def release_patterns():
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "files: |")
    indent = len(lines[start]) - len(lines[start].lstrip())
    patterns = []
    for line in lines[start + 1:]:
        if not line.strip() or len(line) - len(line.lstrip()) <= indent:
            break
        patterns.append(line.strip())
    return patterns


class ReleaseFilesTest(unittest.TestCase):
    def test_every_release_file_pattern_matches(self):
        patterns = release_patterns()
        self.assertIn("cli/dist/wb-onprem.pyz", patterns)
        with tempfile.TemporaryDirectory() as dist:
            subprocess.run(["bash", str(REPO / "cli" / "build.sh"), dist], check=True, capture_output=True)
            for pattern in patterns:
                with self.subTest(pattern):
                    path = (os.path.join(dist, pattern.removeprefix("cli/dist/")) if pattern.startswith("cli/dist/")
                            else str(REPO / pattern))
                    self.assertTrue([p for p in glob.glob(path, recursive=True) if os.path.isfile(p)], pattern)


if __name__ == "__main__":
    unittest.main()
