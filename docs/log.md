# SIEM documentation update log

## 2026-11-03

* **BOM/SBOM regenerated**: Declared inventory, [BOM](bom.md), CycloneDX bundle, [FOSS/FOCI review](foss-foci-assessment.md) and [HTML report](reports/ironlog-supply-chain-report.html) now cover ClickHouse 26.8.34.13, Grafana 13.3.0 with plugin 4.23.4, and Vector 0.61.0; HyperDX and MongoDB removed. Syft 1.56.0 ARM64 scans of the three runtime images: 2,074 packages, 10,483 components. Added `scripts/scan-image-sboms.py` and a GitHub Actions SBOM workflow. FOCI remains not established.
* **Grafana-only UI**: Removed HyperDX, its MongoDB app-state store, the `svc_hyperdx` ClickHouse account and the HyperDX Keycloak client. Grafana is the single UI; the new Log Search dashboard and `siem.log_search` view replace HyperDX search.
* **Upgrades**: ClickHouse 24.8 -> 26.8.34.13 LTS with text (inverted) indexes on free-text `message` columns, migrated in place on existing installs; Grafana 11.4.0 -> `grafana/grafana:13.3.0` with the ClickHouse plugin pinned at 4.23.4; Vector 0.57.0 -> 0.61.0; k3s demo v1.35.6 -> v1.37.1. Vector was re-evaluated against OpenTelemetry Collector and alternatives and retained.
* **Diagrams**: Rebuilt the architecture diagram with per-component role captions, ports, ClickHouse internals, optional/not-deployed markings and a legend; added a component role table to [architecture](architecture.md).
* **Diagrams**: Rebuilt architecture overview, ingestion paths and user access/query auditing through hosted Drawbridge MCP. Uniform role colors, aligned zones and spaced connectors accompany editable draw.io, SVG, PNG and round-trip topology exports. Added reproducible renderer and layout profiles; no runtime topology or deployment changed.

## 2026-11-02

* **Coverage update**: Completed [HyperDX ARM64 SBOM](../sbom/registry-snapshot/hyperdx.cdx.json) by manifest digest. All five runtime images now scanned. Corrected counting: 2,180 package occurrences, 3,509 file-evidence components and five OS records, totaling 5,694 CycloneDX components; earlier 3,377 total included files, not just packages. Host/plugin release evidence remains incomplete.
* **Policy clarification**: Excluded Ironlog deployment/configuration bundle as a separate software component. MongoDB SSPL is accepted under operator's intended-use FOSS policy and marked yellow; OSI classification and unresolved FOCI findings remain separately documented.
* **Report**: Added [offline HTML supply-chain report](reports/ironlog-supply-chain-report.html) with full assessment, searchable component/package inventories, source links and print styling. Embedded evidence remains distinct from release attestation.
* **Assessment**: Added [FOSS/FOCI review](foss-foci-assessment.md), [BOM](bom.md), CSV and CycloneDX SBOM bundle. Owner-operated non-SaaS use is distinguished from strict FOSS classification. Four current ARM64 registry images scanned by digest; host, plugin and HyperDX coverage remain incomplete. No license grant, supplier clearance or runtime changes made.

- 2026-09-15: Local bootstrap defaults to Podman, with explicit Docker selection persisted in `.env` and a shared Compose wrapper. Bootstrap checks runtime and provider readiness before writing `.env`; Docker volumes are not automatically migrated to Podman. Appliance Quadlets remain Podman-based. Runtime selection is tested with mocks; live Podman Compose validation remains open.


## 2026-09-15
* **Update**: Added [RHEL 9 and private software builds](private-software-builds.md), covering OS selection, S3 staging, RPM/image/plugin bundle contents, and private build networking. Removed checksum and bucket-owner requirements at operator request.

## 2026-09-14
* **Update**: Default deployments use [native local app accounts](local-auth.md). Keycloak integration is deferred and no identity provider is bundled. Updated deployment and control notes to remove current SSO/MFA claims.
* **Update**: Refreshed appliance runbooks for single-builder RHEL/Rocky selection, local/S3 artifact staging, baked offline runtime assets, and native local app authentication. No live RHEL build, boot, or compliance result is recorded.

## 2026-07-16
* **Update**: Converted the documentation set into an Open Knowledge Format (OKF v0.1) bundle — added frontmatter to every concept, plus this log and the bundle [index](index.md).

## 2026-07-15
* **Creation**: Added the [querying guide](query-guide.md).
* **Update**: Documented Windows (Phase 4) onboarding in [host and Kubernetes ingestion](host-ingestion.md); recorded AU-5 pipeline alerting and the weekly ISSO dashboard in the [control mapping](control-mapping.md).

## 2026-07-14
* **Initialization**: Established the documentation set — [control mapping](control-mapping.md), [event catalog](event-catalog.md), [retention policy](retention-policy.md), [AWS ingestion](aws-ingestion.md), and [host and Kubernetes ingestion](host-ingestion.md).
