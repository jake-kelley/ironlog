---
type: Guide
title: Querying the SIEM
description: Analyst quick-start for interactive search in HyperDX and SQL/dashboards in Grafana over the siem.* tables.
tags: [au-6, querying, hyperdx, grafana]
timestamp: 2026-07-16T00:00:00Z
---

# Querying the SIEM — analyst quick-start (AU-6)

Two UIs, one database. **HyperDX** (http://localhost:8081) is for interactive
search and investigations — fast filtering, log tailing, drill-down. **Grafana**
(http://localhost:3000) is for SQL, dashboards, and alerting. Both read the
same `siem.*` tables, and every query either tool runs is itself recorded in
`audit.query_archive` (that's the AU-9 analyst audit trail working).

## HyperDX: search

1. Log in (Keycloak SSO first, then your HyperDX account).
2. Left sidebar -> **Search**. Top of the page has three controls that matter:
   - **Source dropdown** (top-left): pick the table — `linux_syslog`,
     `k8s_logs`, `CloudTrail`, `windows_events`, ...
   - **Search box**: Lucene-style filters (below).
   - **Time range picker** (top-right): defaults short — widen it if you see
     nothing ("Last 1 day" is a good start).
3. Click any result row to open the full event with every column.

Search syntax (Lucene-style; column names = the ClickHouse columns):

    sudo                          bare word: full-text over the message/body
    identifier:sshd               column equals value
    identifier:sudo OR identifier:su
    host:jdesktop AND priority:3
    namespace:kube-system         (k8s_logs source)
    pod:vector-shipper*           trailing wildcard
    level:stderr                  k8s: container stderr lines
    -identifier:kernel            minus = NOT
    "Failed password"             quoted phrase

There is also a SQL mode toggle in the search bar if you'd rather write a raw
WHERE clause. Saved searches (Save button) become the basis for HyperDX alerts.

Try these now (real data is flowing):
- Source `linux_syslog`, search `identifier:sudo` — your own sudo activity
  from the WSL host.
- Source `k8s_logs`, search `namespace:kube-system` — k3s system pods.

## Grafana: SQL + dashboards

1. Log in via Keycloak at http://localhost:3000 (needs the `keycloak` hosts
   entry; TOTP enrolls on first login).
2. **Dashboards -> SIEM folder -> AWS Security Overview** — provisioned from
   git; populates once AWS ingestion is live.
3. For ad-hoc SQL: **Explore** (compass icon) -> datasource **SIEM (analyst)**
   -> switch the editor to **SQL Editor** mode -> paste, then Run query.

Starter queries (paste into Explore):

    -- what's flowing, by source table
    SELECT 'linux' src, count() FROM siem.linux_syslog
    UNION ALL SELECT 'k8s', count() FROM siem.k8s_logs
    UNION ALL SELECT 'windows', count() FROM siem.windows_events
    UNION ALL SELECT 'cloudtrail', count() FROM siem.cloudtrail

    -- recent auth-related activity on Linux hosts
    SELECT event_time, host, identifier, message
    FROM siem.linux_syslog
    WHERE identifier IN ('sshd', 'sudo', 'su', 'login')
    ORDER BY event_time DESC LIMIT 100

    -- noisiest systemd units in the last hour
    SELECT unit, count() c FROM siem.linux_syslog
    WHERE event_time > now() - INTERVAL 1 HOUR
    GROUP BY unit ORDER BY c DESC LIMIT 20

    -- k8s: what's writing to stderr
    SELECT event_time, namespace, pod, message
    FROM siem.k8s_logs
    WHERE level = 'stderr'
    ORDER BY event_time DESC LIMIT 100

    -- Windows: failed logons (once the Phase 4 agent is installed)
    SELECT event_time, computer, user_name, src_ip, logon_type, message
    FROM siem.windows_events
    WHERE event_id = 4625
    ORDER BY event_time DESC LIMIT 100

    -- CloudTrail: who used root (once AWS ingestion is live)
    SELECT event_time, event_name, source_ip, user_agent
    FROM siem.cloudtrail
    WHERE principal_type = 'Root'
    ORDER BY event_time DESC LIMIT 100

Notes:
- The **SIEM (analyst)** datasource reads `siem.*` only. The **SIEM (audit
  trail)** datasource (auditor account) reads `audit.query_archive` — use it
  to review who searched what:
      SELECT event_time, user, query FROM audit.query_archive
      ORDER BY event_time DESC LIMIT 50
- Time is stored UTC; Grafana renders in your browser timezone.
- Queries run under the `siem_reader` profile: SELECT-only, 8 GB / 120 s /
  20 B-rows caps per query — a runaway query cancels itself, not the server.
