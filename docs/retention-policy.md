# Log retention policy (AU-11, AU-4)

Status: DRAFT — confirm the two driving numbers, then keep this file and the
ClickHouse TTLs / S3 lifecycle rules in sync. This document is auditor-facing.

## Driving decisions

| Decision | Value | Rationale |
|---|---|---|
| Hot retention (ClickHouse, full query speed) | 30 days | Covers routine investigation window (AU-6) |
| Warm retention (ClickHouse S3 volume, Phase 5) | 30–400 days | Queryable, slower; cheap object storage |
| Total retention (S3 raw archive, Object Lock) | 3 years | AU-11 baseline + org obligation — CONFIRM |
| Raw-JSON column in hot tables | 7 days | Full fidelity for fresh incidents; archive holds authoritative copy |
| Analyst activity trail (audit.query_archive) | 2 years | AU-9 supporting evidence |

## Storage classes (raw archive bucket, Phase 5)

Day 0–30 S3 Standard -> Day 30–180 Standard-IA -> Day 180–365 Glacier Instant
Retrieval -> Day 365+ Glacier Deep Archive -> Delete at 3 years.
Object Lock: compliance mode, retention equal to total retention. Versioning on.

## Integrity (AU-9)

Raw events are written once by the pipeline account to an Object Lock bucket;
no principal (including root) can modify or delete them within the retention
period. ClickHouse hot data is a derived, disposable copy.
