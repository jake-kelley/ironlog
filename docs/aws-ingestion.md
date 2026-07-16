---
type: Runbook
title: AWS ingestion setup
description: AWS-side wiring (S3 event notifications to SQS and a least-privilege IAM user) that feeds CloudTrail, GuardDuty, VPC Flow, and S3 access logs into the SIEM.
tags: [aws, ingestion, cloudtrail, guardduty, runbook]
timestamp: 2026-07-16T00:00:00Z
---

# AWS ingestion setup (Phase 2)

How to wire AWS log sources into the Vector aggregator. Everything on the SIEM
side is already built (vector/vector.yaml, siem.* tables, svc_vector account);
this document is the AWS-side runbook. All events ingested here are committed
in docs/event-catalog.md (AU-2).

## Architecture

    CloudTrail / GuardDuty / VPC Flow / S3 access logs
        -> S3 bucket (per source or shared with prefixes)
        -> S3 Event Notification (s3:ObjectCreated:*)
        -> SQS queue  (ONE PER LOG FAMILY — Vector's aws_s3 source cannot
                       demux mixed object types from a single queue)
        -> vector (aws_s3 source) -> VRL normalize -> ClickHouse siem.*

## 1. Log delivery to S3

- **CloudTrail**: org/account trail, all regions, management events (+data
  events per event-catalog scope) -> its own bucket or prefix. Files arrive as
  `.json.gz` with a `Records[]` array.
- **GuardDuty**: Settings -> Findings export options -> S3. Findings arrive as
  JSONL. Export frequency 15 min (fastest).
- **VPC Flow Logs**: create flow logs (VPCs in scope, ACCEPT+REJECT) with
  destination S3, format: default v2. Files are text `.log.gz` with a header line.
- **S3 server access logs**: enable on in-scope buckets, target a dedicated
  logging bucket/prefix. Plain text, no compression.

## 2. SQS queues + notifications

Create 4 standard queues: `siem-cloudtrail`, `siem-guardduty`, `siem-vpcflow`,
`siem-s3access` (visibility timeout 300s, retention 4 days). On each log
bucket/prefix add an Event Notification for `s3:ObjectCreated:*` targeting the
matching queue. Each queue needs a policy allowing S3 to send (Condition on
`aws:SourceArn` = the bucket ARN).

## 3. IAM user for Vector (least privilege)

Create IAM user `svc-siem-vector`, programmatic access only. Policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ConsumeQueues",
      "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
      "Resource": [
        "arn:aws:sqs:REGION:ACCOUNT:siem-cloudtrail",
        "arn:aws:sqs:REGION:ACCOUNT:siem-guardduty",
        "arn:aws:sqs:REGION:ACCOUNT:siem-vpcflow",
        "arn:aws:sqs:REGION:ACCOUNT:siem-s3access"
      ]
    },
    {
      "Sid": "ReadLogObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::LOGBUCKET1/*", "arn:aws:s3:::LOGBUCKET2/*"]
    }
  ]
}
```

No write, no list, no delete on S3: Vector only fetches the objects named in
queue messages. (Object deletion/lifecycle stays an S3 lifecycle-rule concern.)

## 4. Turn it on

1. Fill the `--- Phase 2 ---` block in `.env` (region, keys, 4 queue URLs).
2. Uncomment `COMPOSE_PROFILES=aws` in `.env`.
3. `docker compose up -d` (starts the `vector` service).
4. Verify:
   - `docker logs siem-vector` — no auth/queue errors, sinks healthy.
   - Row counts rising: `SELECT count() FROM siem.cloudtrail` (as admin or analyst).
   - Grafana -> SIEM folder -> "AWS Security Overview" populates.

## Operational notes

- Vector keeps per-sink **disk buffers** (`vector-buffer` volume): SQS messages
  are only deleted after successful read; events already read survive restarts
  in the buffer. ClickHouse outages back-pressure (`when_full: block`) rather
  than drop (AU-5 groundwork; pipeline alerts land in Phase 5).
- A `NONE` value in `siem.vpc_flow.action` is a NODATA/SKIPDATA record (no
  traffic decision existed), not missing data.
- CloudTrail digest files (`/CloudTrail-Digest/`) are dropped by the transform;
  exclude the prefix from the bucket notification to avoid paying for the reads.
- Adding a new AWS source = catalog it in docs/event-catalog.md first, then a
  new SQS queue + source/transform/sink trio in vector/vector.yaml, a table in
  clickhouse/ddl/, and a row in docs/control-mapping.md.
