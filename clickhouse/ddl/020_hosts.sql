-- Message search index (all three tables below) --------------------------------
-- `idx_msg_text` is a GA text (inverted) index (ClickHouse >= 26.2) that
-- replaced the old `idx_msg ... TYPE tokenbf_v1(8192, 3, 0)` Bloom-filter skip
-- index. Query it with hasToken / hasAllTokens / hasAnyTokens, e.g.
--   WHERE hasAllTokens(message, 'failed password')   -- case-insensitive
-- The text index is the primary evaluation path for those functions (exact,
-- no false positives); substring tests (LIKE '%x%', positionCaseInsensitive)
-- are NOT accelerated by it (nor were they by tokenbf_v1).
--   * tokenizer = splitByNonAlpha: splits on ASCII non-alphanumerics, which is
--     how journald / auditd / Windows event / container log text is naturally
--     delimited (words, IPs -> '10','0','0','1', paths, key=value). It is the
--     tokenizer the ClickHouse docs and the FTS GA post use for log search.
--     Rejected: ngrams/sparseGrams (substring search, but a far larger index
--     and nobody queries by substring through an index today); array (whole
--     message as one token); asciiCJK/icu (only needed for CJK text).
--   * preprocessor = lower(message): case-insensitive match; hasAllTokens
--     lower-cases the needle with the same expression. lower() is ASCII-only;
--     switch to lowerUTF8 if non-ASCII log text matters (needs a re-index).
--   * The Bloom filter is DROPPED, not kept alongside: both serve the same
--     token predicates, the text index is exact and (per the GA post) faster
--     at query time at the cost of a larger index, so keeping both only adds
--     insert cost and disk. Existing installs: 025_migrate_text_index.sql adds
--     the new index; initdb/99-init.sh then materializes it and drops idx_msg.
--   * posting_list_codec is deliberately NOT set. On 26.8 the server default
--     is 'none' and 'pfor' is rejected (BAD_ARGUMENTS); 'pfor' exists from
--     26.10 and becomes the default in a later release, after which new parts
--     are unreadable by older servers. When bumping past 26.10, decide then
--     whether to pin posting_list_codec (index arg or the
--     text_index_posting_list_codec MergeTree setting) before any rollback is
--     needed. `compatibility` is not used: text indexes ignore it and it would
--     also revert unrelated defaults.

-- Windows Event Log ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS siem.windows_events
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),
    ingest_time     DateTime DEFAULT now() CODEC(Delta, ZSTD(1)),
    computer        LowCardinality(String),
    channel         LowCardinality(String),           -- Security / System / Microsoft-Windows-PowerShell/Operational
    provider        LowCardinality(String),
    event_id        UInt16,
    level           LowCardinality(String),           -- Information / Warning / Error / Critical / Audit Success / Audit Failure
    task            LowCardinality(String),
    user_sid        String CODEC(ZSTD(3)),
    user_name       String CODEC(ZSTD(3)),
    logon_type      UInt8 DEFAULT 0,                  -- populated for 4624/4625; 0 = n/a
    src_ip          String CODEC(ZSTD(3)),            -- Windows reports '-' or hostnames; kept as string
    process_name    String CODEC(ZSTD(3)),
    message         String CODEC(ZSTD(3)),
    raw             String CODEC(ZSTD(6)) TTL event_time + INTERVAL 7 DAY,  -- full EventData XML/JSON
    INDEX idx_user user_name TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_msg_text message TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(message))  -- see "Message search index" above
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (channel, computer, event_id, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;

-- Linux (journald + auditd) ---------------------------------------------------
CREATE TABLE IF NOT EXISTS siem.linux_syslog
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),
    ingest_time     DateTime DEFAULT now() CODEC(Delta, ZSTD(1)),
    host            LowCardinality(String),
    source          LowCardinality(String),           -- journald / auditd
    unit            LowCardinality(String),           -- systemd unit, e.g. sshd.service
    identifier      LowCardinality(String),           -- SYSLOG_IDENTIFIER, e.g. sudo, sshd
    priority        UInt8,                            -- 0=emerg .. 7=debug
    pid             UInt32 CODEC(T64, ZSTD(1)),
    uid             UInt32 CODEC(T64, ZSTD(1)),
    user_name       String CODEC(ZSTD(3)),
    audit_type      LowCardinality(String),           -- auditd record type (SYSCALL, USER_AUTH, ...) or ''
    message         String CODEC(ZSTD(3)),
    raw             String CODEC(ZSTD(6)) TTL event_time + INTERVAL 7 DAY,
    INDEX idx_user user_name TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_msg_text message TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(message))  -- see "Message search index" above
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (host, identifier, priority, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;

-- Kubernetes (via HEC push) ----------------------------------------------------
CREATE TABLE IF NOT EXISTS siem.k8s_logs
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),
    ingest_time     DateTime DEFAULT now() CODEC(Delta, ZSTD(1)),
    cluster         LowCardinality(String),
    namespace       LowCardinality(String),
    node            LowCardinality(String),
    container       LowCardinality(String),
    pod             String CODEC(ZSTD(1)),            -- high cardinality (hash suffixes): plain String
    level           LowCardinality(String),
    message         String CODEC(ZSTD(3)),
    raw             String CODEC(ZSTD(6)) TTL event_time + INTERVAL 7 DAY,
    INDEX idx_pod pod TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_msg_text message TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(message))  -- see "Message search index" above
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (cluster, namespace, container, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;
