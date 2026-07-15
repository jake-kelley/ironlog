# CLAUDE.md — self-hosted SIEM project

## What this is
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
  which 24.8 can't parse and which is experimental. Rewritten as a standard
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
  timberio/vector:0.57.0-debian): stack stays green until COMPOSE_PROFILES=aws.
- siem.vpc_flow action enum gained 'NONE'=0 (NODATA/SKIPDATA rows have no
  action) — DDL + live table both updated.
- Grafana: provisioned dashboard "AWS Security Overview" (console logins,
  AccessDenied trend, root activity, IAM writes) in SIEM folder;
  provider grafana/provisioning/dashboards/dashboards.yml (UI edits disabled).

Phase 3 state (2026-07-14): DEPLOYED and E2E-verified locally, INCLUDING two
real producers now live:
- The WSL Ubuntu host itself runs the Linux agent (vector 0.57.0 .deb,
  /etc/vector/vector.yaml from vector/agent-linux.yaml, drop-in
  /etc/systemd/system/vector.service.d/siem.conf: aggregator localhost:6000,
  interpolation flag, User=root). Journald flows (host 'jdesktop'); WSL kernel
  has no audit subsystem so the auditd tail idles harmlessly. NB: WSL agent
  only ships while the WSL VM is up.
- A single-node k3s demo cluster (compose profile "k3s", rancher/k3s
  v1.35.6-k3s1, manifest auto-applied) ships pod logs via the
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
  siem.windows_events (field names taken from a live 0.57.0 windows_event_log
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

HyperDX added (2026-07-14), deployed and verified:
- hyperdx 2.19.0 (ClickStack, MIT) at http://localhost:8081 as the log-search /
  investigation UI over siem.*. NOT published directly — oauth2-proxy v7.15.3
  (hyperdx-auth) enforces Keycloak OIDC+MFA first (OSS HyperDX has no native
  SSO), allowed realm roles: siem_admin/analyst/auditor. Keycloak client
  "hyperdx" (in realm-export + created live; secret rotated by bootstrap.sh).
- Reads ClickHouse as svc_hyperdx (siem_analyst role + siem_reader profile,
  in initdb 99-init.sh + created live) so its queries are captured in
  audit.query_archive. Verified: reads siem.*, denied audit.*.
- App state in mongo:7.0 (hyperdx-db, auth enabled). MongoDB is SSPL (not OSI;
  free self-hosted, no caps/keys) — accepted + documented in control-mapping.
  Upstream pins EOL mongo:5.0; 7.0 verified working (connects, collections
  created).
- DEFAULT_CONNECTIONS/DEFAULT_SOURCES env provision the ClickHouse connection
  + 4 sources (CloudTrail/GuardDuty/VPC Flow/S3 Access). IMPORTANT: these seed
  only when the FIRST user registers (setupTeamDefaults on team creation), and
  malformed JSON is silently ignored (validated in-container with node).
  Operator still needs to: visit http://localhost:8081, pass Keycloak, create
  the HyperDX local account (first visit), confirm sources appear.

## Host environment
Operator is on Windows. Use Docker Desktop (WSL2 backend). Run bootstrap.sh from
a WSL Ubuntu shell (or Git Bash) in the repo directory. The `127.0.0.1 keycloak`
hosts entry goes in C:\Windows\System32\drivers\etc\hosts (admin PowerShell:
`Add-Content $env:SystemRoot\System32\drivers\etc\hosts "127.0.0.1 keycloak"`).

## Immediate tasks
1. DONE (2026-07-14): Phase 1 deployed; bootstrap green; RBAC + audit-trail exit
   criteria verified from the host. Remaining for the operator: add the Windows
   hosts entry (admin) and complete the browser SSO+MFA login to confirm the two
   login-flow exit criteria end-to-end.
2. DONE (2026-07-14) SIEM-side: Phase 2 artifacts built/tested (see Phase 2
   state above). Remaining: operator wires the AWS side per
   docs/aws-ingestion.md, fills .env, sets COMPOSE_PROFILES=aws; then watch
   `docker logs siem-vector` and confirm the dashboard populates with real data.
3. DONE (2026-07-14) SIEM-side: Phase 3 aggregator deployed + E2E-verified
   (see Phase 3 state above). Remaining: onboard real Linux hosts / K8s
   clusters per docs/host-ingestion.md.
4. DONE (2026-07-15): Phase 4 Windows agent live on this machine (see Phase 4
   state above). Keep watching for the idle-freeze symptom during the pilot.
5. DONE (2026-07-15) Phase 5 partial — AU-5 alerting live:
   grafana/provisioning/alerting/au5-pipeline-alerts.yaml (3 active source-
   silence rules for linux/windows/k8s; 4 AWS rules ship PAUSED — un-pause at
   AWS go-live; NoData/Error -> Alerting so CH-down fires). Contact point
   "siem-oncall" has a placeholder address; needs real address + GF_SMTP_* for
   delivery. Dashboards added: pipeline-health.json (AU-5 lag/rate) and
   nist-80053-weekly.json (ISSO weekly evidence — all committed Win/Linux/AWS
   event families, control IDs in panel titles, 7d window). README fully
   rewritten (architecture, onboarding matrix, security model, ops runbook,
   field-notes/troubleshooting section that indexes every gotcha).
6. Next: Phase 5 remainder (S3 tiering, Object Lock raw archive, query_archive
   export — blocked on AWS creds + retention-number confirmation; user is
   considering 5-year retention, see retention-policy.md), Phase 6 (detection
   SQL), Phase 7 (ops cadence). AWS-side wiring for Phase 2 still pending.

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
