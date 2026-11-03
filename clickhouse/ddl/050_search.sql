-- Unified log search view ------------------------------------------------------
-- One relation over every free-text log table so the "Log Search" dashboard
-- (grafana/provisioning/dashboards/json/log-search.json) can search them with a
-- single query. Common columns:
--   event_time  DateTime
--   source      logical log family: linux | windows | k8s | cloudtrail | guardduty
--   origin      finer detail: journald/auditd + identifier, Windows channel,
--               k8s namespace/container, CloudTrail event source, GuardDuty type
--   host        linux host | Windows computer | k8s node | AWS account id
--   user        linux user_name | Windows user_name | CloudTrail principal ARN
--               ('' where the source has no user: k8s, guardduty)
--   level       normalised to the levels Grafana's Logs panel colours:
--               critical/error/warning/info/debug (syslog 5 notice and 6 info -> info)
--   message     the text to display
--   search_text the text to MATCH against; always case-insensitive (see below)
--
-- Message search: always filter with hasAllTokens()/hasAnyTokens() on
-- `search_text`, not `message`. For linux/windows/k8s it IS the real `message`
-- column, so the predicate is pushed into each base table and uses the
-- idx_msg_text text index (see "Message search index" in 020_hosts.sql), which
-- lower-cases both sides. Outside an index hasAllTokens() is case-SENSITIVE, and
-- wrapping the column in lower() (hasAllTokens(lower(message), ...)) switches the
-- index off, so the AWS branches pre-lower-case `search_text` themselves.
-- The AWS tables have no free-text column and no text index: their `message` is
-- synthesised from the descriptive columns and token search over those two
-- branches is a (partition-pruned) scan.
-- Not included: vpc_flow and s3_access (numeric flow records / access-log rows,
-- not log text; query them directly).
--
-- Access: SQL SECURITY INVOKER means every query is authorised as the calling
-- user against the base tables, so RBAC (040_rbac.sql) stays the single source of
-- truth. CREATE OR REPLACE (not IF NOT EXISTS) so a changed definition reaches
-- existing installs, since this file is re-applied on every boot.

CREATE OR REPLACE VIEW siem.log_search
SQL SECURITY INVOKER
AS
SELECT
    event_time,
    'linux'                                            AS source,
    concat(linux_syslog.source, '/', identifier)       AS origin,   -- qualified: the 'source' alias below would shadow the column
    host,
    user_name                                          AS user,
    multiIf(priority <= 2, 'critical', priority = 3, 'error', priority = 4, 'warning',
            priority <= 6, 'info', 'debug') AS level,
    message,
    message                                            AS search_text
FROM siem.linux_syslog
UNION ALL
SELECT
    event_time,
    'windows'                                          AS source,
    channel                                            AS origin,
    computer                                           AS host,
    user_name                                          AS user,
    multiIf(level = 'Information', 'info', level = 'Audit Success', 'info',
            level = 'Audit Failure', 'warning', lower(level)) AS level,
    message,
    message                                            AS search_text
FROM siem.windows_events
UNION ALL
SELECT
    event_time,
    'k8s'                                              AS source,
    concat(namespace, '/', container)                  AS origin,
    node                                               AS host,
    ''                                                 AS user,
    lower(level)                                       AS level,
    message,
    message                                            AS search_text
FROM siem.k8s_logs
UNION ALL
SELECT
    event_time,
    'cloudtrail'                                       AS source,
    event_source                                       AS origin,
    aws_account                                        AS host,
    principal_arn                                      AS user,
    if(error_code = '', 'info', 'error')               AS level,
    concat(event_source, ' ', event_name,
           if(error_code = '', '', concat(' ', error_code, ' ', error_message))) AS message,
    lower(message)                                     AS search_text
FROM siem.cloudtrail
UNION ALL
SELECT
    event_time,
    'guardduty'                                        AS source,
    finding_type                                       AS origin,
    aws_account                                        AS host,
    ''                                                 AS user,
    multiIf(severity >= 7, 'error', severity >= 4, 'warning', 'info') AS level,
    concat(finding_type, ' ', title)                   AS message,
    lower(message)                                     AS search_text
FROM siem.guardduty;

-- Explicit grants mirror 040_rbac.sql. ClickHouse folds them into the existing
-- SELECT ON siem.* (no separate row appears in system.grants), so today they are
-- no-ops that document intent and keep the view readable if that wildcard grant
-- is ever narrowed.
GRANT SELECT ON siem.log_search TO siem_analyst;
GRANT SELECT ON siem.log_search TO siem_auditor;
