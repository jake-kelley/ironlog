#!/usr/bin/env python3
"""Stage a checked Ironlog software bundle; never contact package/image registries."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit


def fail(message):
    raise ValueError(message)


def relative_name(name):
    if not re.fullmatch(r"[A-Za-z0-9_./+@-]+", name):
        fail(f"Unsupported bundle path: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or any(p in ("", ".", "..") for p in name.split("/")):
        fail(f"Unsafe bundle path: {name!r}")
    return name


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def verify_bundle(root, expected_os):
    files = set()
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            fail(f"Bundle contains a link or special file: {path.name}")
        name = relative_name(path.relative_to(root).as_posix())
        if path.is_file() and name != "SHA256SUMS":
            files.add(name)
    manifest = root / "SHA256SUMS"
    if not manifest.is_file():
        fail("Missing SHA256SUMS")
    if b"\r" in manifest.read_bytes():
        fail("SHA256SUMS must use LF line endings")
    entries = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([a-fA-F0-9]{64}) [ *](.+)", line)
        if not match:
            fail("Invalid SHA256SUMS entry")
        checksum, name = match.groups()
        relative_name(name)
        if name in entries or name == "SHA256SUMS":
            fail(f"Duplicate or self-referencing checksum entry: {name}")
        entries[name] = checksum.lower()
    if set(entries) != files:
        fail("SHA256SUMS must cover every bundle file exactly once")
    for name, checksum in entries.items():
        if digest(root / name) != checksum:
            fail(f"Checksum mismatch: {name}")
    metadata = (root / "bundle.env").read_bytes()
    canonical = f"FORMAT_VERSION=1\nOS_ID={expected_os}\nARCH=arm64\n".encode("ascii")
    if metadata != canonical:
        fail("Bundle must match requested OS, format 1, and arm64 architecture")
    required = ["rpm-repo/repodata/repomd.xml", "images.tsv",
                "grafana-plugins/grafana-clickhouse-datasource/plugin.json"]
    if any(name not in files for name in required):
        fail("Missing RPM metadata, image index, or Grafana plugin")
    if not list((root / "keys").glob("*.asc")) or not list((root / "rpm-repo").rglob("*.rpm")):
        fail("Bundle requires approved RPM signing keys and RPM packages")
    refs = set()
    if b"\r" in (root / "images.tsv").read_bytes():
        fail("images.tsv must use LF line endings")
    for line in (root / "images.tsv").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 2:
            fail("images.tsv requires reference<TAB>archive on each line")
        ref, archive = fields
        relative_name(archive)
        registry = ref.split("/", 1)[0]
        if "/" not in ref or not ("." in registry or ":" in registry or registry == "localhost"):
            fail("Image references must include their registry")
        if any(c.isspace() for c in ref) or ref in refs:
            fail("Duplicate or invalid image reference")
        if not archive.startswith("images/") or archive not in files:
            fail(f"Missing indexed image archive: {archive}")
        refs.add(ref)
    quadlets = Path(__file__).resolve().parent.parent / "quadlets"
    expected_refs = {line.split("=", 1)[1] for unit in quadlets.glob("*.container")
                     for line in unit.read_text(encoding="utf-8").splitlines() if line.startswith("Image=")}
    if not expected_refs or refs != expected_refs:
        fail("Image index must match all appliance Quadlet image references")
    plugin = json.loads((root / required[-1]).read_text(encoding="utf-8"))
    if plugin.get("id") != "grafana-clickhouse-datasource":
        fail("Wrong Grafana plugin id")
    return len(files)


def unpack(archive, target):
    """Extract regular files only; do not delegate link/path handling to tar."""
    seen = set()
    with tarfile.open(archive, "r:*") as stream:
        for member in stream:
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            name = name.rstrip("/") if member.isdir() else name
            if name in ("", ".") and member.isdir():
                continue
            relative_name(name)
            if name in seen or not (member.isfile() or member.isdir()):
                fail(f"Duplicate path, link, or special tar entry: {name}")
            seen.add(name)
            path = target / name
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, path.open("xb") as destination:
                    shutil.copyfileobj(source, destination)
                # Preserve executable plugin backends, strip privileged bits.
                path.chmod(member.mode & 0o777)


def fetch_s3(uri, destination, profile, region, endpoint):
    parsed = urlsplit(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lstrip("/") or parsed.query or parsed.fragment:
        fail("Use s3://bucket/key for one bundle archive")
    if not region:
        fail("--region is required for S3")
    common = ["aws", "--region", region]
    if profile:
        common += ["--profile", profile]
    identity = subprocess.run(common + ["sts", "get-caller-identity", "--output", "json"],
                              check=True, capture_output=True, text=True)
    account = json.loads(identity.stdout)["Account"]
    if not re.fullmatch(r"\d{12}", account):
        fail("Unexpected AWS account identity")
    command = common + ["s3api", "get-object", "--bucket", parsed.netloc,
                        "--key", parsed.path.lstrip("/"), "--expected-bucket-owner", account]
    if endpoint:
        command += ["--endpoint-url", endpoint]
    subprocess.run(command + [str(destination)], check=True, stdout=subprocess.DEVNULL)


def prepare(args):
    output = Path(args.output).resolve()
    if output.exists():
        fail("Output already exists; choose a new directory")
    is_s3 = args.source.startswith("s3://")
    source = None if is_s3 else Path(args.source).resolve()
    directory = source is not None and source.is_dir()
    if directory and (source == output or source in output.parents):
        fail("Output cannot be inside the input bundle")
    if not directory and not re.fullmatch(r"[a-fA-F0-9]{64}", args.sha256 or ""):
        fail("Archive input requires --sha256 from an independently trusted source")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ironlog-stage-", dir=output.parent) as temporary:
        work = Path(temporary)
        staged = work / "bundle"
        if directory:
            verify_bundle(source, args.os)
            shutil.copytree(source, staged)
        else:
            archive = work / "bundle.tar"
            if is_s3:
                fetch_s3(args.source, archive, args.profile, args.region, args.endpoint_url)
            else:
                shutil.copyfile(source, archive)
            if digest(archive) != args.sha256.lower():
                fail("Archive SHA-256 mismatch; nothing extracted")
            staged.mkdir()
            unpack(archive, staged)
        count = verify_bundle(staged, args.os)
        os.replace(staged, output)
    print(f"Verified {count} files for {args.os}/arm64: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Local directory/archive or s3://bucket/key archive")
    parser.add_argument("--output", required=True, help="New local directory for Packer artifact_bundle_dir")
    parser.add_argument("--os", choices=("rhel9", "rocky9"), required=True)
    parser.add_argument("--sha256", help="Trusted archive SHA-256 (required for archives, including S3)")
    parser.add_argument("--profile", help="AWS CLI profile; otherwise uses normal credential chain")
    parser.add_argument("--region", help="Explicit AWS region (required for S3)")
    parser.add_argument("--endpoint-url", help="Optional S3 endpoint URL; standard endpoint verification stays enabled")
    args = parser.parse_args()
    try:
        prepare(args)
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Artifact preparation failed: {error}\n")


if __name__ == "__main__":
    main()
