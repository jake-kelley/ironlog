# CLAUDE.md — self-hosted SIEM project

## Current auth decision — 2026-09-14

The local Grafana account is the current default (Grafana is the only UI). Keycloak IdP
integration is paused; future integration uses an existing external Keycloak.
Never deploy an on-box Keycloak or its Postgres. Generic development logins
and upgrade behavior are documented in docs/local-auth.md. Historical SSO,
MFA, service lists and login instructions below describe earlier deployments
and are not the current contract. Database RBAC remains unchanged.

## Current build and deployment contract

Ironlog ships as three portable images built from `images/` (contract:
images/README.md): `ghcr.io/jake-kelley/ironlog-clickhouse:26.8.34.13`
(ClickHouse LTS; also runs the one-shot `ironlog-schema`),
`ironlog-grafana:13.3.0` (`grafana/grafana`, ClickHouse plugin pinned to 4.23.4
in `scripts/ami/grafana-clickhouse-plugin.version`) and `ironlog-vector:0.61.0`
(`IRONLOG_VECTOR_ROLE=hosts` or `aws`). amd64 and arm64. Configuration is baked
in: no config bind mounts; runtime input is environment variables plus one data
path. Images must start under an arbitrary UID with GID 0. Grafana is the only
UI and authenticates local users itself; oauth2-proxy, Keycloak and Postgres
are not deployed. Free-text search is the `siem.log_search` view
(`clickhouse/ddl/050_search.sql`) behind the Grafana "Log Search" dashboard,
backed by `idx_msg_text` text indexes (`hasAllTokens`/`hasAnyTokens`).

- Deployment targets: Quadlets on Oracle Linux 9 podman (quadlets/, verified
  live 2026-11-04 single host, split host and S3 cold tier), Compose for
  development (builds `:local` images), Helm chart in deploy/helm/ironlog
  (CI on kind). Amazon ECS on EC2 is planned (wave 2; deploy/ecs/ does not
  exist yet). Keep image tags in Quadlets and Helm values equal to the
  published GHCR tags.
- CI: .github/workflows/images.yml (build, image tests, GHCR publish with SBOM
  attestation and Grype on main), helm.yml (lint, kubeconform, kind install),
  sbom.yml (SBOM, weekly Grype, Pages report).
- Legacy EC2 AMI appliance (packer/, scripts/ami/, scripts/firstboot/,
  scripts/build-ami.sh): RHEL 9 shipping / Rocky 9 development, superseded by
  the images; whether to retire it is an open operator decision.
- Operator explicitly requested no bundle checksums or bucket ownership
  checks. Do not add SHA256SUMS, archive hash arguments, STS identity calls,
  or expected-bucket-owner enforcement. RPM signature checks remain enabled.

## Validation and remaining work

Image tests: scripts/tests/{clickhouse,grafana,vector}-image.test.sh; live
Quadlet test: scripts/tests/ol9-quadlet-e2e.sh. Do not assume any endpoint,
VM or local agent from historical notes remains live. External OIDC is
paused. Consult current DDL and docs/retention-policy.md before changing
retention.

Run `python scripts/okf-validate.py docs` after doc edits. For legacy AMI
changes, use scripts/tests/build-ami.test.sh,
scripts/tests/offline-software-source.test.sh and
scripts/tests/prepare-artifacts.test.py.

## Development host

Use a Bash shell for shell scripts. Podman with a Compose provider is the
default local runtime; Docker Compose v2 remains selectable through
`IRONLOG_CONTAINER_RUNTIME=docker`. Bootstrap saves the selection in `.env`;
use `scripts/compose.sh` for later stack operations. Engine switching does
not migrate volumes. Keep Docker-specific historical notes scoped to their
original deployment. No Keycloak hosts-file entry is required. Verify installed
tools and running services rather than relying on historical host notes.

## Historical implementation notes — superseded where noted
A license-free SIEM replacing paid products: ClickHouse (storage + SQL + RBAC),
Grafana OSS (dashboards/alerts, OIDC login), Keycloak (SSO + mandatory TOTP MFA),
Vector (all log collection). Primary mission: NIST 800-53 audit evidence
(AU family especially). Everything must stay on free/open licenses — the project
exists because OpenObserve gated SSO/RBAC/audit-trail and >50 GB/day behind a
paid license. Never introduce a component with usage caps or license keys.

## Current state
Phase 1 is DEPLOYED and host-side verified (2026-07-14) via Docker CE inside WSL
Ubuntu (no Docker Desktop — see Host environment). All RBAC + audit-trail exit
criteria pass; the SSO/MFA browser login is the only step needing the operator
(requires the Windows hosts entry, which needs admin).
- docker-compose.yml: clickhouse, keycloak(+postgres), grafana. Vector stub commented out (Phase 2).
- clickhouse/ddl/: 7 source tables + audit.query_archive + roles. Auto-applied by initdb on first start.
- bootstrap.sh: one-command setup (generates .env, compose up, rotates Keycloak
  grafana client secret via kcadm, creates first admin user, verifies RBAC).
- docs/: retention-policy.md (AU-11), event-catalog.md (AU-2), control-mapping.md.
- README.md: Phase 1 runbook + exit criteria checklist.

Bugs fixed during first deploy (all committed to the artifacts):
- compose: users.d was mounted read-only over the whole dir, which blocked the
  ClickHouse entrypoint from writing default-user.xml (crash loop). Now mounts
  the single 00-lockdown.xml file so the dir stays writable.
- config.d/10-query-log.xml: base config.xml ships an uncommented <partition_by>;
  a full <engine> string can't coexist with it. Node now uses replace="replace".
- ddl/030_audit.sql: the AU-9 archive was a refreshable MV (REFRESH ... APPEND),
  which ClickHouse 24.8 (the version then) can't parse and which is experimental. Rewritten as a standard
  INCREMENTAL MV (system.query_log -> audit.query_archive), continuous not hourly.
  Also added `SYSTEM FLUSH LOGS` before the MV (query_log doesn't exist yet at
  initdb time) and fixed the source column `client_address` -> `address`.
- grafana/provisioning/: added empty dashboards/ alerting/ plugins/ dirs (.gitkeep)
  to silence Grafana's startup "no such file" provisioning errors.
- Known minor: the MV stores interface as '1'/'2' (toString of the UInt8 enum),
  not 'TCP'/'HTTP'. Cosmetic; map to names later if auditors want readability.
- config.d/05-listen.xml: the stock image listens on loopback ONLY, so Grafana
  and Vector could never reach ClickHouse over the compose network (and the
  published 127.0.0.1 host ports were dead). Now listens on 0.0.0.0 ('::'
  crashes: compose network has no IPv6). Found+fixed at Phase 2 start.

Phase 2 state (2026-07-14): SIEM side COMPLETE and tested; AWS side pending
operator (needs real AWS account wiring — docs/aws-ingestion.md is the runbook).
- vector/vector.yaml: 4 aws_s3+SQS sources -> VRL -> clickhouse sinks
  (svc_vector, disk buffers, unix-epoch timestamps). `vector validate` clean;
  8/8 unit tests pass (vector/tests.yaml); every sink's exact JSONEachRow shape
  insert-tested against live tables AS svc_vector over HTTP.
- vector service in compose behind the "aws" profile (image pinned
  timberio/vector, now 0.61.0-debian): stack stays green until COMPOSE_PROFILES=aws.
- siem.vpc_flow action enum gained 'NONE'=0 (NODATA/SKIPDATA rows have no
  action) — DDL + live table both updated.
- Grafana: provisioned dashboard "AWS Security Overview" (console logins,
  AccessDenied trend, root activity, IAM writes) in SIEM folder;
  provider grafana/provisioning/dashboards/dashboards.yml (UI edits disabled).

Phase 3 state (2026-07-14): DEPLOYED and E2E-verified locally, INCLUDING two
real producers now live:
- The WSL Ubuntu host itself runs the Linux agent (vector .deb, 0.57.0 when installed,
  /etc/vector/vector.yaml from vector/agent-linux.yaml, drop-in
  /etc/systemd/system/vector.service.d/siem.conf: aggregator localhost:6000,
  interpolation flag, User=root). Journald flows (host 'jdesktop'); WSL kernel
  has no audit subsystem so the auditd tail idles harmlessly. NB: WSL agent
  only ships while the WSL VM is up.
- A single-node k3s demo cluster (compose profile "k3s", rancher/k3s
  now v1.37.1-k3s1, manifest auto-applied) ships pod logs via the
  k8s/vector-shipper.yaml DaemonSet -> HEC :8088. Bring-up:
  k8s/k3s-demo-up.sh (creates HEC secret + patches SIEM_ENDPOINT to the
  aggregator container IP — pods in in-docker k3s can't resolve docker DNS
  names; k3s swaps loopback resolvers for a public one).
- GOTCHA: Vector expands dollar-brace env refs EVEN IN CONFIG COMMENTS
  (pre-parse text substitution) — a comment mentioning one kills config load
  with "Missing environment variable".
Real fleet hosts/clusters onboard per docs/host-ingestion.md.
- vector-hosts service (always on, separate from the aws-profile vector):
  vector/hosts.yaml — splunk_hec :8088 (K8s, SPLUNK_HEC_TOKEN) + vector :6000
  (Linux agents) -> siem.k8s_logs / siem.linux_syslog. 5/5 unit tests
  (tests-hosts.yaml); E2E verified through the real ports: HEC valid-token ->
  row, bad-token -> 401, fake agent (journald + auditd shapes) -> rows.
- vector/agent-linux.yaml: drop-in agent config for Linux hosts (journald +
  auditd file tail, tag-and-forward; normalization lives on the aggregator).
- GOTCHA (cost us a debug cycle): Vector >=0.57 DISABLES ${VAR} config
  interpolation by default. Both vector services set
  VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true in compose; agent
  installs need it too (documented in host-ingestion.md).
- Vector's clickhouse-sink healthcheck probes WITHOUT auth -> our lockdown
  403s it. Sink healthchecks are disabled in both vector configs (inserts are
  authenticated and fine); container healthcheck + Phase 5 AU-5 alerts cover it.

Phase 4 state (2026-07-15): DEPLOYED and E2E-verified on THIS machine (pilot
host for the idle-freeze watch).
- Aggregator: agent_route routes .source=="wineventlog" -> windows_map ->
  siem.windows_events (field names taken from a live 0.57.0 windows_event_log (historical)
  sample; 8/8 unit tests). Linux and Windows agents share :6000.
- This machine runs the "vector" Windows service (LocalSystem, reads
  Security/System/PowerShell-Operational; installed by
  scripts/install-windows-agent.ps1). Verified: a deliberately triggered 4625
  landed with logon_type/user extraction intact.
- CRITICAL WSL QUIRK: Windows SERVICES cannot use the WSL2 localhost relay
  (interactive sessions only) — agent buffered silently until repointed at the
  WSL NAT IP. scripts/fix-windows-agent-addr.ps1 -Register installed a SYSTEM
  boot task that re-resolves the WSL IP, fixes the env var, restarts the
  service — and thereby auto-starts WSL+docker+stack at boot.
- PowerShell script-block logging is enabled on this host -> PowerShell/
  Operational is the highest-volume Windows channel here.
- Idle-freeze bug 25194 watch: symptom = max(event_time) stale while service
  Running; remedy = Restart-Service vector (agent disk buffer prevents loss).
- Windows scripts must stay PURE ASCII: an em dash in a .ps1 string broke
  PowerShell 5.1 parsing (BOM-less UTF-8 read as ANSI turns the dash into a
  smart quote).

## Conventions (do not violate)
- Schema density rules: ORDER BY low-cardinality-first + timestamp last;
  CODEC(Delta,ZSTD) timestamps, T64 counters, ZSTD text; LowCardinality for
  <10k distinct values; `raw` JSON column carries 7-day column TTL (the
  authoritative raw copy goes to the S3 Object Lock bucket in Phase 5); VPC Flow
  has no raw column at all.
- Hot retention 30 days (TTL DELETE); Phase 5 switches to TO VOLUME 's3' tiering.
  Any retention change must update docs/retention-policy.md AND the DDL together.
- New event types must be added to docs/event-catalog.md before VRL implements them.
- Every new artifact gets a row in docs/control-mapping.md.
- Ingest writes only as svc_vector (INSERT-only). Analysts never get write access.
- Windows agents: Vector >=0.55 native windows_event_log source, but it has a
  known idle-freeze bug (github.com/vectordotdev/vector/issues/25194) — pilot
  first; fallback is Winlogbeat OSS to the aggregator.

## Phase plan (summary)
P2 AWS via SQS/S3 -> P3 K8s (splunk_hec source on aggregator, port 8088) +
Linux agents (journald+auditd) -> P4 Windows agents -> P5 S3 tiering, Object
Lock raw archive (Parquet via aws_s3 sink), query_archive export, AU-5 pipeline
alerts -> P6 detection SQL + alert rules per control family -> P7 ops cadence.
