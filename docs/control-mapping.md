---
type: Compliance Mapping
title: NIST 800-53 control mapping
description: Maps each in-scope NIST 800-53 control to the concrete repository artifact that implements it, for auditor review.
tags: [compliance, nist-800-53, audit, controls]
timestamp: 2026-07-16T00:00:00Z
---

# NIST 800-53 control mapping

Each control maps to a concrete artifact in this repo. Auditor-facing.
Phase column shows when the evidence becomes live.

| Control | Implementation | Artifact | Phase |
|---|---|---|---|
| AU-2 Event logging | Committed event catalog | docs/event-catalog.md | 0 |
| AU-3 Content of records | Typed schemas + VRL normalization | clickhouse/ddl/*, vector/vector.yaml (+ unit tests vector/tests.yaml) | 2 |
| AU-4 Storage capacity | S3-backed tiering, capacity alerts | config.d/20-storage-s3.xml, retention-policy.md | 5 |
| AU-5 Response to failures | Source-silence alert rules per table (live sources active, AWS rules paused until go-live; NoData/Error also alert) + pipeline-health dashboard | grafana/provisioning/alerting/au5-pipeline-alerts.yaml, dashboards/json/pipeline-health.json | 5 (live) |
| AU-6 Review & analysis | Weekly ISSO evidence dashboard (all committed Windows/Linux/AWS event families, control-tagged panels); AWS overview dashboard; HyperDX search UI (reads as svc_hyperdx -> queries audited); analyst quick-start | grafana/provisioning/dashboards/json/nist-80053-weekly.json + aws-security-overview.json, docker-compose.yml (hyperdx*), docs/query-guide.md | 2+ |
| AU-7 Reduction & reporting | SQL saved searches, evidence query pack | detections/ (P6) | 6 |
| AU-8 Time stamps | NTP on agents; event_time + ingest_time on every row | clickhouse/ddl/* | 2 |
| AU-9 Protection of audit info | S3 Object Lock (compliance), write-only ingest role, read-only analyst roles, query_archive | ddl/030,040; retention-policy.md | 1/5 |
| AU-11 Retention | TTLs + S3 lifecycle | retention-policy.md, ddl TTL clauses | 5 |
| AU-12 Generation | Agents + collectors on all in-scope systems | vector/vector.yaml (AWS), vector/hosts.yaml + vector/agent-linux.yaml (Linux), k8s/vector-shipper.yaml (K8s), vector/agent-windows.yaml + scripts/install-windows-agent.ps1 (Windows), docs/aws-ingestion.md, docs/host-ingestion.md | 2–4 |
| AC-2 Account management | Native Grafana and HyperDX accounts; generic development users, not individual accountability; CH service accounts unchanged | docs/local-auth.md, bootstrap.sh, scripts/bootstrap-hyperdx-local.sh, clickhouse/initdb/99-init.sh | Local mode |
| AC-3 / AC-6 Enforcement, least privilege | CH roles/grants/profiles and native app login; shared Grafana datasources are not isolated by human role | clickhouse/ddl/040_rbac.sql, docker-compose.yml, docs/local-auth.md | Local mode |
| IA-2 MFA | Not enforced in local mode. External Keycloak integration is deferred; no IdP is bundled | docs/local-auth.md | Deferred |
| SI-4 Monitoring | GuardDuty triage, detection content | detections/ (P6) | 6 |
| CM-2 Baseline configuration | Compose stack translated 1:1 to podman systemd quadlets (appliance deployment model); baked read-only config under /opt/ironlog, persistent data on a separate bind-mounted volume under /var/lib/ironlog | quadlets/*.container, quadlets/ironlog.network, quadlets/README.md | Appliance |
| CM-7 Least functionality | ClickHouse admin ports remain loopback-only; HyperDX publishes its native login on 8081; no Keycloak/Postgres/oauth2-proxy; AWS Vector starts only when configured | quadlets/ironlog-clickhouse.container, quadlets/ironlog-hyperdx.container, quadlets/ironlog-vector.container | Appliance |
| CM-2 Baseline configuration (image build) | Packer HCL2 templates build the appliance AMI: RHEL 9 aarch64 (shipping) and Rocky 9 aarch64 (dev), one shared provisioner list, source AMIs selected by filter (not hardcoded id), disk-layout contract (root + separate /var/lib/ironlog data volume) for scripts/ami/00-partition.sh | packer/ironlog.pkr.hcl, packer/sources.pkr.hcl, packer/build.pkr.hcl, packer/variables.pkr.hcl, packer/README.md | Appliance |
| CM-6 Configuration settings (image build — STIG/FIPS wiring) | Provisioner order wires scripts/ami/30-stig.sh (STIG hardening) and scripts/ami/40-fips.sh (FIPS mode) into every AMI build; FIPS/Vector TLS incompatibility documented as an open, untested risk requiring a real-RHEL-9 boot test | packer/build.pkr.hcl, packer/README.md ("FIPS / Vector — open risk") | Appliance |
| MA-2 Controlled maintenance (offline runtime) | scripts/ami/20-container-images.sh loads or pulls the five appliance container images (arm64) and bakes the Grafana ClickHouse plugin at build time; appliance Quadlets use Pull=never | scripts/ami/20-container-images.sh, packer/build.pkr.hcl, quadlets/README.md | Appliance; live offline boot unverified |
| CM-7 Least functionality (image build — disk layout) | STIG-required separate mount points (/home, /tmp, /var, /var/log, /var/log/audit, /var/tmp) carved from the root volume via LVM with nodev/nosuid/noexec as applicable; appliance data volume mounted nodev at /var/lib/ironlog; devices identified by findmnt/exclusion, not launch-time names, fstab by UUID | scripts/ami/00-partition.sh, scripts/ami/README.md | Appliance |
| AU-9 Protection of audit information (image build) | /var/log/audit provisioned as its own LVM logical volume (mode 0700, nodev/nosuid/noexec), separate from /var/log so audit records can't be starved by general log growth | scripts/ami/00-partition.sh | Appliance |
| CM-6 Configuration settings (STIG remediation + evidence) | oscap xccdf eval --remediate against ssg-rhel9-ds.xml (stig profile), tailored via a generated XCCDF tailoring file to exclude documented container-incompatible rules (ip_forward, user namespaces), then a second evidence-only scan; reports + tailoring file shipped inside the image at /var/log/ironlog-build/ | scripts/ami/30-stig.sh, scripts/ami/README.md ("STIG vs. containers") | Appliance |
| SC-13 Cryptographic protection (FIPS) | fips-mode-setup --enable; RHEL 9 build path uses CMVP-validated modules (OpenSSL #4746/#4857, GnuTLS #4780/#4846, Kernel Crypto API #4796/#5034) — the only build path FIPS evidence may be drawn from; Rocky 9 build path explicitly logged as functional-only, uncertified | scripts/ami/40-fips.sh, scripts/ami/README.md ("FIPS") | Appliance |
| SI-2 Flaw remediation (image build) | dnf update -y applied at every AMI build, before hardening and image-pull steps | scripts/ami/10-baseline.sh | Appliance |
| IA-5 Authenticator management (secret resolution) | Resolver supports ssm://, asm://, file://, generate: and literals. Backend secrets are generated/resolved; app logins intentionally use generic development defaults unless overridden | scripts/firstboot/secret-resolver.sh, scripts/firstboot/ironlog-firstboot.sh, docs/local-auth.md | Appliance |
| SC-28 Protection of information at rest (secrets file) | /etc/ironlog/ironlog.env and /etc/ironlog/generated/*.secret written mode 0600 root:root, atomic write (temp file + rename), never logged | scripts/firstboot/ironlog-firstboot.sh, scripts/firstboot/secret-resolver.sh | Appliance |
| IA-2 / IA-8 (appliance auth mode selection) | APPLIANCE_MODE defaults to local; native accounts do not provide MFA or federated identity. oidc/ldap are deferred and rejected | scripts/firstboot/ironlog-firstboot.sh, docs/local-auth.md | Local mode; federation deferred |
| AC-3 Access enforcement (HyperDX local authentication) | HyperDX native account bootstrap verifies credentials without disabling authentication or resetting existing users | scripts/bootstrap-hyperdx-local.sh, quadlets/ironlog-hyperdx.container | Local mode |
| CM-6 Configuration settings (per-service ownership/SELinux data dirs) | /var/lib/ironlog/<service> directories created and chowned to each container image's documented runtime uid/gid before any container starts; :Z relabeling left to podman via the quadlets' own Volume= flags | scripts/firstboot/ironlog-firstboot.sh, scripts/firstboot/README.md ("Container uid/gid values") | Appliance |
| CM-6 Configuration settings (schema reconciliation) | ClickHouse SIEM schema and service accounts re-applied and verified on every boot, not once at image-init: the clickhouse image runs /docker-entrypoint-initdb.d only against an empty data dir, so a single failed boot would otherwise leave the persistent volume permanently schema-less. All DDL is CREATE ... IF NOT EXISTS, so reapplication is idempotent | scripts/firstboot/ironlog-apply-schema.sh, scripts/firstboot/ironlog-schema.service, clickhouse/ddl/*.sql, clickhouse/initdb/99-init.sh | Appliance |
| AU-5 Response to failures (audit store schema) | An incomplete audit store is treated as a boot failure rather than a warning: the reconciliation unit asserts 7 siem tables, audit.query_archive and 4 service accounts, and every service that queries ClickHouse gates on it via Requires=, so Vector/Grafana/HyperDX cannot start against a database that would silently accept no events. Gating deliberately does NOT live in the container healthcheck (SELECT 1 succeeds on an empty database, and a schema-aware healthcheck would deadlock against this unit) | scripts/firstboot/ironlog-apply-schema.sh, quadlets/ironlog-vector-hosts.container, quadlets/ironlog-vector.container, quadlets/ironlog-grafana.container, quadlets/ironlog-hyperdx.container | Appliance |

License notes:
- All components are OSI-licensed except MongoDB (HyperDX app-state only:
  users/dashboards/saved searches — no audit data). MongoDB is SSPL:
  free to self-host, no usage caps or license keys; the SSPL copyleft only
  triggers when offering MongoDB itself as a service, which we do not.
- HyperDX uses its native local accounts. A second password account is not
  MFA. External SSO is deferred and no longer claimed as an implemented control.
