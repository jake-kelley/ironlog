# ironlog-clickhouse

Contract: `images/README.md`. Build context is the repository root:

```
docker build -f images/clickhouse/Dockerfile -t ironlog-clickhouse .
```

Base `docker.io/clickhouse/clickhouse-server:26.8.34.13` (`ARG CLICKHOUSE_IMAGE`).
Baked in: `clickhouse/config.d/10-query-log.xml`, `clickhouse/users.d/00-lockdown.xml`
(built-in `default` user loopback-only; upstream also removes it once
`CLICKHOUSE_USER` is set), `clickhouse/ddl/` at `/ddl`, and the image-only
`05-listen.xml` (`listen_host` from `IRONLOG_CLICKHOUSE_LISTEN`, default `0.0.0.0`;
umask 007 so volumes stay usable across UIDs with GID 0; stdout logging at
`information`). Upstream's `docker_related_config.xml` (listens on `::`) is removed.

## Environment

All variables are in `images/README.md`. In server mode the image exits 64 unless
`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CH_VECTOR_PASSWORD`,
`CH_GRAFANA_ANALYST_PASSWORD` and `CH_GRAFANA_AUDITOR_PASSWORD` are set.
`IRONLOG_S3_TIER=on` needs `IRONLOG_S3_ENDPOINT` (exit 64 otherwise). Extra, for
`ironlog-schema` only: `IRONLOG_CLICKHOUSE_HOST` (default `localhost`),
`IRONLOG_CLICKHOUSE_NATIVE_PORT` (`9000`), `IRONLOG_SCHEMA_WAIT_SECONDS` (`120`).

## Health and readiness

```
/usr/local/bin/ironlog-healthcheck      # clickhouse-client --query "SELECT 1" as the admin user
```

Baked as `HEALTHCHECK`; use it as exec probe / ECS `healthCheck.command` / Quadlet
`HealthCmd`. Health says nothing about the schema. Readiness for dependants is a
successful `ironlog-schema` run: the server container logs
`[ironlog-schema] SIEM schema, TTLs and service accounts verified`, and a separate
one-shot works too:

```
docker run --rm -e CLICKHOUSE_USER=... -e CLICKHOUSE_PASSWORD=... -e CH_VECTOR_PASSWORD=... \
  -e CH_GRAFANA_ANALYST_PASSWORD=... -e CH_GRAFANA_AUDITOR_PASSWORD=... \
  -e IRONLOG_CLICKHOUSE_HOST=clickhouse ironlog-clickhouse ironlog-schema
```

Any command not starting with `--` bypasses the server start-up logic.

## ironlog-schema

Idempotent; runs in the background on every server start (retried 5 x 10 s, then
a `FATAL` log line; the server keeps running) and on demand. Steps: wait for the
server; apply `/ddl/*.sql`; text-index materialize/drop (as `clickhouse/initdb/99-init.sh`);
create the three service accounts; apply tier and TTL; verify (7 `siem` tables,
`audit.query_archive`, 3 accounts, TTL and storage policy of every `siem` table);
exit 1 on any mismatch.

- **Retention** applies to the seven `siem.*` tables only. Tier off:
  `TTL event_time + INTERVAL <RETENTION> DAY DELETE` (default 30 = the DDL). Tier on:
  `TTL event_time + INTERVAL <HOT> DAY TO VOLUME 's3', event_time + INTERVAL <RETENTION> DAY DELETE`
  (defaults 30 / 400; `RETENTION` must exceed `HOT`). `MODIFY TTL` runs only when the
  table's current TTL differs, because it re-materializes TTL on existing parts.
  The 7-day column TTL on `raw` is untouched.
- **`audit.query_archive` keeps its own 2-year TTL** (`ddl/030_audit.sql`,
  `docs/retention-policy.md`: analyst-activity trail, a separate AU-9 obligation).
  `IRONLOG_RETENTION_DAYS` does not change it, and it is never tiered.
- **Switching existing tables to S3**: `ALTER TABLE ... MODIFY SETTING storage_policy`
  is accepted only if the new policy contains all disks/volumes of the old one.
  The generated policy `hot_to_s3` names its local volume `default` (disk `default`),
  matching the built-in `default` policy, so the switch is accepted on populated
  tables (tested). Switching **back** (tier off) is not supported and untested: tables keep
  `hot_to_s3`, and verification fails with a message saying so.
- The tier config is generated at start into `/etc/clickhouse-server/config.d/20-storage-s3.xml`
  (mode 664, group 0) with `from_env` references, so secrets are never written
  to disk or logs. Unset keys give `use_environment_credentials`. The disk metadata
  lives in `/var/lib/clickhouse/disks/s3_cold/`.
- Inside the container `ironlog-schema` connects to `localhost`; do not set
  `IRONLOG_CLICKHOUSE_LISTEN` to a single non-loopback address.

## Runtime

Runs as uid 10001, gid 0; `--user 1000770000:0` works on empty and reused volumes
(tested, including a volume first written by 10001).

## Test

`scripts/tests/clickhouse-image.test.sh` (run it where `docker` is the CLI, e.g.
`wsl -e bash scripts/tests/clickhouse-image.test.sh`). The tier test uses
`docker.io/chrislusf/seaweedfs:4.52` (override with `S3_IMAGE`) because
`docker.io/minio/minio` is no longer published on Docker Hub.
