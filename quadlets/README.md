# ironlog quadlets — podman + systemd translation of docker-compose.yml

This directory is a **translation**, not a redesign, of the repo's
`docker-compose.yml` (Phases 0–5 SIEM stack) into Podman Quadlet units, per
the 2026-08-16 decision to run the appliance on Podman + systemd quadlets
instead of native RPMs or a full compose/orchestrator stack. K3s is
deliberately excluded — it is a local test/demo producer, not part of the
SIEM itself (compose's own comment says so).

On the appliance, these files are deployed to `/etc/containers/systemd/`
(flat, same names as here) and generate systemd units named
`ironlog-<service>.service`. Baked config referenced by `Volume=`/
`EnvironmentFile=` lives read-only at `/opt/ironlog/...`; persistent data is
bind-mounted from `/var/lib/ironlog/<name>/` (a separate EBS data volume),
NOT podman named volumes — this makes the data survive an AMI/appliance
rebuild independent of the container runtime state.

## Files

| File | Produces | Purpose |
|---|---|---|
| `ironlog.network` | `ironlog-network.service` | Podman network `ironlog-siem`; every container joins it and gets a `NetworkAlias=` matching its original compose service name |
| `ironlog-clickhouse.container` | `ironlog-clickhouse.service` | ClickHouse storage/query engine |
| `ironlog-keycloak-db.container` | `ironlog-keycloak-db.service` | Postgres — Keycloak's own state |
| `ironlog-keycloak.container` | `ironlog-keycloak.service` | Keycloak OIDC SSO + mandatory TOTP MFA |
| `ironlog-grafana.container` | `ironlog-grafana.service` | Grafana OSS dashboards/alerts, OIDC login |
| `ironlog-hyperdx-db.container` | `ironlog-hyperdx-db.service` | MongoDB — HyperDX app state only (users/dashboards/searches, no audit data) |
| `ironlog-hyperdx.container` | `ironlog-hyperdx.service` | HyperDX (ClickStack) search/investigation UI, NOT published to the host |
| `ironlog-hyperdx-auth.container` | `ironlog-hyperdx-auth.service` | oauth2-proxy — Keycloak OIDC gate in front of HyperDX |
| `ironlog-vector-hosts.container` | `ironlog-vector-hosts.service` | Vector aggregator: Linux agents (:6000) + K8s splunk_hec (:8088), always on |
| `ironlog-vector.container` | `ironlog-vector.service` | Vector aggregator: AWS ingestion (CloudTrail/GuardDuty/VPC Flow/S3 Access via SQS+S3) — **ships disabled**, see below |
| `hyperdx/default-sources.env` | (baked file, not a unit) | Static, non-secret `DEFAULT_SOURCES` value for HyperDX — deploy to `/opt/ironlog/hyperdx/default-sources.env` |

## Compose → quadlet diff table

Use this to check nothing was silently dropped, side by side with
`docker-compose.yml`.

| Compose service | Quadlet unit | Compose volume(s) | Quadlet mount | Compose port(s) | Quadlet port(s) |
|---|---|---|---|---|---|
| clickhouse | ironlog-clickhouse.container | clickhouse-data; config.d; users.d/00-lockdown.xml (file); initdb; ddl | /var/lib/ironlog/clickhouse:Z; /opt/ironlog/clickhouse/{config.d,ddl,initdb}:ro,Z; users.d/00-lockdown.xml individually :ro,Z | 127.0.0.1:8123:8123, 127.0.0.1:9000:9000 | same, unchanged (loopback preserved) |
| keycloak-db | ironlog-keycloak-db.container | keycloak-db-data | /var/lib/ironlog/keycloak-db:Z | (none) | (none) |
| keycloak | ironlog-keycloak.container | realm-export | /opt/ironlog/keycloak/realm-export:ro,Z | 8080:8080 | 8080:8080 |
| grafana | ironlog-grafana.container | grafana-data; provisioning | /var/lib/ironlog/grafana:Z; /opt/ironlog/grafana/provisioning:ro,Z | 3000:3000 | 3000:3000 |
| hyperdx | ironlog-hyperdx.container | (none) | (none, config via env) | not published | not published (unchanged) |
| hyperdx-db | ironlog-hyperdx-db.container | hyperdx-db-data | /var/lib/ironlog/hyperdx-db:Z | (none) | (none) |
| hyperdx-auth | ironlog-hyperdx-auth.container | (none) | (none) | 8081:4180 | 8081:4180 |
| vector-hosts | ironlog-vector-hosts.container | vector-hosts-buffer; hosts.yaml | /var/lib/ironlog/vector-hosts-buffer:Z; /opt/ironlog/vector/hosts.yaml:ro,Z | 8088:8088, 6000:6000 | 8088:8088, 6000:6000 |
| vector | ironlog-vector.container | vector-buffer; vector.yaml | /var/lib/ironlog/vector-buffer:Z; /opt/ironlog/vector/vector.yaml:ro,Z | (none published) | (none published) |
| k3s | — excluded — | k3s-data | — | — | — |

Network aliases (all required — config/env reference these DNS names
literally): `clickhouse, keycloak-db, keycloak, grafana, hyperdx, hyperdx-db,
hyperdx-auth, vector-hosts, vector`. All on `ironlog-siem` (via
`ironlog.network`).

## Ordering: `depends_on condition: service_healthy/service_started` → systemd

Compose only had real healthchecks on **clickhouse, keycloak-db, hyperdx-db**.
Those three quadlets set `HealthCmd=`/`HealthInterval=`/`HealthRetries=` (the
same probes compose used) plus `Notify=healthy`. `Notify=healthy` makes podman
send `READY=1` to systemd only once podman's own healthcheck reports
`healthy`, not just once the process has started — so a plain
`After=`/`Requires=` on that unit genuinely reproduces
`condition: service_healthy`, instead of only waiting for the container to
start (which is all a bare `After=` on a `Notify=none` unit would guarantee).
For `condition: service_started` edges (compose had no health probe to wait
on anyway) we use `After=` only, no `Requires=`, matching compose's weaker
guarantee.

Edges translated:
- keycloak → After+Requires keycloak-db (healthy)
- grafana → After+Requires clickhouse (healthy); After only keycloak (started)
- hyperdx → After+Requires clickhouse (healthy) and hyperdx-db (healthy)
- hyperdx-auth → After only keycloak (started) and hyperdx (started)
- vector-hosts → After+Requires clickhouse (healthy)
- vector → After+Requires clickhouse (healthy)

`vector-hosts` also had a compose healthcheck (bash `/dev/tcp` probe against
Vector's internal `:8686` API), but nothing in compose's dependency graph
actually waited on it. Translated as a plain `HealthCmd=` for
`podman ps`/monitoring visibility only — no `Notify=healthy`, nothing gates
on it — matching compose's actual behavior, not just its healthcheck block.

## Secret handling: the EnvironmentFile rename problem

`EnvironmentFile=/etc/ironlog/ironlog.env` (the ONE secrets file, generated
by the appliance's first-boot secret resolver, using the `.env.example`
variable names verbatim: `CH_ADMIN_USER`, `CH_VECTOR_PASSWORD`,
`KC_DB_PASSWORD`, `GRAFANA_OAUTH_SECRET`, etc.) only loads a file's variables
under their own literal names into a container's environment — it cannot
rename or interpolate them, and compose did **both**: `CLICKHOUSE_USER:
${CH_ADMIN_USER}` renames; `MONGO_URI: mongodb://hyperdx:${HYPERDX_DB_PASSWORD}@...`
interpolates a secret into a larger static string.

Fix used throughout: put `EnvironmentFile=/etc/ironlog/ironlog.env` under
**`[Service]`** (loads the vars into the *unit's own* systemd environment,
before ExecStart is generated) and write the actual container-facing
`Environment=CONTAINER_NAME=$SOURCE_NAME` in `[Container]`. systemd performs
`$VAR` substitution on the whole generated `ExecStart=podman run ...` command
line using that unit environment, so `$CH_ADMIN_USER` etc. get replaced with
real values before podman ever runs — this is standard systemd
command-line variable substitution (systemd.service(5)), not something
quadlet-specific. Where compose kept the same name in both places (e.g.
`CH_VECTOR_PASSWORD`), we still write it explicitly as
`Environment=CH_VECTOR_PASSWORD=$CH_VECTOR_PASSWORD` for a self-documenting,
auditable list of exactly which secrets each container consumes.

Two values needed extra care because of systemd's own unit-file quoting
(not `EnvironmentFile=`'s — this is `Environment=` written inline in the
unit):
- `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH` (grafana) and
  `DEFAULT_CONNECTIONS` (hyperdx) contain spaces and/or quotes, so the whole
  `KEY=VALUE` is wrapped in outer `"..."` with internal `"` escaped as `\"`,
  per systemd's ExecStart quoting rules.
- `DEFAULT_SOURCES` (hyperdx) is a much larger JSON blob with embedded
  doubled single-quotes (`'':''`, SQL-string escaping nested inside JSON
  string values) but **no secrets** — rather than fight that quoting inline,
  it's baked verbatim as `quadlets/hyperdx/default-sources.env` (deploy to
  `/opt/ironlog/hyperdx/default-sources.env`), loaded via a second
  `EnvironmentFile=` in `ironlog-hyperdx.container`'s `[Container]` section.
  See the comment header in that file for the full reasoning.
- `ironlog-clickhouse.container`'s `HealthCmd=` needs the opposite: it
  references `$$CLICKHOUSE_USER`/`$$CLICKHOUSE_PASSWORD` (systemd-escaped
  literal `$`, per systemd's "use `$$` for a literal dollar sign") so the
  **container's own** `/bin/sh -c` expands those from the container's
  runtime env at healthcheck time, instead of systemd trying to substitute
  them at the host level (where those exact names don't exist in
  `ironlog.env` — only the renamed `CH_ADMIN_USER`/`CH_ADMIN_PASSWORD` do).

**Unverified / needs confirmation on a real box:** this whole mechanism
(systemd `$VAR` substitution inside a quadlet-generated `ExecStart=`, plus
the escaped/quoted inline values above) could not be tested here — podman is
not installed on this Windows dev machine (see "Verify" section below). Treat
every `Environment=` line with a `$VAR` or embedded quote as needing a real
`quadlet -dryrun` + `systemctl start` pass before trusting it in production.

**Other assumption:** compose defaulted `AWS_REGION: ${AWS_REGION:-us-east-1}`.
Systemd/quadlet has no `${VAR:-default}` fallback syntax, so
`ironlog-vector.container` does a plain `$AWS_REGION` substitution — this
assumes the secret resolver always writes a concrete `AWS_REGION` value into
`ironlog.env` (defaulting to `us-east-1` itself if the operator didn't set
one), not that quadlet supplies the default.

## SELinux labelling

RHEL 9 ships SELinux enforcing by default, and unlabelled bind mounts are the
single most common quadlet failure mode. Every `Volume=` bind mount here
carries an explicit relabel flag:
- Read-only baked config under `/opt/ironlog/...` → `:ro,Z` (private,
  container-exclusive read-only label; nothing else needs to share these
  files, and each is only ever mounted into one container in this stack).
- Writable data under `/var/lib/ironlog/...` → `:Z` (private, writable
  relabel — matches `:ro,Z` in privacy semantics, just without the read-only
  bind flag).

Lowercase `:z` (shared label, for a path bind-mounted into *multiple*
containers) is not used anywhere: no bind-mounted path in this stack is
shared across more than one container.

## Enabling `ironlog-vector.service` (AWS ingestion)

`ironlog-vector.container` has **no `[Install]` section** — it is not
disabled by any flag, it simply has nothing for `systemctl enable` to
symlink, so it never starts automatically at boot even if every other
`ironlog-*` unit is enabled. This mirrors compose's `profiles: ["aws"]` gate:
the stack stays green before AWS credentials exist (per CLAUDE.md Phase 2).

To bring it up once AWS ingestion is actually configured (per
`docs/aws-ingestion.md`):
1. Confirm the secret resolver has populated `AWS_REGION`,
   `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and the four `SQS_URL_*`
   values in `/etc/ironlog/ironlog.env`.
2. `systemctl daemon-reload` (picks up the unit if it wasn't already loaded).
3. `systemctl start ironlog-vector.service` to run it now, **and/or**
   `systemctl enable --now ironlog-vector.service` if you want it to persist
   across reboots (this works even without an `[Install]` section — it just
   means a plain `systemctl enable` with no `--now` and no target argument
   has nothing to do; `enable --now` still starts it immediately, and you can
   separately add the unit to a target's `.wants/` directory if persistent
   enablement across reboots is desired without editing this file).
4. `journalctl -u ironlog-vector.service -f` / `docker logs`-equivalent
   (`podman logs -f ironlog-vector`) to confirm rows are landing, per
   CLAUDE.md's existing Phase 2 remaining-work note.

## Air-gap blocker: Grafana plugin install

`GF_INSTALL_PLUGINS=grafana-clickhouse-datasource` (carried over unchanged
from compose) makes Grafana fetch the plugin from grafana.com **at container
start**, which needs network egress. The target environments include
disconnected enclaves (GovCloud, C2S, SC2S) where that egress will not exist.
**Not solved in this translation** — flagging it as an open item. Options for
whoever picks this up: bake the plugin into a custom Grafana image built at
AMI-build time, or pre-stage the unpacked plugin directory into
`/var/lib/ironlog/grafana/plugins/` so Grafana finds it locally and skips the
fetch.

## Verify on a Rocky 9 box

Podman is not installed on this Windows dev machine, so none of the units
below have been syntax-checked or started — this section is what to run on
real target hardware, not a claim that it already passed.

```bash
# 1. Copy the network file + all *.container files into place (flat, as-is):
sudo cp quadlets/ironlog.network quadlets/*.container /etc/containers/systemd/
sudo mkdir -p /opt/ironlog/hyperdx
sudo cp quadlets/hyperdx/default-sources.env /opt/ironlog/hyperdx/

# 2. Make systemd (re-)run the quadlet generator over the new unit files:
sudo systemctl daemon-reload

# 3. Syntax-check without actually generating/starting anything (adjust path
#    if your podman build installs the generator elsewhere — check
#    `rpm -ql podman | grep quadlet`):
/usr/libexec/podman/quadlet -dryrun

# 4. Bring the always-on services up (ironlog-vector.service is intentionally
#    excluded — see "Enabling ironlog-vector.service" above):
sudo systemctl start ironlog-network.service
sudo systemctl start ironlog-clickhouse.service ironlog-keycloak-db.service ironlog-hyperdx-db.service
sudo systemctl start ironlog-keycloak.service ironlog-vector-hosts.service
sudo systemctl start ironlog-grafana.service ironlog-hyperdx.service
sudo systemctl start ironlog-hyperdx-auth.service

# 5. Confirm everything is actually running and (for the 3 healthchecked
#    services) healthy:
podman ps
systemctl status 'ironlog-*.service'
```

## What was NOT translated / open items

- **k3s** — excluded per task scope; it's a local test/demo producer per
  compose's own comment, not appliance-relevant.
- **Grafana plugin egress** — see "Air-gap blocker" above.
- **`AWS_REGION` default** — see "Secret handling" above; needs the secret
  resolver to always write a concrete value.
- **No live validation** — podman unavailable on this dev machine; see
  "Verify" section. Every `$VAR`-substitution and quoted `Environment=` line
  should be treated as needing a real dry-run before production use.
