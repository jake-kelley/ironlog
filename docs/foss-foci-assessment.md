---
type: Assessment
title: Ironlog FOSS and FOCI assessment
description: Evidence-based license and foreign ownership/control review with explicit exceptions and incomplete release coverage.
tags: [supply-chain, licenses, foss, foci, sbom]
timestamp: 2026-11-03T00:00:00Z
---

# Ironlog FOSS and FOCI assessment

**Disposition: every runtime component's primary license is OSI-approved
(Apache-2.0, AGPL-3.0-only, MPL-2.0). Artifact-level license review remains incomplete.
FOCI assurance is not established.** Intended deployment is **owner-operated, not SaaS**.
Ironlog is treated as a deployment/configuration bundle, not a separate
software product requiring an entry in this BOM. Inventory covers its
constituent software. No supplier is formally disqualified by this review.

Reviewed current files at Git HEAD `a568b2007242b980df52cbe8d2765e3d855e083e`
(2026-11-03). This is a public-evidence
assessment, not a supplier attestation, government FOCI determination,
legal approval, security authorization or audit of a running appliance.

Deliverables: [BOM](bom.md), [CSV](../sbom/ironlog-bom.csv),
[declared CycloneDX SBOM](../sbom/ironlog.cdx.json), and
[package-level image SBOM bundle](../sbom/README.md).

## Licensing findings

FOSS describes freedoms to use, study, modify and redistribute software;
it does not mean hosting/support costs zero. The Open Source Initiative
(OSI) maintains [criteria and approved licenses](https://opensource.org/licenses).
Primary upstream licenses do not establish
all unmeasured dependency licenses. Receiving organizations may apply their own criteria.
RHEL subscriptions supply support/maintenance entitlements; see [Red Hat subscription guide](https://www.redhat.com/en/resources/red-hat-enterprise-linux-subscription-guide).

| Component | Primary upstream license | License review disposition |
|---|---|---|
| ClickHouse Server 26.8.34.13 LTS | Apache-2.0 | FOSS primary project; bundled dependencies still require review. [Versioned license](https://github.com/ClickHouse/ClickHouse/blob/v26.8.34.13-lts/LICENSE). |
| Vector 0.61.0 | MPL-2.0 | FOSS, file-level copyleft obligations. [Versioned license](https://github.com/vectordotdev/vector/blob/v0.61.0/LICENSE). |
| Grafana 13.3.0 (`grafana/grafana`) | AGPL-3.0-only by default, with Apache-2.0 directories | FOSS; preserve notices and meet applicable source/distribution/network-use obligations. AGPL does not automatically license independent services in other containers. [Versioned licensing](https://github.com/grafana/grafana/blob/v13.3.0/LICENSING.md). |
| Grafana ClickHouse datasource 4.23.4 | Apache-2.0 | FOSS; version pinned, plugin backend not scanned. [Versioned license](https://github.com/grafana/clickhouse-datasource/blob/v4.23.4/LICENSE). |
| RHEL 9 / Rocky 9 host | Multiple package licenses | Exact AMI/RPM/firmware licenses unmeasured. RHEL subscription and redistribution terms separate from package-level FOSS. Rocky is development alternative, not replacement shipping decision. |
| Packer build tool | Installed version unknown; `>= 1.9.0` permits BUSL releases | **Build-chain exception/unresolved** if FOSS-only applies to tools. Current BUSL releases are not FOSS before change date. Not an appliance runtime service. [Packer 1.16.0 license](https://github.com/hashicorp/packer/blob/v1.16.0/LICENSE). |

## FOCI findings

FOCI means **Foreign Ownership, Control, or Influence**. Under DCSA's
framework, review concerns foreign interests' direct or indirect power over
company management/operations and resulting classified-contract risks.
Nationality of contributors or historical project origin alone is not a
formal determination. FOCI concerns and mitigation are entity- and
contract-specific; a public software license does not resolve them.
[DCSA explanation](https://www.dcsa.mil/FOCI/When/),
[DCSA mitigation process](https://www.dcsa.mil/mc/isd/foci/cimp/).

| Supplier/component | Public evidence | Disposition |
|---|---|---|
| ClickHouse | ClickHouse's January 16, 2026 financing announcement names GIC and other investors. Nebius disclosed ClickHouse equity ownership in May 2025 and identifies Amsterdam headquarters. | **Foreign-investment review required**. Historical disclosures do not reveal current percentages, voting/control rights, access rights, mitigation or formal status. |
| Grafana Labs / datasource plugin | Grafana announced April 6, 2022 funding led by GIC and described GIC's earlier investment. | **Foreign-investment review required**. Obtain current ownership/control information; 2022 disclosure is not a current cap table. Plugin artifact ownership/provenance also needs confirmation. |
| Vector / Datadog | Datadog acquired Timber/Vector in 2021. | **Not established**. Acquisition identifies supplier, not absence of foreign beneficial ownership/influence. |
| Red Hat/IBM, OS communities, registries and build-tool suppliers | Supplier identities or project governance can be identified, but no organization-specific current FOCI attestation was supplied. | **Not established**. No blanket clearance inferred from U.S. incorporation, headquarters, public listing or FOSS license. |

GIC states it is wholly owned by the Government of Singapore. This makes
the disclosed investments a concrete foreign-interest review item. It is
**not evidence by itself of prohibited control, malicious software,
sanctions, unmitigated FOCI or supplier ineligibility**.
[GIC ownership](https://www.gic.com.sg/who-we-are/faqs/)

Ownership evidence:

- [ClickHouse Series D, January 2026](https://clickhouse.com/blog/clickhouse-raises-400-million-series-d-acquires-langfuse-launches-postgres)
- [Nebius equity disclosure, May 2025](https://nebius.com/newsroom/nebius-participates-in-clickhouse-series-c-crystallizes-value-of-asset-to-fund-hypergrowth-of-core-ai-infrastructure-business)
- [Grafana GIC investment disclosure](https://grafana.com/press/2022/04/06/grafana-labs-announces-240-million-investment-round-led-by-gic-and-welcomes-new-investor-j-p--morgan/)
- [Datadog acquisition of Timber/Vector](https://vector.dev/blog/datadog-acquisition/)

Red Hat ownership evidence: [IBM acquisition completion](https://www.ibm.com/investor/news/ibm-completes-acquisition-of-red-hat).
U.S. parent ownership is useful evidence, not a FOCI certificate.

## What the SBOM establishes

All three currently referenced ARM64 runtime images were scanned with Syft
1.56.0 on 2026-11-03 and identified by manifest digest: ClickHouse, Grafana
and Vector. Result: **2,074 detected package occurrences** (ClickHouse 111,
Grafana 1,878, Vector 85), **8,406 file-evidence components** and **three
operating-system records**: **10,483 CycloneDX components**. Counts are not
deduplicated across images and are not license approvals. File-evidence
counts are not comparable with the 2026-11-02 run, which recorded far fewer
file components per image.

Grafana's count is mostly Go modules (1,846) compiled into the binary.
Exact shipping RHEL AMI, host RPMs and the pinned Grafana plugin artifact
were not scanned. Scanner license fields are incomplete and sometimes
opaque hashes. Release SBOM therefore remains **incomplete** despite full
current runtime-image scan coverage. No old AMI is claimed current,
scanned, running or retained.

Current public-image snapshot is not proof of packages shipped in a previous
AMI: major/patch tags can change. Exact scan references and timestamps are
in [scan summary](../sbom/registry-snapshot/scan-summary.json). No runtime,
cloud infrastructure, image pinning or private-artifact checks were changed.

## Closure requirements

1. Preserve required upstream notices, license texts and corresponding-source
   availability. Ironlog itself is excluded as a separate software product.
2. Resolve build-tool licensing separately if the procurement policy
   extends to build tooling.
3. Complete release-specific host, plugin and transitive package
   evidence using [SBOM instructions](../sbom/README.md); review unknown licenses.
4. Obtain current beneficial-ownership, board/voting, foreign-interest and
   access/control disclosures for relevant suppliers. Where applicable,
   use SF-328/supporting evidence and the designated security authority;
   do not infer a government determination from this review.
5. Obtain customer procurement/security disposition, including any mitigation
   or accepted exceptions. Self-hosting, egress restrictions, reviewed builds
   and controlled updates help supply-chain risk but do not erase ownership.

## Accurate response to requester

> Ironlog has a component BOM and an initial CycloneDX SBOM bundle. It is
> deployed and operated by the system owner, not offered as SaaS. The BOM
> lists constituent software, not Ironlog as a separate software product.
> Every runtime component's primary license is OSI-approved (Apache-2.0,
> AGPL-3.0-only, MPL-2.0); no SSPL software remains. Artifact-level license
> coverage remains incomplete. We cannot currently attest that the solution
> is free of FOCI concerns.
> Public disclosures identify foreign investment requiring supplier review;
> release inventory and ownership/control approval remain open.
