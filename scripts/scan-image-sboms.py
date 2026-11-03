#!/usr/bin/env python3
"""Scan declared runtime images with Syft and record their digest identity.

Reads runtime images from sbom/ironlog.inventory.json, scans each registry tag
for one platform, and writes one CycloneDX 1.6 file per component plus
scan-summary.json. Images are read from the registry, never executed. Results
describe the current registry artifact behind each tag, not a built appliance.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import subprocess


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def scan(syft, row, platform, output):
    target = output / f"{row['id']}.cdx.json"
    native = output / f"{row['id']}.syft.json.tmp"
    started = now()
    proc = subprocess.run(
        [syft, "scan", "registry:" + row["image"], "--platform", platform, "--scope", "squashed",
         "-q", "-o", f"cyclonedx-json@1.6={target}", "-o", f"syft-json={native}"],
        capture_output=True, text=True)
    result = {"component": row["id"], "reference": row["image"], "platform": platform,
              "scope": "squashed", "exitCode": proc.returncode, "started": started,
              "finished": now(), "file": target.name}
    if proc.returncode:
        target.unlink(missing_ok=True)
        native.unlink(missing_ok=True)
        result.update(status="failed", error=proc.stderr.strip()[-2000:])
        return result
    bom = json.loads(target.read_text(encoding="utf-8"))
    # Tag scans record the tag in CycloneDX; the native output has the digest.
    image = json.loads(native.read_text(encoding="utf-8"))["source"]["metadata"]
    native.unlink()
    repository = row["image"].rsplit(":", 1)[0]
    types = [component["type"] for component in bom.get("components", [])]
    result.update(
        status="success",
        scanReference=f"{repository}@{image['manifestDigest']}",
        manifestDigest=image["manifestDigest"],
        imageID=image.get("imageID"),
        architecture=image.get("architecture"),
        imageSize=image.get("imageSize"),
        labels=image.get("labels") or {},
        packages=sum(t not in ("file", "operating-system") for t in types),
        files=types.count("file"),
        operatingSystems=types.count("operating-system"),
        components=len(types))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--syft", default="syft", help="Syft command (default: syft on PATH)")
    parser.add_argument("--platform", default="linux/arm64", help="image platform (default: linux/arm64)")
    parser.add_argument("--output-dir", type=Path, help="default: repository sbom/registry-snapshot")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output_dir or root / "sbom/registry-snapshot"
    output.mkdir(parents=True, exist_ok=True)
    inventory = json.loads((root / "sbom/ironlog.inventory.json").read_text(encoding="utf-8"))
    rows = [row for row in inventory["components"] if row["category"] == "runtime" and row["image"]]
    version = json.loads(subprocess.check_output([args.syft, "version", "-o", "json"], text=True))["version"]
    results = [scan(args.syft, row, args.platform, output) for row in rows]
    # Drop scans of images no longer declared, so the folder matches the inventory.
    current = {result["file"] for result in results}
    for stale in output.glob("*.cdx.json"):
        if stale.name not in current:
            stale.unlink()
    summary = {
        "generator": f"Syft {version}",
        "purpose": "Current registry artifacts behind repository image tags, identified by manifest digest; not attestation of any built or deployed Ironlog appliance",
        "results": results,
        "countDefinitions": {
            "packages": "Detected library/application package occurrences; excludes file and operating-system components. Not deduplicated across images.",
            "components": "All CycloneDX components, including packages, file evidence and operating-system records.",
            "files": "CycloneDX file evidence components.",
        },
    }
    (output / "scan-summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    for result in results:
        print(f"{result['component']}: {result['status']} {result.get('packages', '-')} packages {result.get('manifestDigest', '')}")
    failed = [result["component"] for result in results if result["status"] != "success"]
    if failed:
        raise SystemExit("scan failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
