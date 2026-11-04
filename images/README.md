# Ironlog container images: portability contract

Ironlog ships as three container images that run unchanged on podman/Docker
(Compose or Quadlets), Kubernetes, OpenShift and Amazon ECS on EC2. All
containers can share one host or be split across several. The images are the
product; every deployment target only supplies environment variables, volumes,
networking and secrets. Status: **draft, 2026-11-04**. Change this file before
changing the behavior it describes.

## Images

| Image | Dockerfile | Upstream base | Ports | Writable path |
|---|---|---|---|---|
| `ironlog-clickhouse` | `images/clickhouse/Dockerfile` | `docker.io/clickhouse/clickhouse-server:26.8.34.13` | 8123 HTTP, 9000 native | `/var/lib/clickhouse` |
| `ironlog-grafana` | `images/grafana/Dockerfile` | `docker.io/grafana/grafana:13.3.0` | 3000 | `/var/lib/grafana` |
| `ironlog-vector` | `images/vector/Dockerfile` | `docker.io/timberio/vector:0.61.0-debian` | 8088 HEC, 6000 native (hosts role); 8686 API | `/var/lib/vector` |

- Build context is the **repository root**, so Dockerfiles `COPY` from the
  existing `clickhouse/`, `grafana/` and `vector/` directories. Those stay the
  single source of truth; do not copy them under `images/`.
- Image-only helper files (entrypoints, generated-config templates) live in
  `images/<name>/`.
- Registry is a build argument; default `ghcr.io/jake-kelley`. Tags are
  `<upstream version>-<git short sha>` plus a moving `<upstream version>`.
- Platforms: `linux/amd64` and `linux/arm64`. Nothing in an image may assume
  one architecture.
- Upstream versions are pinned in exactly one place per image (a Dockerfile
  `ARG`). `sbom/ironlog.inventory.json` and `scripts/generate-sbom.py` checks
  must keep matching.

## Runtime rules (all images)

1. **No config bind mounts.** All configuration is baked in. Runtime input is
   environment variables and the one writable data path. A deployment must
   work with only those.
2. **Arbitrary UID.** Each image runs as a non-root user and must also start
   when the platform assigns a random UID with GID 0 (OpenShift
   `restricted-v2`). Writable and generated paths are group 0 with `g=u`.
   Test with `--user 1000770000:0`. No image needs root, privileged mode,
   added capabilities or host networking.
3. **Addresses come from the environment.** No service assumes it shares a
   host or network namespace with another. Defaults match the Compose service
   name `clickhouse`.
4. **Secrets** arrive as environment variables (ECS Secrets Manager, Kubernetes
   Secret, Quadlet `EnvironmentFile`). Images never print them.
5. Logs go to stdout/stderr. No log files are required.
6. Each image documents one health command, usable as a Docker
   `HEALTHCHECK`, Kubernetes probe, ECS `healthCheck` and Quadlet `HealthCmd`.
7. TLS between services is out of scope for this draft; it must be addable
   later without changing the variables below.

## Environment

### ironlog-clickhouse

| Variable | Default | Meaning |
|---|---|---|
| `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | required | Admin account (upstream image behavior) |
| `CH_VECTOR_PASSWORD` | required | `svc_vector` (ingest) |
| `CH_GRAFANA_ANALYST_PASSWORD`, `CH_GRAFANA_AUDITOR_PASSWORD` | required | Grafana read accounts |
| `IRONLOG_CLICKHOUSE_LISTEN` | `0.0.0.0` | `listen_host` |
| `IRONLOG_CLICKHOUSE_ALLOWED_HOSTS` | empty (no restriction) | Comma-separated IPv4/IPv6 addresses or CIDRs. Set: `svc_vector`, `svc_grafana_analyst`, `svc_grafana_auditor` get `HOST LOCAL, IP '<each>'` (re-applied on every `ironlog-schema` run) and the admin account is limited to loopback + the list. Unset or empty: `HOST ANY` and the upstream admin default. Any entry that is not an IP/CIDR is refused (entrypoint exit 64, `ironlog-schema` exit 1). Single-host mode must leave it unset: containers connect from podman/docker network addresses. Not passed through by `docker-compose.yml` or the Helm chart for the same reason |
| `IRONLOG_S3_TIER` | `off` | `on` adds the S3 cold volume and moves parts to it after `IRONLOG_HOT_DAYS` |
| `IRONLOG_S3_ENDPOINT` | — | Full bucket/prefix URL, AWS S3 or S3-compatible (MinIO, Ceph, OpenShift Data Foundation) |
| `IRONLOG_S3_ACCESS_KEY_ID`, `IRONLOG_S3_SECRET_ACCESS_KEY` | — | Static keys for S3-compatible stores; unset means the AWS credential chain (instance or task role) |
| `IRONLOG_S3_REGION` | — | Optional signing region |
| `IRONLOG_HOT_DAYS` | `30` | Days on local disk before moving to S3 (tier on) |
| `IRONLOG_RETENTION_DAYS` | `30` tier off, `400` tier on | Delete after; matches `docs/retention-policy.md`. Five-year deployments set `1825` |

The image provides `ironlog-schema`, an idempotent command that applies
`clickhouse/ddl/*.sql`, creates the service accounts, applies the tier and
retention TTLs, then **verifies** databases, tables and accounts and exits
non-zero if anything is missing (the check in
`scripts/firstboot/ironlog-apply-schema.sh`). It runs:
- inside the server container on start, against localhost, so a single
  `podman run` works; and
- as a separate one-shot container from the same image against
  `IRONLOG_CLICKHOUSE_HOST` (Kubernetes Job, ECS task, Quadlet oneshot).

Health: `clickhouse-client --query "SELECT 1"` run with admin credentials.
Readiness for dependants is a successful `ironlog-schema` run, not health.

HA hooks, not implemented yet: replica and shard names, and choice of
`ReplicatedMergeTree` with ClickHouse Keeper, will be environment-driven. New
code must not make that harder (no hard-coded engine strings outside the DDL,
no single-node assumptions in `ironlog-schema`).

### ironlog-grafana

| Variable | Default | Meaning |
|---|---|---|
| `IRONLOG_CLICKHOUSE_HOST` | `clickhouse` | Datasource host |
| `IRONLOG_CLICKHOUSE_NATIVE_PORT` | `9000` | Datasource port |
| `CH_GRAFANA_ANALYST_PASSWORD`, `CH_GRAFANA_AUDITOR_PASSWORD` | required | Datasource passwords |
| `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` | required | Local admin |
| `GF_SERVER_ROOT_URL` | — | External URL |
| `GF_DATABASE_*` | SQLite in `/var/lib/grafana` | Set `GF_DATABASE_TYPE=postgres` and friends for a shared database (multi-replica Grafana) |

Local-auth settings from `quadlets/ironlog-grafana.container` are image
defaults. The ClickHouse plugin (pin: `scripts/ami/grafana-clickhouse-plugin.version`)
is baked **outside** `/var/lib/grafana`, so a volume there cannot hide it, and
plugin preinstall is disabled. Provisioning, dashboards and alert rules are
baked.

Health: `GET /api/health` on 3000.

### ironlog-vector

| Variable | Default | Meaning |
|---|---|---|
| `IRONLOG_VECTOR_ROLE` | required | `hosts` (`vector/hosts.yaml`: HEC and native agents) or `aws` (`vector/vector.yaml`: S3 via SQS) |
| `IRONLOG_CLICKHOUSE_HOST` | `clickhouse` | Sink host |
| `IRONLOG_CLICKHOUSE_HTTP_PORT` | `8123` | Sink port |
| `CH_VECTOR_PASSWORD` | required | Sink password |
| `SPLUNK_HEC_TOKEN` | required for `hosts` | HEC token |
| `AWS_REGION`, `SQS_URL_*` | required for `aws` | Existing names in `vector/vector.yaml` |

AWS credentials use Vector's default chain (instance or task role); static keys
stay optional. `vector test` with `vector/tests.yaml` and
`vector/tests-hosts.yaml` must still pass inside the image.

Health: `GET /health` on 8686.

## Deployment targets

| Target | Location | Notes |
|---|---|---|
| podman / Docker | `docker-compose.yml`, `quadlets/` | One host, or several hosts with `IRONLOG_CLICKHOUSE_HOST` pointing across |
| Kubernetes / OpenShift / EKS | `deploy/helm/ironlog/` | Runs under OpenShift `restricted-v2`; schema as a Job |
| Amazon ECS on EC2 | `deploy/ecs/` | CloudFormation; all services on one instance or split; ClickHouse data on a persistent EBS volume |

Not covered by this contract: FIPS-validated crypto inside the containers
(upstream bases are Ubuntu 22.04, Alpine 3.24.3 and Debian 13.7), TLS, HA.
