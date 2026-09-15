# SIEM documentation update log

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
