# Ironlog BOM / SBOM evidence

Assessment date: **2026-11-03**. Deployment model: **owner-operated, non-SaaS**.
Runtime primary licenses: **OSI-approved** (Apache-2.0, AGPL-3.0-only,
MPL-2.0); HyperDX and MongoDB (SSPL) were removed 2026-11-03.
Artifact license review: **incomplete**.
FOCI: **not established**. Inventory covers constituent software; Ironlog
deployment/configuration bundle is not listed as a separate software product.

[Open HTML report](../docs/reports/ironlog-supply-chain-report.html) for full
assessment, searchable BOM and package explorer. Report works offline;
regenerate with `python scripts/build-supply-chain-report.py`
(`markdown-it-py` required for Markdown rendering).

| File | Scope |
|---|---|
| [ironlog-bom.csv](ironlog-bom.csv) | Human-readable/exportable declared-component BOM, including runtime, host requirements, build tools and alternatives |
| [ironlog.inventory.json](ironlog.inventory.json) | Maintained source inventory, supplier/license evidence and unresolved items |
| [ironlog.cdx.json](ironlog.cdx.json) | CycloneDX 1.6 declared-component SBOM; explicitly `incomplete` |
| [registry-snapshot/scan-summary.json](registry-snapshot/scan-summary.json) | Scanned tags, resolved manifest digests, timestamps, platform, results and image labels |
| [FOCI and FOSS assessment](../docs/foss-foci-assessment.md) | Findings, decision limits, evidence and completion requirements |

## Package-level image SBOMs

Syft **1.56.0**, Linux/ARM64, squashed/final filesystem, registry-only scans
of each declared tag on **2026-11-03**, identified by the resolved manifest
digest. Images were read, not executed. These describe **current registry
artifacts**, not a historic build or a deployed appliance.

| Image | CycloneDX 1.6 | Packages | File evidence | All components |
|---|---|---:|---:|---:|
| ClickHouse 26.8.34.13 | [clickhouse.cdx.json](registry-snapshot/clickhouse.cdx.json) | 111 | 4,463 | 4,575 |
| Grafana 13.3.0 | [grafana.cdx.json](registry-snapshot/grafana.cdx.json) | 1,878 | 837 | 2,716 |
| Vector 0.61.0-debian | [vector.cdx.json](registry-snapshot/vector.cdx.json) | 85 | 3,106 | 3,192 |

Total: **2,074 package occurrences across the three runtime images**, plus
**8,406 file-evidence components and three operating-system records**:
**10,483 CycloneDX components**. Packages are not deduplicated across images.
Grafana's packages are mostly Go modules (1,846). File-evidence counts are
not comparable with the 2026-11-02 run, which recorded far fewer file
components per image. HyperDX and MongoDB scans were deleted with the
components on 2026-11-03.

Scanner output is preserved separately from manually researched license
decisions. Many packages have missing license data; some Debian license
entries are content hashes rather than recognized SPDX licenses. Such entries
are **unresolved**, not proof of FOSS or license clearance. Scanners can miss
static, stripped, vendored or frontend dependencies. No CVE, malware, supplier
clearance or reproducible-build assessment is implied.

## Regenerate declared inventory

From repository root:

```sh
python scripts/generate-sbom.py
```

This verifies source paths and checks inventory image references against
Compose and appliance Quadlets. Unknown versions/licenses stay unknown.
Generator records Git HEAD plus dirty-tree status; existing uncommitted
documentation/diagram work is not represented as a new source release.

## Regenerate image evidence

Install an approved [Syft release](https://github.com/anchore/syft/releases),
then from repository root:

```sh
python scripts/scan-image-sboms.py            # syft on PATH
python scripts/scan-image-sboms.py --syft /path/to/syft --platform linux/arm64
```

This scans every runtime image in `ironlog.inventory.json`, writes one
CycloneDX 1.6 file per component, records the resolved manifest digest in
`scan-summary.json`, and removes scans of images no longer declared. A
failed scan exits non-zero. Each scan is equivalent to:

```sh
syft scan 'registry:<image>:<tag>' --platform linux/arm64 --scope squashed \
  -o cyclonedx-json@1.6=component.cdx.json
```

If registry rate limits recur, use authenticated access or a known approved
image archive, and record actual digest and provenance. Do not substitute an
unverified similarly named repository. Offline archives can be scanned with
`syft scan oci-archive:/path/image.tar -o cyclonedx-json@1.6=component.cdx.json`.

## CI

`.github/workflows/sbom.yml` runs on pushes and pull requests that touch
image references or the inventory, weekly (Monday 06:17 UTC), and on manual
dispatch. It runs `generate-sbom.py` (which fails on inventory/Compose/Quadlet
drift), scans the repository directory with Syft, and uploads the results as
a 30-day workflow artifact. Manual dispatch with `scan_images` also runs
`scan-image-sboms.py`.

Grype then matches the image SBOMs against its vulnerability database: the
fresh scans when dispatched with `scan_images`, otherwise the committed
`registry-snapshot/`. Per-image table and JSON reports land in
`vulnerabilities/` in the artifact, with severity counts in the run summary.
The Grype pass is report-only and does not fail the job. Matches are not
triaged and are not deduplicated across binaries or images.

`scripts/build-vuln-report.py` turns the declared inventory, image SBOMs and
Grype reports into a self-contained, color-coded `index.html`: summary tiles,
a severity bar per image, the declared BOM with license and FOCI status, the
packages in each image with their worst matched vulnerability, filterable
findings grouped by vulnerability and package version, and SBOM downloads.
Light and dark themes follow the browser setting. Runs on `main` publish it to GitHub Pages; pull requests do not.
CI output is not committed back to the repository.

## Complete a release-specific SBOM

1. Record selected RHEL AMI ID/owner, build Git revision, architecture, RPM
   repositories and exact installed RPM NEVRA/license inventory. On the built
   host, capture `rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{LICENSE}\n'`.
2. Scan approved base/appliance filesystem and each **actually baked** image
   or saved archive. Include final host RPMs, container base packages, static
   libraries and bundled application dependencies; capture unresolved findings.
3. Capture actual datasource `plugin.json` version and scan the unpacked
   plugin/backend. Complete exact source mapping for bundled binaries.
4. Reconcile inventory to final artifact identities and preserve provenance,
   license texts/notices and required corresponding source. Record analyzer
   versions and any exclusions; do not label unknown dependencies complete.
5. Obtain supplier ownership/control disclosures and designated customer
   security/procurement review. An SBOM never establishes FOCI clearance.

These are release-evidence instructions, not new checksum/bucket-owner gates
in Ironlog's build or private-artifact workflow. No AWS resources were launched.
