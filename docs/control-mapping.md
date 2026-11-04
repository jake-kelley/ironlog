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
| AU-6 Review & analysis | Weekly ISSO evidence dashboard (all committed Windows/Linux/AWS event families, control-tagged panels); AWS overview dashboard; Log Search dashboard (free-text search over `siem.log_search`; Grafana's query runs as svc_grafana_analyst or svc_grafana_auditor -> queries audited in audit.query_archive); analyst quick-start | grafana/provisioning/dashboards/json/nist-80053-weekly.json + aws-security-overview.json + log-search.json, clickhouse/ddl/050_search.sql, docs/query-guide.md | 2+ |
| AU-7 Reduction & reporting | SQL saved searches, evidence query pack | detections/ (P6) | 6 |
| AU-8 Time stamps | NTP on agents; event_time + ingest_time on every row | clickhouse/ddl/* | 2 |
| AU-9 Protection of audit info | S3 Object Lock (compliance), write-only ingest role, read-only analyst roles, query_archive | ddl/030,040; retention-policy.md | 1/5 |
| AU-11 Retention | TTLs + S3 lifecycle | retention-policy.md, ddl TTL clauses | 5 |
| AU-12 Generation | Agents + collectors on all in-scope systems | vector/vector.yaml (AWS), vector/hosts.yaml + vector/agent-linux.yaml (Linux), k8s/vector-shipper.yaml (K8s), vector/agent-windows.yaml + scripts/install-windows-agent.ps1 (Windows), docs/aws-ingestion.md, docs/host-ingestion.md | 2–4 |
| AC-2 Account management | Native Grafana account (the only UI); generic development user, not individual accountability; CH service accounts svc_vector, svc_grafana_analyst, svc_grafana_auditor (svc_hyperdx removed) | docs/local-auth.md, bootstrap.sh, clickhouse/initdb/99-init.sh | Local mode |
| AC-3 / AC-6 Enforcement, least privilege | CH roles/grants/profiles and native app login; shared Grafana datasources are not isolated by human role | clickhouse/ddl/040_rbac.sql, docker-compose.yml, docs/local-auth.md | Local mode |
| IA-2 MFA | Not enforced in local mode. External Keycloak integration is deferred; no IdP is bundled | docs/local-auth.md | Deferred |
| SI-4 Monitoring | GuardDuty triage, detection content | detections/ (P6) | 6 |
| CM-2 Baseline configuration | Compose stack translated 1:1 to podman systemd quadlets (appliance deployment model); baked read-only config under /opt/ironlog, persistent data on a separate bind-mounted volume under /var/lib/ironlog | quadlets/*.container, quadlets/ironlog.network, quadlets/README.md | Appliance |
| CM-7 Least functionality | ClickHouse admin ports remain loopback-only; Grafana (3000) is the only published UI; no HyperDX/MongoDB/Keycloak/Postgres/oauth2-proxy; AWS Vector starts only when configured | quadlets/ironlog-clickhouse.container, quadlets/ironlog-grafana.container, quadlets/ironlog-vector.container | Appliance |
| CM-2 Baseline configuration (image build) | Packer HCL2 templates build the appliance AMI: RHEL 9 aarch64 (shipping) and Rocky 9 aarch64 (dev), one shared provisioner list, source AMIs selected by filter (not hardcoded id), disk-layout contract (root + separate /var/lib/ironlog data volume) for scripts/ami/00-partition.sh | packer/ironlog.pkr.hcl, packer/sources.pkr.hcl, packer/build.pkr.hcl, packer/variables.pkr.hcl, packer/README.md | Appliance |
| CM-6 Configuration settings (image build — STIG/FIPS wiring) | Provisioner order wires scripts/ami/30-stig.sh (STIG hardening) and scripts/ami/40-fips.sh (FIPS mode) into every AMI build; FIPS/Vector TLS incompatibility documented as an open, untested risk requiring a real-RHEL-9 boot test | packer/build.pkr.hcl, packer/README.md ("FIPS / Vector — open risk") | Appliance |
| MA-2 Controlled maintenance (offline runtime) | scripts/ami/20-container-images.sh loads or pulls the three appliance container images (ClickHouse 26.8.34.13, Grafana 13.3.0, Vector 0.61.0) (arm64) and bakes the Grafana ClickHouse plugin at build time; appliance Quadlets use Pull=never | scripts/ami/20-container-images.sh, packer/build.pkr.hcl, quadlets/README.md | Appliance; live offline boot unverified |
| CM-7 Least functionality (image build — disk layout) | STIG-required separate mount points (/home, /tmp, /var, /var/log, /var/log/audit, /var/tmp) carved from the root volume via LVM with nodev/nosuid/noexec as applicable; appliance data volume mounted nodev at /var/lib/ironlog; devices identified by findmnt/exclusion, not launch-time names, fstab by UUID | scripts/ami/00-partition.sh, scripts/ami/README.md | Appliance |
| CM-6 Configuration settings (container images and split-host exposure) | Compose and Quadlets run the baked ironlog images with no config bind mounts; ClickHouse HTTP/native ports stay loopback unless `IRONLOG_CLICKHOUSE_BIND` is set deliberately for split-host mode, and the exposure (plaintext, authentication-only, firewall restriction) is documented with a two-host example. One-shot `ironlog-schema` unit replaces the firstboot schema dependency | docker-compose.yml, quadlets/ironlog-schema.container, quadlets/ironlog-clickhouse.container, quadlets/README.md, images/README.md | Appliance; live Quadlet run unverified |
| AU-9 Protection of audit information (image build) | /var/log/audit provisioned as its own LVM logical volume (mode 0700, nodev/nosuid/noexec), separate from /var/log so audit records can't be starved by general log growth | scripts/ami/00-partition.sh | Appliance |
| CM-6 Configuration settings (STIG remediation + evidence) | oscap xccdf eval --remediate against ssg-rhel9-ds.xml (stig profile), tailored via a generated XCCDF tailoring file to exclude documented container-incompatible rules (ip_forward, user namespaces), then a second evidence-only scan; reports + tailoring file shipped inside the image at /var/log/ironlog-build/ | scripts/ami/30-stig.sh, scripts/ami/README.md ("STIG vs. containers") | Appliance |
| SC-13 Cryptographic protection (FIPS) | fips-mode-setup --enable; RHEL 9 build path uses CMVP-validated modules (OpenSSL #4746/#4857, GnuTLS #4780/#4846, Kernel Crypto API #4796/#5034) — the only build path FIPS evidence may be drawn from; Rocky 9 build path explicitly logged as functional-only, uncertified | scripts/ami/40-fips.sh, scripts/ami/README.md ("FIPS") | Appliance |
| SI-2 Flaw remediation (image build) | dnf update -y applied at every AMI build, before hardening and image-pull steps | scripts/ami/10-baseline.sh | Appliance |
| IA-5 Authenticator management (secret resolution) | Resolver supports ssm://, asm://, file://, generate: and literals. Backend secrets are generated/resolved; app logins intentionally use generic development defaults unless overridden | scripts/firstboot/secret-resolver.sh, scripts/firstboot/ironlog-firstboot.sh, docs/local-auth.md | Appliance |
| SC-28 Protection of information at rest (secrets file) | /etc/ironlog/ironlog.env and /etc/ironlog/generated/*.secret written mode 0600 root:root, atomic write (temp file + rename), never logged | scripts/firstboot/ironlog-firstboot.sh, scripts/firstboot/secret-resolver.sh | Appliance |
| IA-2 / IA-8 (appliance auth mode selection) | APPLIANCE_MODE defaults to local; native accounts do not provide MFA or federated identity. oidc/ldap are deferred and rejected | scripts/firstboot/ironlog-firstboot.sh, docs/local-auth.md | Local mode; federation deferred |
| AC-3 / AC-6 Access enforcement (log search) | `siem.log_search` is `SQL SECURITY INVOKER`: each query is authorised as the calling ClickHouse account against the base tables, so RBAC in 040_rbac.sql stays the only grant source; `GRANT SELECT` to siem_analyst and siem_auditor only. vpc_flow and s3_access are not in the view | clickhouse/ddl/050_search.sql, clickhouse/ddl/040_rbac.sql | Local mode |
| CM-6 Configuration settings (per-service ownership/SELinux data dirs) | /var/lib/ironlog/<service> directories created and chowned to each container image's documented runtime uid/gid before any container starts; :Z relabeling left to podman via the quadlets' own Volume= flags | scripts/firstboot/ironlog-firstboot.sh, scripts/firstboot/README.md ("Container uid/gid values") | Appliance |
| CM-6 Configuration settings (schema reconciliation) | ClickHouse SIEM schema and service accounts re-applied and verified on every boot, not once at image-init: the clickhouse image runs /docker-entrypoint-initdb.d only against an empty data dir, so a single failed boot would otherwise leave the persistent volume permanently schema-less. All DDL is CREATE ... IF NOT EXISTS, so reapplication is idempotent | scripts/firstboot/ironlog-apply-schema.sh, scripts/firstboot/ironlog-schema.service, clickhouse/ddl/*.sql, clickhouse/initdb/99-init.sh | Appliance |
| AU-5 Response to failures (audit store schema) | An incomplete audit store is treated as a boot failure rather than a warning: the reconciliation unit asserts 7 siem tables, audit.query_archive and 3 service accounts, and every service that queries ClickHouse gates on it via Requires=, so Vector/Grafana cannot start against a database that would silently accept no events. Gating deliberately does NOT live in the container healthcheck (SELECT 1 succeeds on an empty database, and a schema-aware healthcheck would deadlock against this unit) | scripts/firstboot/ironlog-apply-schema.sh, quadlets/ironlog-vector-hosts.container, quadlets/ironlog-vector.container, quadlets/ironlog-grafana.container | Appliance |

License notes:
- All components are OSI-licensed. MongoDB (SSPL) was used only for HyperDX
  app state and was removed together with HyperDX on 2026-11-03.
- Grafana uses its native local account. A second password account is not
  MFA. External SSO is deferred and no longer claimed as an implemented control.

Access-control and audit attribution:
- Grafana roles (Grafana's own login) gate dashboards. Grafana reaches
  ClickHouse through two shared datasources: `SIEM (analyst)` as
  `svc_grafana_analyst` (role `siem_analyst`) and `SIEM (audit trail)` as
  `svc_grafana_auditor` (role `siem_auditor`, also reads `audit.*`). Grafana's
  datasources are shared, so they do not separate human analyst and auditor
  access inside Grafana.
- ClickHouse `system.query_log` records the service account, not the browser
  user. `audit.query_archive` therefore attributes queries per service account
  (`svc_vector`, `svc_grafana_analyst`, `svc_grafana_auditor`, plus admin use),
  not per person. HyperDX no longer contributes query evidence.
