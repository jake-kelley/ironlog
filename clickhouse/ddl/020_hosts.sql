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
    INDEX idx_msg message TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 4
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
    INDEX idx_msg message TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 4
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
    INDEX idx_msg message TYPE tokenbf_v1(8192, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (cluster, namespace, container, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;
