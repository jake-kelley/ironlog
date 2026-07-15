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
| AC-2 Account management | Keycloak realm (SSO users), CH service accounts | keycloak/, initdb/99-init.sh | 1 |
| AC-3 / AC-6 Enforcement, least privilege | CH roles/grants/profiles; Grafana role mapping; oauth2-proxy gates HyperDX by siem_* realm roles | ddl/040_rbac.sql, docker-compose.yml | 1 |
| IA-2 MFA | Keycloak TOTP required action (default on); HyperDX gated behind the same realm via oauth2-proxy | keycloak/realm-export/siem-realm.json, docker-compose.yml (hyperdx-auth) | 1 |
| SI-4 Monitoring | GuardDuty triage, detection content | detections/ (P6) | 6 |

License notes:
- All components are OSI-licensed except MongoDB (HyperDX app-state only:
  users/dashboards/saved searches — no audit data). MongoDB is SSPL:
  free to self-host, no usage caps or license keys; the SSPL copyleft only
  triggers when offering MongoDB itself as a service, which we do not.
- OSS HyperDX has no native SSO (enterprise-only feature); the mandate is met
  by fronting it with oauth2-proxy (Apache-2.0) bound to the Keycloak realm.
  HyperDX local accounts exist underneath as a second factor of the app itself.
