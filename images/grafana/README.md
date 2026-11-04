# ironlog-grafana

Contract: `images/README.md`. Build (context = repo root):

    docker build -f images/grafana/Dockerfile -t ironlog-grafana .

Test (linux/amd64, needs Docker, curl; pulls `postgres:16.4-alpine`):

    bash scripts/tests/grafana-image.test.sh      # on Windows: run inside WSL

## Health

    GET http://<host>:3000/api/health   # 200 and "database": "ok"

Image `HEALTHCHECK` uses `wget` against `127.0.0.1:3000`. For Kubernetes/ECS/Quadlet use the HTTP GET above.

## Notes

- **Datasource address.** Grafana provisioning has no default-value syntax
  (only `$VAR` / `${VAR}`). The Dockerfile rewrites `host`/`port` in the baked
  copy of `datasources/clickhouse.yml` to `${IRONLOG_CLICKHOUSE_HOST}` and
  `${IRONLOG_CLICKHOUSE_NATIVE_PORT}`; the defaults (`clickhouse`, `9000`) are
  image `ENV`. The repo file `grafana/provisioning/datasources/clickhouse.yml`
  is unchanged, so Compose keeps working. Do not set either variable to an
  empty string: the datasource would get an empty host.
- **Plugin.** `grafana-clickhouse-datasource` is installed at build time with
  `grafana cli` at the version in `scripts/ami/grafana-clickhouse-plugin.version`
  into `/usr/share/ironlog/grafana-plugins` (`GF_PATHS_PLUGINS`), not under
  `/var/lib/grafana`. grafana.com serves a per-architecture zip, so each
  platform's build step gets its own backend binary; the build fails if
  `gpx_clickhouse_linux_$TARGETARCH` is missing. `GF_PLUGINS_PREINSTALL_DISABLED=true`.
- **Local-auth defaults** (image `ENV`, overridable): login form on, basic
  auth on, sign-up off, anonymous off, generic OAuth off, `x_xss_protection` false.
- **Database.** SQLite in `/var/lib/grafana` by default. For several replicas
  set `GF_DATABASE_TYPE=postgres`, `GF_DATABASE_HOST`, `GF_DATABASE_NAME`,
  `GF_DATABASE_USER`, `GF_DATABASE_PASSWORD`, `GF_DATABASE_SSL_MODE`. Tested.
- **Arbitrary UID.** Runs as 472 by default; also starts as
  `--user 1000770000:0`. Grafana writes its own files `0640`/`0700`, so a
  persistent `/var/lib/grafana` must be reused by the same UID (OpenShift
  assigns one UID per namespace). Changing the UID against an existing SQLite
  volume fails with `attempt to write a readonly database`; use Postgres or a
  fresh volume.
- Provisioned dashboards use `disableDeletion`/`allowUiUpdates: false`; edit in git.
