---
type: Inventory
title: Ironlog bill of materials
description: Declared runtime, platform, build and infrastructure materials with license and supplier-review status.
tags: [bom, sbom, supply-chain]
timestamp: 2026-11-03T00:00:00Z
---

# Ironlog bill of materials

Baseline: repository HEAD `a568b2007242b980df52cbe8d2765e3d855e083e`
(Grafana-only UI, ClickHouse 26.8, Grafana 13.3, Vector 0.61), reviewed
**2026-11-03**. Owner-operated EC2
appliance; no SaaS offering. This BOM describes configured materials, not
proof of a currently deployed or certified system.

**Runtime primary licenses: OSI-approved (Apache-2.0, AGPL-3.0-only,
MPL-2.0). Artifact
license review: incomplete. FOCI: not established.** Ironlog itself
is a deployment/configuration bundle and excluded as a separate software
product from this inventory. See
[assessment and sources](foss-foci-assessment.md) before sending a compliance
statement. Machine-readable [CSV](../sbom/ironlog-bom.csv),
[source inventory](../sbom/ironlog.inventory.json) and
[SBOM bundle](../sbom/README.md) accompany this document.

## Runtime software

| Material | Declared version/reference | Quantity/role | Primary upstream license | Supplier review |
|---|---|---|---|---|
| ClickHouse Server | `clickhouse/clickhouse-server:26.8.34.13` (LTS) | One log/query database with text indexes | Apache-2.0 | Foreign investment disclosed; review required |
| Vector | `timberio/vector:0.61.0-debian` | One host collector; second AWS collector when enabled | MPL-2.0 | Datadog; no FOCI clearance established |
| Grafana | `grafana/grafana:13.3.0` | The single UI: log search, dashboards, alerts | AGPL-3.0-only plus Apache-2.0 directories | GIC investment disclosed; review required |
| Grafana ClickHouse datasource | `grafana-clickhouse-datasource` **4.23.4**, pinned in `scripts/ami/grafana-clickhouse-plugin.version` | One plugin; preinstalled by Compose, baked or staged for the AMI | Apache-2.0 at v4.23.4 | Plugin artifact not scanned; supplier control unresolved |

All Docker Hub runtime references are fully qualified with `docker.io/` in
source. Three unique images implement four container services when AWS
collection is enabled. Grafana now ships as `grafana/grafana`; the
`grafana-oss` repository stopped publishing at 13.0.2.

Linux/Windows Vector agent binaries and the Kubernetes Vector shipper
(`timberio/vector:0.61.0-distroless-libc`) are
external collection components at Vector **0.61.0**; they are not extra
databases or copies of the appliance. Their platform-specific binaries
need separate artifact scans for a fleet-wide SBOM.

## Host and build materials

| Material | Version/status | Inclusion |
|---|---|---|
| RHEL | Major 9, ARM64; exact AMI/release/RPMs unresolved | Shipping/compliance target; package licenses and subscription/redistribution terms require review |
| Rocky Linux | Major 9, ARM64; exact AMI/RPMs unresolved | Development alternative; not co-installed with RHEL or substitute FIPS evidence |
| Podman + Quadlet | Distribution-selected version | Appliance container lifecycle via systemd; upstream Podman Apache-2.0 |
| Base OS and host packages | Versions/licenses unresolved | `kernel`, `systemd`, `bash`, `coreutils`, `rpm`, `dnf`, `cloud-init`, `curl`, plus explicit package selections below; not exhaustive |
| Packer / Amazon plugin | `>= 1.9.0` / `>= 1.3.0`; actual versions unresolved | Build host only; constraints are not lockfiles. Packer constraint admits BUSL-1.1 releases |
| AWS CLI; Python 3 or jq | Conditional; exact versions unresolved | SSM/Secrets Manager resolution, JSON parsing and artifact preparation as configured |
| Compose provider / optional Docker Engine | Operator-selected, unresolved | Connected development; not appliance runtime. Docker Desktop not required |
| k3s | `rancher/k3s:v1.37.1-k3s1`; Apache-2.0 upstream | Optional demo producer, excluded from baked appliance and current image scans |

Explicit provisioner RPM selections: `podman`, `podman-plugins`, `chrony`,
`rsync`, `lvm2`, `parted`, `policycoreutils`, `audit`, `openssl`, `file`,
`crypto-policies-scripts`, `util-linux`, `gdisk`, `openscap-scanner`, and
`scap-security-guide`. The CSV lists these separately. Transitive RPMs,
base-AMI packages, firmware and bundled crypto libraries need actual host
inventory; this list is not a complete OS SBOM.

## Infrastructure and externally supplied services

| Material | Configured quantity/specification | Status |
|---|---|---|
| EC2 compute | One ARM64 instance; instance type configurable | AWS commercial or customer-approved partition/account; no live instance asserted |
| Root EBS | One encrypted gp3, **60 GiB** default | OS/container images; 125 MiB/s declared default |
| Data EBS | One encrypted gp3, **100 GiB** default | `/var/lib/ironlog`; 3,000 IOPS / 250 MiB/s declared defaults; not sizing for 100 GB/day |
| VPC/subnet/security groups/IAM | Customer-provided/configured | External deployment prerequisites; AWS-managed internals not software components inspected here |
| S3 / SQS | Optional AWS ingestion; queues by log family | Customer services; no cloud subscription represented as FOSS software |
| KMS / SSM / Secrets Manager | Encryption and secret schemes as configured | External services, not bundled software |
| HTTPS terminator / DNS / browser | Environment-provided where needed | No terminator or external IdP bundled in current stack; identify exact products before release review |

Earlier **8 vCPU / 64 GiB plus 2 TiB** discussion was provisional planning for
100 GB/day, not implemented defaults or measured capacity. EC2/EBS/AWS service
costs and RHEL subscription charges are separate from software freedoms.

## Scope exclusions and completeness

No deployed on-box Keycloak, PostgreSQL, oauth2-proxy, ECS, AI/MCP query
component or FerretDB is included. Historical files and proposed alternatives
are not current shipped dependencies. Package-level scanning covers all three ARM64 runtime images.
Host OS, agent binaries, demo image and the datasource plugin remain outside
current scan coverage.

Scan coverage, immutable image identities, actual detected package versions
and regeneration steps: [SBOM bundle](../sbom/README.md).
