import os
import tempfile
import unittest
import urllib.error
from unittest import mock

import registry_check as rc


class ComposeImagesTest(unittest.TestCase):
    def test_substitutes_version_and_skips_comments(self):
        text = (
            "services:\n"
            "  db:\n"
            "    image: postgres:17-alpine\n"
            "  backend:\n"
            "    image: ghcr.io/wirenboard/on-premise/wbc-backend:${VERSION}\n"
            "  worker:\n"
            "    image: ghcr.io/wirenboard/on-premise/wbc-backend:${VERSION}\n"
            "  # old:\n"
            "  #  image: minio/minio:latest\n"
        )
        self.assertEqual(
            rc.compose_images(text, "2.1.0"),
            ["postgres:17-alpine", "ghcr.io/wirenboard/on-premise/wbc-backend:2.1.0"],
        )

    def test_unresolved_variable_is_an_error(self):
        with self.assertRaises(ValueError):
            rc.compose_images("    image: grafana/grafana:${GRAFANA_TAG}\n", "2.1.0")


class ParseReferenceTest(unittest.TestCase):
    def test_docker_hub_official_image(self):
        self.assertEqual(rc.parse_reference("redis:7.4.8-alpine"), ("registry-1.docker.io", "library/redis", "7.4.8-alpine"))

    def test_docker_hub_user_image(self):
        self.assertEqual(
            rc.parse_reference("timescale/timescaledb-ha:pg17.5-ts2.21.3"),
            ("registry-1.docker.io", "timescale/timescaledb-ha", "pg17.5-ts2.21.3"),
        )

    def test_explicit_registry_and_default_tag(self):
        self.assertEqual(
            rc.parse_reference("ghcr.io/wirenboard/on-premise/mc"),
            ("ghcr.io", "wirenboard/on-premise/mc", "latest"),
        )


class VersionLabelTest(unittest.TestCase):
    def test_matching_label_passes(self):
        self.assertIsNone(rc.version_label_error({"on-premise.version": "2.1.0"}, "2.1.0"))

    def test_testing_suffix_is_rejected(self):
        self.assertIn("-testing", rc.version_label_error({"on-premise.version": "2.1.0-testing"}, "2.1.0"))

    def test_missing_label_is_rejected(self):
        self.assertIsNotNone(rc.version_label_error({}, "2.1.0"))
        self.assertIsNotNone(rc.version_label_error(None, "2.1.0"))


class PickPlatformTest(unittest.TestCase):
    def test_takes_linux_amd64_from_index(self):
        index = {
            "manifests": [
                {"digest": "sha256:arm", "platform": {"os": "linux", "architecture": "arm64"}},
                {"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}},
            ]
        }
        self.assertEqual(rc.pick_platform(index), "sha256:amd")


class FakeRegistry:
    missing = set()
    label = "2.1.0"

    def __init__(self, registry, path):
        self.path = path

    def manifest(self, reference, method="GET"):
        if self.path in self.missing:
            raise urllib.error.HTTPError(self.path, 404, "not found", {}, None)
        return b"{}"

    def labels(self, tag):
        self.manifest(tag)
        return {rc.VERSION_LABEL: self.label}


@mock.patch.object(rc, "Registry", FakeRegistry)
@mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""})
class ExitCodeTest(unittest.TestCase):
    def setUp(self):
        FakeRegistry.missing = set()
        FakeRegistry.label = "2.1.0"
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.compose = os.path.join(self.dir.name, "docker-compose.yml")
        self.version = os.path.join(self.dir.name, "VERSION")
        with open(self.compose, "w") as f:
            f.write("    image: redis:7\n    image: ghcr.io/wirenboard/on-premise/wbc-backend:${VERSION}\n")
        with open(self.version, "w") as f:
            f.write("2.1.0")

    def pullable(self, *extra):
        with mock.patch("sys.stdout"):
            return rc.main(["pullable", "--compose", self.compose, "--version-file", self.version, *extra])

    def label(self):
        with mock.patch("sys.stdout"):
            return rc.main(["label", "--version", "2.1.0", "--tag", "2.1.0-testing"])

    def test_all_pullable_exits_zero(self):
        self.assertEqual(self.pullable(), 0)

    def test_missing_compose_image_exits_nonzero(self):
        FakeRegistry.missing = {"library/redis"}
        rows, failed = rc.check_pullable(["redis:7", "ghcr.io/wirenboard/on-premise/wbc-backend:2.1.0"])
        self.assertEqual(failed, 1)
        self.assertIn("NOT PULLABLE: HTTP 404", rows[0][1])
        self.assertEqual(self.pullable(), 1)

    def test_missing_extra_image_exits_nonzero(self):
        FakeRegistry.missing = {"wirenboard/on-premise/does-not-exist"}
        self.assertEqual(self.pullable("ghcr.io/wirenboard/on-premise/does-not-exist:0.0.0"), 1)

    def test_matching_labels_exit_zero(self):
        self.assertEqual(self.label(), 0)

    def test_testing_label_exits_nonzero(self):
        FakeRegistry.label = "2.1.0-testing"
        rows, failed = rc.check_labels(["ghcr.io/wirenboard/on-premise/wbc-backend:2.1.0-testing"], "2.1.0")
        self.assertEqual(failed, 1)
        self.assertEqual(self.label(), 1)

    def test_unreachable_label_image_exits_nonzero(self):
        FakeRegistry.missing = {"wirenboard/on-premise/wbc-worker"}
        self.assertEqual(self.label(), 1)


if __name__ == "__main__":
    unittest.main()
