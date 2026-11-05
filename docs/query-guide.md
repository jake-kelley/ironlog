---
type: Guide
title: Querying the SIEM
description: Analyst quick-start for free-text search (Log Search dashboard, siem.log_search, hasAllTokens/hasAnyTokens) and SQL/dashboards in Grafana over the siem.* tables.
tags: [au-6, querying, grafana]
timestamp: 2026-11-03T00:00:00Z
---

# Querying the SIEM — analyst quick-start (AU-6)

One UI, one database. **Grafana** (`http://APPLIANCE_FQDN:3000`) is for
free-text log search, SQL, dashboards, and alerting. Replace `APPLIANCE_FQDN`
with `localhost` for connected development. Every query Grafana runs is
recorded in `audit.query_archive` under the datasource's service account
(`svc_grafana_analyst` or `svc_grafana_auditor`), not under your Grafana user.

## Log Search dashboard

1. Log in at http://localhost:3000 (see [local authentication](local-auth.md)).
2. **Dashboards -> SIEM folder -> Log Search**.
3. Set the controls at the top:
   - **Search**: words to find in the message. Matching is token-based and
     case-insensitive; leave empty to list everything in range.
   - **Mode**: `all` (every word must appear) or `any` (at least one).
   - **Source**: `linux`, `windows`, `k8s`, `cloudtrail`, `guardduty`.
   - **Host** and **User**: filter lists built from the current time range.
   - Time range picker (top-right): widen it if you see nothing.
4. Panels: *Log volume by source*, *Matching logs* (Logs panel; context
   columns `source` and `host`) and *Matching events (table)*. Each lists at
   most 200 rows, newest first.

The dashboard reads the `SIEM (analyst)` datasource. The AWS Security Overview
dashboard links to it.

## The `siem.log_search` view

One relation over every free-text log table (`clickhouse/ddl/050_search.sql`):
`linux_syslog`, `windows_events`, `k8s_logs`, `cloudtrail`, `guardduty`.
`vpc_flow` and `s3_access` are not in it; query them directly.

| Column | Meaning |
|---|---|
| `event_time` | event time |
| `source` | `linux`, `windows`, `k8s`, `cloudtrail`, `guardduty` |
| `origin` | journald/auditd + identifier, Windows channel, `namespace/container`, CloudTrail event source, GuardDuty finding type |
| `host`, `user` | host / computer / node / AWS account; user name or principal ARN (`''` for k8s and GuardDuty) |
| `level` | `critical`, `error`, `warning`, `info`, `debug` |
| `message` | text to display |
| `search_text` | text to match; always search this column, not `message` |

The view is `SQL SECURITY INVOKER`: you only see what your ClickHouse account
may read from the base tables.

## Token search: hasAllTokens / hasAnyTokens

`linux_syslog`, `windows_events` and `k8s_logs` carry a text index
`idx_msg_text` on `message` (tokenizer `splitByNonAlpha`, lower-cased on both
sides). Use `hasAllTokens` / `hasAnyTokens`; they use the index and are
case-insensitive there. `LIKE '%x%'` is not accelerated. Do not wrap the column
in `lower()`: that switches the index off.

    -- every word must appear (AND)
    SELECT event_time, host, identifier, message
    FROM siem.linux_syslog
    WHERE event_time > now() - INTERVAL 1 DAY
      AND hasAllTokens(message, 'failed password')
    ORDER BY event_time DESC LIMIT 100

    -- any word may appear (OR)
    SELECT event_time, computer, message
    FROM siem.windows_events
    WHERE event_time > now() - INTERVAL 1 DAY
      AND hasAnyTokens(message, 'denied refused')
    ORDER BY event_time DESC LIMIT 100

    -- across every source at once
    SELECT event_time, source, origin, host, user, level, message
    FROM siem.log_search
    WHERE event_time > now() - INTERVAL 1 HOUR
      AND hasAllTokens(search_text, 'sudo')
    ORDER BY event_time DESC LIMIT 100

The CloudTrail and GuardDuty branches have no text index; their `search_text`
is built from descriptive columns and lower-cased, so search them with
lower-case words (the dashboard lower-cases your input) and expect a
partition-pruned scan rather than an index lookup.

## Grafana: SQL + dashboards

1. Log in locally at http://localhost:3000. Fresh development default:
   `admin` / `IronlogDev123!`. Existing accounts retain their passwords.
2. **Dashboards -> SIEM folder** — *Log Search*, *AWS Security Overview*
   (populates once AWS ingestion is live), the weekly NIST evidence dashboard
   and pipeline health; all provisioned from git.
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
