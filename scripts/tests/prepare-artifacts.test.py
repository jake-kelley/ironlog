#!/usr/bin/env python3
"""Host-only tests: no AWS calls, RPM installation, or container runtime."""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("artifacts", Path(__file__).parents[1] / "prepare-artifacts.py")
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class BundleTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parents[2] / ".decurion"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "input"
        files = {
            "bundle.env": "FORMAT_VERSION=1\nOS_ID=rhel9\nARCH=arm64\n",
            "rpm-repo/repodata/repomd.xml": "test metadata",
            "rpm-repo/test.rpm": "test rpm",
            "keys/vendor.asc": "test key",
            "images.tsv": "".join(ref + "\timages/test.tar\n" for ref in (
                "docker.io/clickhouse/clickhouse-server:24.8", "docker.io/grafana/grafana-oss:11.4.0",
                "docker.hyperdx.io/hyperdx/hyperdx:2.19.0", "docker.io/library/mongo:7.0",
                "docker.io/timberio/vector:0.57.0-debian")),
            "images/test.tar": "test archive",
            "grafana-plugins/grafana-clickhouse-datasource/plugin.json": json.dumps({"id": "grafana-clickhouse-datasource"}),
        }
        for name, content in files.items():
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode("utf-8"))
        # Old manifests are ordinary bundle files and do not affect staging.
        (self.bundle / "SHA256SUMS").write_text("obsolete manifest\n")

    def args(self, **changes):
        values = dict(source=str(self.bundle), output=str(self.root / "output"), os="rhel9",
                      profile=None, region=None, endpoint_url=None)
        values.update(changes)
        return argparse.Namespace(**values)

    def test_valid_local_directory_and_no_overwrite(self):
        artifacts.prepare(self.args())
        self.assertTrue((self.root / "output/images.tsv").is_file())
        with self.assertRaisesRegex(ValueError, "already exists"):
            artifacts.prepare(self.args())

    def test_files_and_old_manifest_do_not_require_checksums(self):
        (self.bundle / "images/test.tar").write_text("tampered")
        (self.bundle / "extra").write_text("unlisted")
        artifacts.prepare(self.args())
        self.assertTrue((self.root / "output/extra").is_file())
        self.assertEqual((self.root / "output/SHA256SUMS").read_text(), "obsolete manifest\n")

    def test_wrong_os_and_malformed_bundle(self):
        with self.assertRaisesRegex(ValueError, "match requested OS"):
            artifacts.prepare(self.args(os="rocky9"))
        (self.bundle / "images.tsv").write_bytes(b"not-an-image-index\n")
        with self.assertRaisesRegex(ValueError, "reference<TAB>archive"):
            artifacts.prepare(self.args())

    def test_valid_archive_without_checksum(self):
        archive = self.root / "bundle.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            stream.add(self.bundle, arcname=".")
        artifacts.prepare(self.args(source=str(archive)))
        self.assertTrue((self.root / "output/bundle.env").exists())

    def test_reject_tar_traversal_links_and_duplicate_entries(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("link", tarfile.SYMTYPE), ("duplicate", tarfile.REGTYPE)]:
            archive = self.root / "unsafe.tar"
            with tarfile.open(archive, "w") as stream:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = 1 if kind == tarfile.REGTYPE else 0
                member.linkname = "../../outside" if kind == tarfile.SYMTYPE else ""
                stream.addfile(member, io.BytesIO(b"x") if member.size else None)
                if name == "duplicate":
                    stream.addfile(member, io.BytesIO(b"x"))
            with self.assertRaises(ValueError):
                artifacts.prepare(self.args(source=str(archive)))
            self.assertFalse((self.root / "escape").exists())

    def test_s3_uses_single_get_object_without_owner_check(self):
        archive = self.root / "bundle.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            stream.add(self.bundle, arcname=".")
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            Path(command[-1]).write_bytes(archive.read_bytes())
            return argparse.Namespace()
        with patch.object(artifacts.subprocess, "run", side_effect=run):
            artifacts.prepare(self.args(source="s3://private-bucket/bundle.tar.gz", profile="build",
                                        region="us-east-1", endpoint_url="https://s3.example.test"))
        self.assertTrue((self.root / "output/bundle.env").is_file())
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:5], ["aws", "--region", "us-east-1", "--profile", "build"])
        self.assertIn("--endpoint-url", calls[0])
        self.assertIn("get-object", calls[0])
        self.assertNotIn("get-caller-identity", calls[0])
        self.assertNotIn("--expected-bucket-owner", calls[0])


if __name__ == "__main__":
    unittest.main()
