#!/usr/bin/env python3
"""Generate the declared-component CycloneDX inventory and BOM CSV.

No network requests, image execution, artifact verification gates, or license
inference. Package-level registry SBOMs are separate, immutable scan evidence.
"""
import argparse
import csv
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import uuid


def generate(root, output):
    inventory = json.loads((root / "sbom/ironlog.inventory.json").read_text(encoding="utf-8"))
    rows = inventory["components"]
    ids = {row["id"] for row in rows}
    if len(ids) != len(rows):
        raise ValueError("duplicate inventory component IDs")
    for row in rows:
        for source in row["source_paths"]:
            if not (root / source).is_file():
                raise ValueError(f"missing source evidence: {source}")
        if not set(row["depends_on"]) <= ids:
            raise ValueError(f"unknown dependency: {row['id']}")
    # Catch image inventory drift without loading .env, secrets, or cloud state.
    declared = {row["image"] for row in rows if row["category"] == "runtime" and row["image"]}
    quadlet_images = set()
    for path in (root / "quadlets").glob("*.container"):
        quadlet_images.update(re.findall(r"^Image=(.+)$", path.read_text(), re.M))
    if declared != quadlet_images:
        raise ValueError("inventory runtime images differ from appliance Quadlets")
    compose = (root / "docker-compose.yml").read_text(encoding="utf-8")
    compose_images = set(re.findall(r"^\s+image:\s*(\S+)", compose, re.M))
    if {row["image"] for row in rows if row["image"]} != compose_images:
        raise ValueError("inventory images differ from Compose (including demo)")
    summary = root / "sbom/registry-snapshot/scan-summary.json"
    if summary.is_file():
        scanned = {result["reference"] for result in json.loads(summary.read_text(encoding="utf-8"))["results"]}
        if scanned != declared:
            raise ValueError("image scans differ from inventory; run scripts/scan-image-sboms.py")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip())
    timestamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    subject = "ironlog-declared-inventory"
    components = []
    for row in rows:
        properties = {
            "ironlog:category": row["category"],
            "ironlog:evidence:sourcePaths": "; ".join(row["source_paths"]),
            "ironlog:foci:status": row["foci_status"],
            "ironlog:license:scope": "primary upstream project only; not entire container or dependency tree",
            "ironlog:version:status": "declared constraint" if row["version"].startswith(">=") else "declared; not appliance-measured",
        }
        if row["image"]:
            properties["ironlog:image:declaredReference"] = row["image"]
        if row.get("license_review_status"):
            properties["ironlog:license:reviewStatus"] = row["license_review_status"]
            properties["ironlog:license:reviewColor"] = row["review_color"]
        if row["version"].startswith(">="):
            properties["ironlog:version:constraint"] = row["version"]
        component = {
            "bom-ref": row["id"],
            "type": "operating-system" if row["category"].endswith("platform") else "application",
            "name": row["name"],
            "supplier": {"name": row["supplier"]},
            "description": row["notes"],
            "properties": [{"name": key, "value": value} for key, value in properties.items()],
        }
        if row["version"] and not row["version"].startswith(">="):
            component["version"] = row["version"]
        if row["license_expression"]:
            component["licenses"] = [{"expression": row["license_expression"]}]
        if row["evidence_urls"]:
            component["externalReferences"] = [{"type": "other", "url": url} for url in row["evidence_urls"]]
        components.append(component)
    bom = {
        "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
        "serialNumber": "urn:uuid:" + str(uuid.uuid4()),
        "metadata": {
            "timestamp": timestamp,
            "tools": {"components": [{"type": "application", "name": "ironlog-declared-inventory-generator", "version": "1"}]},
            "component": {"bom-ref": subject, "type": "platform", "name": "Ironlog deployment inventory", "version": revision},
            "properties": [
                {"name": "ironlog:scope", "value": inventory["scope"]},
                {"name": "ironlog:workingTreeDirty", "value": str(dirty).lower()},
                {"name": "ironlog:deploymentModel", "value": "owner-operated; non-SaaS"},
                {"name": "ironlog:inventory:scope", "value": "Constituent software only; Ironlog deployment/configuration bundle excluded as a separate software product"},
                {"name": "ironlog:license:policy", "value": inventory["license_policy"]["intended_use"]},
                {"name": "ironlog:foss:status", "value": inventory["foss_status"]},
                {"name": "ironlog:foci:status", "value": inventory["foci_status"]},
                {"name": "ironlog:knownGaps", "value": " | ".join(inventory["known_gaps"])},
                {"name": "ironlog:profileSemantics", "value": "Declaration inventory across labeled profiles; RHEL and Rocky are alternatives. Not one installed appliance."},
            ],
        },
        "components": components,
        "dependencies": [{"ref": row["id"], "dependsOn": row["depends_on"]} for row in rows if row["depends_on"]],
        "compositions": [{"aggregate": "incomplete", "assemblies": [subject], "dependencies": [row["id"] for row in rows]}],
    }
    output.mkdir(parents=True, exist_ok=True)
    (output / "ironlog.cdx.json").write_text(json.dumps(bom, indent=2) + "\n", encoding="utf-8")
    fields = ["id", "name", "category", "version", "license_expression", "supplier", "image", "foci_status", "notes", "source_paths", "evidence_urls", "license_review_status", "review_color"]
    with (output / "ironlog-bom.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            record = {key: row.get(key, "") for key in fields}
            for key in ("source_paths", "evidence_urls"):
                record[key] = "; ".join(record[key])
            writer.writerow(record)
    print(f"Generated {len(rows)} declared components; completeness=incomplete; no FOCI clearance asserted.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="default: repository sbom directory")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    generate(repo, args.output_dir or repo / "sbom")
