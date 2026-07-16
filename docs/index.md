---
okf_version: "0.1"
---

# SIEM documentation

Operations and compliance knowledge for the self-hosted, license-free SIEM.
This directory is an [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
(OKF v0.1) bundle: each file is a concept with YAML frontmatter; `log.md` records changes.

# Runbooks

* [AWS ingestion setup](aws-ingestion.md) - S3 / SQS / IAM wiring for the four AWS log sources.
* [Host and Kubernetes ingestion](host-ingestion.md) - onboarding Linux, Windows, and Kubernetes log sources.

# Compliance

* [NIST 800-53 control mapping](control-mapping.md) - control-to-artifact map for auditors.
* [Auditable event catalog (AU-2)](event-catalog.md) - the committed list of captured events.
* [Log retention policy (AU-11)](retention-policy.md) - retention tiers and the immutability model.

# Analyst

* [Querying the SIEM](query-guide.md) - how to search in HyperDX and Grafana.
