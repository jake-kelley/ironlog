# ironlog-vector

Contract: `images/README.md`. Build context is the repository root:

```
docker build -f images/vector/Dockerfile -t ironlog-vector .
```

One image, two roles, chosen by `IRONLOG_VECTOR_ROLE`:

| Role | Config | Listens |
|---|---|---|
| `hosts` | `/etc/vector/hosts.yaml` (from `vector/hosts.yaml`) | 8088 HEC, 6000 native |
| `aws` | `/etc/vector/vector.yaml` (from `vector/vector.yaml`) | none (SQS/S3 pull) |

Unset or any other value exits 64 with
`ironlog-vector: IRONLOG_VECTOR_ROLE must be 'hosts' or 'aws' (got '...')`.
Arguments after the image name run as a Vector subcommand (`validate`, `test`)
and skip the role check.

## Environment

See `images/README.md`. `IRONLOG_CLICKHOUSE_HOST` / `IRONLOG_CLICKHOUSE_HTTP_PORT`
are interpolated into the sink endpoints (`${VAR:-default}`, defaults
`clickhouse` / `8123`), so the shared config files still work unchanged under
Compose and Quadlets. `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` is
baked in. AWS uses the default credential chain; `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` are optional.

## Health

```
/usr/local/bin/ironlog-healthcheck
```

Exit 0 when `GET /health` on the Vector API returns 200. Both roles enable the
API on `127.0.0.1:8686` (loopback only, unauthenticated), so use an **exec**
probe, not an HTTP probe against the pod IP: Docker `HEALTHCHECK` (baked),
Kubernetes `exec`, ECS `healthCheck.command`, Quadlet `HealthCmd`.

## Runtime

Runs as uid 10001, gid 0. `/var/lib/vector` (`data_dir`, disk buffers) is
group 0 with `g=u`, so an arbitrary uid with gid 0 (`--user 1000770000:0`) works.

## Test

`scripts/tests/vector-image.test.sh` (set `DOCKER` for a non-default CLI; the
CH image is `CH_IMAGE`).
