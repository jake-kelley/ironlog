-- Analyst-activity audit trail (who searched what) -----------------------------
-- system.query_log is rotated by the server; this archives a durable subset
-- continuously (via an incremental MV) into an append-only table. In Phase 5
-- this table also gets exported to the S3 Object Lock bucket for immutability (AU-9).

CREATE TABLE IF NOT EXISTS audit.query_archive
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),
    query_id        String CODEC(ZSTD(1)),
    user            LowCardinality(String),
    client_address  String CODEC(ZSTD(1)),
    interface       LowCardinality(String),           -- HTTP / TCP
    query_kind      LowCardinality(String),           -- Select / Insert / ...
    databases       Array(LowCardinality(String)),
    tables          Array(String),
    query           String CODEC(ZSTD(3)),
    read_rows       UInt64 CODEC(T64, ZSTD(1)),
    result_rows     UInt64 CODEC(T64, ZSTD(1)),
    duration_ms     UInt64 CODEC(T64, ZSTD(1)),
    exception       String CODEC(ZSTD(3))
)
ENGINE = ReplacingMergeTree              -- dedupes on query_id if the refresh window overlaps
PARTITION BY toYYYYMM(event_time)
ORDER BY (user, event_time, query_id)
TTL event_time + INTERVAL 2 YEAR DELETE; -- align with docs/retention-policy.md

-- On a fresh server system.query_log is created lazily (first log flush), so it
-- does not exist yet during initdb. Force it into existence before the MV
-- references it, otherwise CREATE ... FROM system.query_log fails (UNKNOWN_TABLE).
SYSTEM FLUSH LOGS;

-- Incremental materialized view: every flush of system.query_log (~7.5s)
-- appends newly-finished queries into the durable archive in near-real-time.
-- Chosen over a refreshable MV so the audit trail rests on a stable, non-
-- experimental feature (REFRESH ... APPEND requires a newer ClickHouse and the
-- experimental refreshable-MV flag). The MV's own target inserts are NOT re-
-- logged by system.query_log, so there is no self-referential growth.
CREATE MATERIALIZED VIEW IF NOT EXISTS audit.query_archive_mv
TO audit.query_archive AS
SELECT
    event_time,
    query_id,
    user,
    toString(address)                 AS client_address,   -- system.query_log column is 'address'
    toString(interface)               AS interface,
    query_kind,
    arrayMap(x -> toString(x), databases) AS databases,
    arrayMap(x -> toString(x), tables)    AS tables,
    query,
    read_rows,
    result_rows,
    query_duration_ms                 AS duration_ms,
    exception
FROM system.query_log
WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing')
  AND user NOT IN ('');
