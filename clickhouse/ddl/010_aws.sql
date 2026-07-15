-- Databases -------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS siem;
CREATE DATABASE IF NOT EXISTS audit;

-- Conventions used in every table (density tuning):
--   * ORDER BY: low-cardinality columns first, timestamp last -> similar rows
--     land adjacent on disk and compress far better.
--   * CODEC(Delta, ZSTD) on timestamps; T64+ZSTD on counters; ZSTD on text.
--   * LowCardinality(String) for columns with < ~10k distinct values.
--   * `raw` keeps full-fidelity JSON for recent investigations only (7-day
--     column TTL). The authoritative immutable copy lives in the S3 Object
--     Lock archive (Phase 5), so hot storage does not pay for it twice.
--   * 30-day table TTL = hot retention (Phase 0 decision; adjust in
--     docs/retention-policy.md and here together). The S3 tiering policy
--     (TTL ... TO VOLUME 's3') is added in Phase 5.

-- CloudTrail ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS siem.cloudtrail
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),
    ingest_time     DateTime DEFAULT now() CODEC(Delta, ZSTD(1)),
    aws_account     LowCardinality(String),
    aws_region      LowCardinality(String),
    event_source    LowCardinality(String),          -- e.g. iam.amazonaws.com
    event_name      LowCardinality(String),          -- e.g. ConsoleLogin
    event_category  LowCardinality(String),          -- Management / Data / Insight
    read_only       Bool,
    principal_type  LowCardinality(String),          -- IAMUser / AssumedRole / Root / AWSService
    principal_arn   String CODEC(ZSTD(3)),
    source_ip       String CODEC(ZSTD(3)),           -- may be an AWS service DNS name, not always an IP
    user_agent      String CODEC(ZSTD(3)),
    error_code      LowCardinality(String),
    error_message   String CODEC(ZSTD(3)),
    request_id      String CODEC(ZSTD(3)),
    event_id        String CODEC(ZSTD(3)),
    raw             String CODEC(ZSTD(6)) TTL event_time + INTERVAL 7 DAY,
    INDEX idx_src_ip source_ip TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_principal principal_arn TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (aws_account, event_source, event_name, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;

-- GuardDuty findings ------------------------------------------------------
CREATE TABLE IF NOT EXISTS siem.guardduty
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),   -- finding update time
    ingest_time     DateTime DEFAULT now() CODEC(Delta, ZSTD(1)),
    aws_account     LowCardinality(String),
    aws_region      LowCardinality(String),
    finding_id      String CODEC(ZSTD(3)),
    finding_type    LowCardinality(String),           -- e.g. UnauthorizedAccess:EC2/SSHBruteForce
    severity        Float32,
    resource_type   LowCardinality(String),
    resource_id     String CODEC(ZSTD(3)),
    title           String CODEC(ZSTD(3)),
    first_seen      DateTime CODEC(Delta, ZSTD(1)),
    last_seen       DateTime CODEC(Delta, ZSTD(1)),
    raw             String CODEC(ZSTD(6)) TTL event_time + INTERVAL 30 DAY,
    INDEX idx_resource resource_id TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (aws_account, finding_type, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;
-- Findings are low-volume and high-value: raw kept for the full hot window.

-- VPC Flow Logs -----------------------------------------------------------
-- The volume monster. No raw column at all: a flow record IS its fields.
CREATE TABLE IF NOT EXISTS siem.vpc_flow
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),   -- flow start
    end_time        DateTime CODEC(Delta, ZSTD(1)),
    aws_account     LowCardinality(String),
    interface_id    String CODEC(ZSTD(1)),
    src_addr        IPv6,                             -- IPv4 stored as IPv4-mapped IPv6
    dst_addr        IPv6,
    src_port        UInt16,
    dst_port        UInt16,
    protocol        UInt8,
    action          Enum8('NONE' = 0, 'ACCEPT' = 1, 'REJECT' = 2),  -- NONE: NODATA/SKIPDATA rows carry no action
    log_status      Enum8('OK' = 1, 'NODATA' = 2, 'SKIPDATA' = 3),
    packets         UInt64 CODEC(T64, ZSTD(1)),
    bytes           UInt64 CODEC(T64, ZSTD(1)),
    INDEX idx_src src_addr TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_dst dst_addr TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (aws_account, action, protocol, dst_port, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;

-- S3 server access logs ----------------------------------------------------
CREATE TABLE IF NOT EXISTS siem.s3_access
(
    event_time      DateTime CODEC(Delta, ZSTD(1)),
    ingest_time     DateTime DEFAULT now() CODEC(Delta, ZSTD(1)),
    bucket          LowCardinality(String),
    operation       LowCardinality(String),           -- REST.GET.OBJECT etc.
    requester       String CODEC(ZSTD(3)),
    object_key      String CODEC(ZSTD(3)),
    remote_ip       IPv6,
    http_status     UInt16,
    error_code      LowCardinality(String),
    bytes_sent      UInt64 CODEC(T64, ZSTD(1)),
    object_size     UInt64 CODEC(T64, ZSTD(1)),
    user_agent      String CODEC(ZSTD(3)),
    request_id      String CODEC(ZSTD(3)),
    INDEX idx_ip remote_ip TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_key object_key TYPE tokenbf_v1(4096, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (bucket, operation, http_status, event_time)
TTL event_time + INTERVAL 30 DAY DELETE;
