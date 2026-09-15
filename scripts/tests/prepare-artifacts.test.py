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
        self.seal()

    def seal(self):
        lines = [f"{artifacts.digest(path)}  {path.relative_to(self.bundle).as_posix()}\n"
                 for path in sorted(self.bundle.rglob("*")) if path.is_file() and path.name != "SHA256SUMS"]
        (self.bundle / "SHA256SUMS").write_bytes("".join(lines).encode("utf-8"))

    def args(self, **changes):
        values = dict(source=str(self.bundle), output=str(self.root / "output"), os="rhel9",
                      sha256=None, profile=None, region=None, endpoint_url=None)
        values.update(changes)
        return argparse.Namespace(**values)

    def test_valid_local_directory_and_no_overwrite(self):
        artifacts.prepare(self.args())
        self.assertTrue((self.root / "output/images.tsv").is_file())
        with self.assertRaisesRegex(ValueError, "already exists"):
            artifacts.prepare(self.args())

    def test_tampered_and_unlisted_files(self):
        (self.bundle / "images/test.tar").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            artifacts.prepare(self.args())
        self.seal()
        (self.bundle / "extra").write_text("unlisted")
        with self.assertRaisesRegex(ValueError, "every bundle file"):
            artifacts.prepare(self.args())
        self.assertFalse((self.root / "output").exists())

    def test_wrong_os_and_duplicate_checksum(self):
        with self.assertRaisesRegex(ValueError, "match requested OS"):
            artifacts.prepare(self.args(os="rocky9"))
        manifest = self.bundle / "SHA256SUMS"
        manifest.write_bytes((manifest.read_text() + manifest.read_text().splitlines()[0] + "\n").encode("utf-8"))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            artifacts.prepare(self.args())

    def test_archive_hash_and_valid_tar(self):
        archive = self.root / "bundle.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            stream.add(self.bundle, arcname=".")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            artifacts.prepare(self.args(source=str(archive), sha256="0" * 64))
        artifacts.prepare(self.args(source=str(archive), sha256=artifacts.digest(archive)))
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
                artifacts.prepare(self.args(source=str(archive), sha256=artifacts.digest(archive)))
            self.assertFalse((self.root / "escape").exists())

    def test_s3_enforces_current_account_owner(self):
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            return argparse.Namespace(stdout='{"Account":"123456789012"}')
        with patch.object(artifacts.subprocess, "run", side_effect=run):
            artifacts.fetch_s3("s3://private-bucket/bundle.tar.gz", self.root / "download", "build", "us-east-1", None)
        self.assertEqual(calls[0][:5], ["aws", "--region", "us-east-1", "--profile", "build"])
        self.assertIn("get-caller-identity", calls[0])
        index = calls[1].index("--expected-bucket-owner")
        self.assertEqual(calls[1][index + 1], "123456789012")

    def test_require_archive_digest_before_aws(self):
        with patch.object(artifacts.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "requires --sha256"):
                artifacts.prepare(self.args(source="s3://private-bucket/bundle.tar.gz"))
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
