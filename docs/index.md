---
okf_version: "0.1"
---

# SIEM documentation

Operations and compliance knowledge for the self-hosted SIEM.
This directory is an [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
(OKF v0.1) bundle: each file is a concept with YAML frontmatter; `log.md` records changes.

# Runbooks

* [Architecture diagrams](architecture.md) - color-coded Drawbridge concept view (technology-neutral), detailed overview, ingestion paths, and user access/query auditing; editable files and image exports.

* [RHEL 9 and private software builds](private-software-builds.md) - legacy AMI path (superseded by the portable images): approved base AMIs and software bundles from local media or S3.
* [Local app authentication](local-auth.md) - development logins, existing accounts, and deferred external Keycloak integration.
* [AWS ingestion setup](aws-ingestion.md) - S3 / SQS / IAM wiring for the four AWS log sources.
* [Host and Kubernetes ingestion](host-ingestion.md) - onboarding Linux, Windows, and Kubernetes log sources.

# Compliance

* [FOSS and FOCI assessment](foss-foci-assessment.md) · [HTML report](reports/ironlog-supply-chain-report.html) - owner-operated licensing, supplier ownership evidence, exceptions and approval gaps.
* [Bill of materials](bom.md) - declared components, infrastructure and links to CycloneDX package inventories.
* [NIST 800-53 control mapping](control-mapping.md) - control-to-artifact map for auditors.
* [Auditable event catalog (AU-2)](event-catalog.md) - the committed list of captured events.
* [Log retention policy (AU-11)](retention-policy.md) - retention tiers and the immutability model.

# Analyst

* [Querying the SIEM](query-guide.md) - how to search in Grafana (Log Search dashboard and SQL).
