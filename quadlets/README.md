# ironlog quadlets: podman + systemd units for the ironlog images

Quadlet translation of `docker-compose.yml`. The units run the three ironlog
images (`ironlog-clickhouse`, `ironlog-grafana`, `ironlog-vector`; contract in
[`images/README.md`](../images/README.md)). All configuration is baked into the
images: **no config bind mounts**. Runtime input is environment variables and
one data directory per container. All units can share one host or be split
across hosts ([Split-host mode](#split-host-mode)).

Host OS for podman hosts: **Oracle Linux 9** (operator decision 2026-11-04).
K3s is excluded: it is a test/demo producer, not part of the SIEM.

Units go in `/etc/containers/systemd/` (flat, names as here) and generate
`ironlog-<name>.service`. Local authentication and the Grafana login are in
[local authentication](../docs/local-auth.md). No Keycloak, Postgres, HyperDX,
MongoDB or oauth2-proxy unit exists.

## Oracle Linux 9 and podman versions

| Fact | Status |
|---|---|
| OL 9.4 release notes list "Notable changes in Podman v4.9" and the Container Tools meta-package (podman, buildah, skopeo, crun, runc); podman and Quadlet are in the OL9 repositories | **verified** against docs.oracle.com (OL 9.4 release notes, Containers; OL Podman Quadlets guide). Later OL9 updates may ship a newer podman: **unchecked**, run `podman --version` |
| An Oracle Linux 9.8 container (`container-registry.oracle.com/os/oraclelinux:9`, `cat /etc/oracle-release`) installs `podman-5.8.2-8.0.1.el9_8` with `dnf install podman`; its `/usr/libexec/podman/quadlet -dryrun` accepted all units here (exit 0, no warnings) | **verified** 2026-11-04. This is podman 5.8, not 4.9, so it does not prove the units on an older OL9 minor release |
| Install | `sudo dnf install -y podman` (what was run in that container); `container-tools` meta-package per the OL docs, not run |
| Quadlet generator path | `/usr/libexec/podman/quadlet` (check `rpm -ql podman \| grep quadlet`) |

First podman release that documents each key these units use, from the
upstream `RELEASE_NOTES.md` (read 2026-11-04):

| Key | First release |
|---|---|
| `Pull=` | 4.6.0 |
| `Ulimit=`, `NetworkName=` (in `.network`) | 4.7.0 |
| health keys in `.container` | 4.5.0 (general bullet; the literal names `HealthCmd`, `HealthStartPeriod` etc. were not found in the notes: **assumed** from that bullet) |
| `Exec=` | not found in release notes: **assumed** present in 4.x |
| `Type=oneshot` for `.container` | not found in release notes; the podman docs allow it; the 5.8.2 generator produced a oneshot `podman run --rm` without `--sdnotify`/`-d`. On 4.9: **assumed**, needs the dry-run below |

**Minimum: podman 4.7**, so OL 9.4's 4.9 satisfies every key used here. These
units deliberately avoid keys that need newer podman (and so do not work on
4.9): `Notify=healthy` (5.0.0), `NetworkAlias=` (5.2.0), Quadlet drop-in
directories `*.container.d` (5.0.0). Readiness gating is done by
`ironlog-schema.service` instead of `Notify=healthy`; the ClickHouse address
is the container name `ironlog-clickhouse` (default), not a `clickhouse` alias.
Plain **systemd** drop-ins on the generated service (for example
`/etc/systemd/system/ironlog-grafana.service.d/`) work on any version.

## Files

| File | Produces | Purpose |
|---|---|---|
| `ironlog.network` | `ironlog-network.service` | Podman network `ironlog-siem` |
| `ironlog-clickhouse.container` | `ironlog-clickhouse.service` | ClickHouse (`ironlog-clickhouse` image) |
| `ironlog-schema.container` | `ironlog-schema.service` | One-shot `ironlog-schema` against `IRONLOG_CLICKHOUSE_HOST`; Grafana and both Vector units `Requires=`/`After=` it |
| `ironlog-grafana.container` | `ironlog-grafana.service` | Grafana 13.3.0, local login |
| `ironlog-vector-hosts.container` | `ironlog-vector-hosts.service` | Vector role `hosts`: Linux agents (:6000), HEC (:8088) |
| `ironlog-vector.container` | `ironlog-vector.service` | Vector role `aws` (SQS/S3). **Ships disabled** |

## Images

All `Image=` lines are `ghcr.io/jake-kelley/<name>:<upstream version>` (contract
default registry; moving tag `26.8.34.13`, `13.3.0`, `0.61.0`; immutable tags
are `<version>-<git short sha>`). The tags and registry are **assumptions until
the images are published**: nothing has been pushed to ghcr.io. The vector tag
`0.61.0` is the contract's `<upstream version>` rule applied to the upstream
`0.61.0-debian` tag.

Units use `Pull=never`, so the images must exist locally first. Either:

```bash
# connected host
sudo podman pull ghcr.io/jake-kelley/ironlog-clickhouse:26.8.34.13
sudo podman pull ghcr.io/jake-kelley/ironlog-grafana:13.3.0
sudo podman pull ghcr.io/jake-kelley/ironlog-vector:0.61.0

# offline host: on a connected machine
podman save -o ironlog-images.tar \
  ghcr.io/jake-kelley/ironlog-clickhouse:26.8.34.13 \
  ghcr.io/jake-kelley/ironlog-grafana:13.3.0 \
  ghcr.io/jake-kelley/ironlog-vector:0.61.0
# carry the tar over, then on the target:
sudo podman load -i ironlog-images.tar

# or build locally from a checkout (context = repo root) and tag to match
sudo podman build -f images/clickhouse/Dockerfile -t ghcr.io/jake-kelley/ironlog-clickhouse:26.8.34.13 .
```

Another registry or a pinned `-<sha>` tag: edit `Image=` in the units. Split
hosts only need the images for the units they run. The Compose path tags
`ironlog-*:local` instead (see `docker-compose.yml`).

## Compose to quadlet diff

| Compose service | Quadlet unit | Data | Ports |
|---|---|---|---|
| clickhouse | ironlog-clickhouse | `/var/lib/ironlog/clickhouse:Z` | `${IRONLOG_CLICKHOUSE_BIND}` (default `127.0.0.1`) 8123, 9000 |
| schema | ironlog-schema | none | none |
| grafana | ironlog-grafana | `/var/lib/ironlog/grafana:Z` | 3000 |
| vector-hosts | ironlog-vector-hosts | `/var/lib/ironlog/vector-hosts-buffer:Z` | 8088, 6000 |
| vector (profile `aws`) | ironlog-vector | `/var/lib/ironlog/vector-buffer:Z` | none |
| k3s | excluded | | |

Removed from the old units (now in the images): `config.d`, `users.d`,
`initdb`, `ddl`, Grafana `provisioning` and `grafana-plugins`, Vector yaml,
`NetworkAlias=`.

## Ordering

```
ironlog-network -> ironlog-clickhouse -> ironlog-schema (oneshot, RemainAfterExit)
                                              -> ironlog-grafana
                                              -> ironlog-vector-hosts
                                              -> ironlog-vector (when enabled)
```

- Grafana and both Vector units `Requires=` + `After=ironlog-schema.service`.
  ClickHouse health only means `SELECT 1` works (true on an empty database), so
  gating is on schema verification, not health.
- `ironlog-schema.service` has `Wants=`/`After=ironlog-clickhouse.service`
  (ignored on a host with no ClickHouse unit) and itself waits up to
  `IRONLOG_SCHEMA_WAIT_SECONDS` (120) for the server, so no `Notify=healthy` is
  needed. `TimeoutStartSec=300`. It exits non-zero, and dependants do not start,
  if the 7 `siem` tables, `audit.query_archive` or the 3 service accounts are
  missing.
- The ClickHouse container also runs `ironlog-schema` in the background on
  start (retries 5 x 10 s). Both runs are idempotent; the Compose live proof ran
  the in-container run and the one-shot against the same server (one-shot exited 0).

## Secret handling

`EnvironmentFile=/etc/ironlog/ironlog.env` (the one secrets file; names as in
`.env.example`) is under `[Service]`. systemd loads it into the **unit's**
environment and substitutes `${NAME}` into the generated `podman run` line, which
is how `CLICKHOUSE_USER=${CH_ADMIN_USER}` renames work (Quadlet's own
`EnvironmentFile=` cannot rename). Every container-facing variable is listed
explicitly in `[Container]`.

systemd has no `${VAR:-default}`. Defaults are `Environment=` lines in `[Service]`
(`IRONLOG_CLICKHOUSE_BIND=127.0.0.1`, `IRONLOG_CLICKHOUSE_HOST=ironlog-clickhouse`,
the port variables), which `ironlog.env` overrides (systemd.exec: file values
override `Environment=`). **Never write one of these as an empty value**: an
empty `IRONLOG_CLICKHOUSE_BIND` renders `:8123:8123` (verified with a systemd
test unit), which podman is expected to publish on all interfaces (that last
step not tested).

`AWS_REGION` has no default in `ironlog-vector.container`: the secret resolver
must write a concrete value.

**Verified**: the Quadlet generator (podman 5.8.2, OL 9.8 container) keeps
`${NAME}` and `PublishPort=${IRONLOG_CLICKHOUSE_BIND}:8123:8123` verbatim in
`ExecStart=`, and systemd 259 (WSL Ubuntu) expands `Environment=` defaults,
`EnvironmentFile=` overrides, and renders an empty value as shown above.
**Not verified**: starting these units under podman/systemd with real images.

## Data directories

Bind mounts under `/var/lib/ironlog/` (a separate data volume, so data
survives a rebuild). The images run as non-root, so create them with the right
owner **before** first start:

```bash
sudo install -d -m 2770 -o 10001 -g 0 /var/lib/ironlog/clickhouse /var/lib/ironlog/vector-hosts-buffer /var/lib/ironlog/vector-buffer
sudo install -d -m 0750 -o 472   -g 0 /var/lib/ironlog/grafana
```

(uid 10001 = ClickHouse and Vector images, 472 = Grafana image; from the image
READMEs, verified there with `docker`, not with podman.) A Grafana volume must
keep the same uid between starts.

## SELinux (Oracle Linux 9 enforcing)

Every data bind mount carries `:Z` (private relabel). No other host paths are
mounted. `Z`, not `z`, because no path is shared between containers.

## Split-host mode

Run the ClickHouse container on one host and Grafana + Vector on another. The
only coupling is `IRONLOG_CLICKHOUSE_HOST` (and the optional
`IRONLOG_CLICKHOUSE_NATIVE_PORT` 9000 for Grafana/schema,
`IRONLOG_CLICKHOUSE_HTTP_PORT` 8123 for Vector).

### What this exposes

ClickHouse ports are loopback-only by default. That is a deliberate security
property: the admin login is not reachable from a network. Split-host mode
needs those ports reachable from the other host, so set
`IRONLOG_CLICKHOUSE_BIND` to the ClickHouse host's private address. Then:

- Anything that can route to that address:8123/9000 can attempt a login as the
  admin account, `svc_vector`, `svc_grafana_analyst` or `svc_grafana_auditor`.
  Without `IRONLOG_CLICKHOUSE_ALLOWED_HOSTS` (below) authentication is the only
  barrier: the service accounts are created with `HOST ANY` and the upstream
  image allows the admin from any address.
- Traffic, including passwords and log data, is **plaintext**. TLS is out of
  scope in the contract. Use an isolated/private VLAN or an encrypted overlay.
- The Grafana/Vector host holds ClickHouse credentials, and because the schema
  one-shot runs there, also the **admin** password (see below).

Bind only to a private interface address, never `0.0.0.0` unless a firewall
does the restricting, and restrict at the firewall as well:

```bash
# on the ClickHouse host, allow only the Grafana/Vector host (OL9 firewalld)
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.1.20 port port=8123 protocol=tcp accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.1.20 port port=9000 protocol=tcp accept'
sudo firewall-cmd --reload
```

The rich rules above only filter traffic *to the host*. Published container
ports are DNATed and then forwarded, and firewalld's forward chain starts with
`ct status dnat accept`, so **rich rules alone do not block them**: from a third
host `curl http://10.0.1.10:8123/ping` still returned `Ok.` (measured
2026-11-04, OL9, podman 5.8.2, netavark). Drop before the DNAT as well:

```bash
for p in 8123 9000; do
  sudo firewall-cmd --permanent --direct --add-rule ipv4 raw PREROUTING 0     -p tcp -d 10.0.1.10 --dport $p ! -s 10.0.1.20/32 -j DROP
done
sudo firewall-cmd --reload
sudo podman network reload --all   # a firewalld reload drops netavark's forward rules
```

Skipping the last line left B connecting but getting no reply (measured). With that, the same curl from a third host times out and from `10.0.1.20`
returns `Ok.`. (A firewalld *policy* with ingress zone `public` and egress
`ANY` was tried and did not block it.)

### In-ClickHouse source allowlist (`IRONLOG_CLICKHOUSE_ALLOWED_HOSTS`)

Set it in `ironlog.env` on the ClickHouse host to a comma-separated list of the
client addresses or CIDRs (IPv4/IPv6), e.g. `IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=10.0.1.20`.
ClickHouse then refuses logins from every other source address, whatever the
firewall does: the three service accounts become `HOST LOCAL, IP '...'` (applied
by `ironlog-schema` on every run, so changing or clearing the variable takes
effect at the next run) and the admin account is limited to loopback + the list.
Both units pass it through; set the same value wherever `ironlog-schema` runs.
Invalid entries make the container and `ironlog-schema` exit non-zero. Leave it
unset in single-host mode (containers connect from the podman network). The
restart of `ironlog-clickhouse` is needed for the admin part; the service
accounts follow the next schema run. Run the schema one-shot with the **same**
value as the server: it re-applies the accounts' `HOST` clause on every run, so a
one-shot without the variable would reset them to `HOST ANY` (and it needs the
same `IRONLOG_S3_TIER`/`IRONLOG_HOT_DAYS`/`IRONLOG_RETENTION_DAYS` as the server or
verification fails). The admin override is a `users.d/zz-admin-networks.xml`
written at container start (it must sort after the upstream `default-user.xml`).

Refusals look like `AUTHENTICATION_FAILED` to the client; the server log says
`Connections from <ip> are not allowed. (IP_ADDRESS_NOT_ALLOWED)`.

**Measured 2026-11-04** (OL9, podman 5.8.2, A `10.10.10.237`, B `10.10.10.236`):
ClickHouse sees B's real address through the published port
(`system.query_log.address` = `::ffff:10.10.10.236`), so the list works behind
DNAT. With `IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=10.10.10.236` on both hosts: B's
schema one-shot verified, an HEC event sent to B landed in A's `siem.k8s_logs`,
both Grafana datasources reported OK, and `svc_grafana_analyst`, `svc_vector` and
the admin were refused from another container on A (`10.89.0.15`, server log
`IP_ADDRESS_NOT_ALLOWED`) while the admin worked from B. The workstation could
not even open the ports: the raw PREROUTING drop refused it before ClickHouse
(so the workstation was not tested against the allowlist itself).

### Two-host example

ClickHouse host `10.0.1.10`, Grafana + Vector host `10.0.1.20`.

**Host A (ClickHouse)**: units `ironlog.network`, `ironlog-clickhouse.container`.

```bash
# /etc/ironlog/ironlog.env  (mode 0600, root)
CH_ADMIN_USER=siem_admin
CH_ADMIN_PASSWORD=...
CH_VECTOR_PASSWORD=...
CH_GRAFANA_ANALYST_PASSWORD=...
CH_GRAFANA_AUDITOR_PASSWORD=...
IRONLOG_CLICKHOUSE_BIND=10.0.1.10
IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=10.0.1.20
```

```bash
sudo cp quadlets/ironlog.network quadlets/ironlog-clickhouse.container /etc/containers/systemd/
sudo systemctl daemon-reload && sudo systemctl start ironlog-clickhouse.service
```

The server applies the schema itself at start (log line
`SIEM schema, TTLs and service accounts verified`).

**Host B (Grafana + Vector)**: units `ironlog.network`, `ironlog-schema.container`,
`ironlog-grafana.container`, `ironlog-vector-hosts.container`.

```bash
# /etc/ironlog/ironlog.env  (mode 0600, root); the same passwords and allowlist as host A
IRONLOG_CLICKHOUSE_HOST=10.0.1.10
IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=10.0.1.20
CH_ADMIN_USER=siem_admin
CH_ADMIN_PASSWORD=...
CH_VECTOR_PASSWORD=...
CH_GRAFANA_ANALYST_PASSWORD=...
CH_GRAFANA_AUDITOR_PASSWORD=...
GRAFANA_ROOT_URL=http://hostb.example:3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=...
SPLUNK_HEC_TOKEN=...
```

```bash
# data directories (the units bind-mount them; they are not created for you)
sudo install -d -m 2770 -o 10001 -g 0 /var/lib/ironlog/vector-hosts-buffer
sudo install -d -m 0750 -o 472   -g 0 /var/lib/ironlog/grafana
sudo cp quadlets/ironlog.network quadlets/ironlog-schema.container \
        quadlets/ironlog-grafana.container quadlets/ironlog-vector-hosts.container \
        /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl start ironlog-schema.service ironlog-grafana.service ironlog-vector-hosts.service
```

`ironlog-schema.service` on B runs `ironlog-schema` against `10.0.1.10:9000`
(that is why B needs the admin credentials), and Grafana and Vector start only
after it passes. A variant without the admin password on host B is not provided.

**Verified 2026-11-04** on two Oracle Linux 9 VMs (podman 5.8.2, SELinux
enforcing, firewalld): ClickHouse + schema on A (`10.10.10.237`, bound to that
address), Grafana + `vector-hosts` on B (`10.10.10.236`). Schema one-shot on B
passed against A; HEC events on B landed in A's `siem.k8s_logs`; both Grafana
datasources reported OK; `svc_grafana_analyst` could read from B; the built-in
`default` user was refused; `:8123/ping` from a third host timed out and from B
returned `Ok.`; both hosts rebooted (A, then B) and B reconnected without
action. Not tested: TLS, IPv6, podman 4.9, a firewall-less A.

Other splits follow from the variable: Vector alone, or Grafana alone, on a
host is the same recipe with only that unit plus `ironlog-schema.container`.
Compose does not support split mode: there Grafana and Vector wait for the local
`schema` service.

## S3 cold tier (`IRONLOG_S3_TIER=on`)

Tiering is a ClickHouse-host setting; Grafana and Vector hosts are unaffected.
Add to `/etc/ironlog/ironlog.env` on the ClickHouse host (mode 0600), then
`sudo systemctl daemon-reload && sudo systemctl restart ironlog-clickhouse ironlog-schema`
(the units must be the ones that pass these variables through; they are listed in
`ironlog-clickhouse.container` and `ironlog-schema.container`):

```bash
IRONLOG_S3_TIER=on
IRONLOG_S3_ENDPOINT=http://s3.example:8333/ironlog-cold/ch/   # bucket and prefix; the bucket must exist
IRONLOG_S3_ACCESS_KEY_ID=...        # set both or neither
IRONLOG_S3_SECRET_ACCESS_KEY=...
IRONLOG_S3_REGION=us-east-1         # optional
IRONLOG_HOT_DAYS=7                  # default 30: days on local disk
IRONLOG_RETENTION_DAYS=100          # default 400 with tier on: days until DELETE; must exceed HOT_DAYS
```

What changes: the image generates `config.d/20-storage-s3.xml` (secrets by
`from_env`, never written out), every `siem.*` table gets storage policy
`hot_to_s3` and `TTL event_time + HOT_DAYS TO VOLUME 's3', event_time + RETENTION_DAYS DELETE`.
`audit.query_archive` is untouched. Switching an existing populated tier-off
deployment to tier on works in place. **Switching tier back off is unsupported**:
tables keep `hot_to_s3` and `ironlog-schema` verification fails. If an existing
ironlog.env lacks these lines the tier stays off. Empty values count as unset.

**Verified 2026-11-04** on the two OL9 hosts of the split-host test (SELinux
enforcing, podman 5.8.2), ClickHouse on A with the S3 endpoint on B:
schema journal `... wrong storage policy=0 (tier=on)` and `verified` after the
restart and after a reboot of A; rows inserted 10 days old moved to disk
`s3_cold` (visible in `system.parts`, objects in the bucket, still readable
through ClickHouse and through Grafana's `SIEM (analyst)` datasource), 200 day
old rows were deleted, current rows stayed on `default`; HEC events on B still
landed; no AVC denials on either host; the S3 keys do not appear in the
`ironlog-clickhouse` / `ironlog-schema` journals. **Not tested**: real AWS S3,
instance-role / `use_environment_credentials` credentials on a host, TLS to the
endpoint (the test used plain HTTP): these belong to the AWS phase.

### Test-only S3 endpoint (SeaweedFS)

`quadlets/test-fixtures/ironlog-test-s3.container` runs
`docker.io/chrislusf/seaweedfs:4.52` as a throwaway S3 endpoint. **Test fixture,
not for deployments.** Setup used on host B:

```bash
# s3.json: {"identities":[{"name":"ironlog","credentials":[{"accessKey":"...","secretKey":"..."}],
#           "actions":["Admin","Read","Write","List","Tagging"]}]}
sudo install -d -m 711 /etc/ironlog-test-s3
sudo install -m 600 -o 1000 -g 1000 s3.json /etc/ironlog-test-s3/s3.json   # the image runs as uid 1000
sudo cp quadlets/test-fixtures/ironlog-test-s3.container /etc/containers/systemd/
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.237/32" port port="8333" protocol="tcp" accept' && sudo firewall-cmd --reload
sudo systemctl daemon-reload && sudo systemctl start ironlog-test-s3.service
echo "s3.bucket.create -name ironlog-cold" | sudo podman exec -i ironlog-test-s3 weed shell -master=localhost:9333
```

Gotchas found: the S3 port accepts connections a few seconds after the unit is
`active`; the key file must be readable by uid 1000 or SeaweedFS silently runs
without the identities; a `curl --aws-sigv4` bucket PUT returned
`SignatureDoesNotMatch` against it, so the bucket is created with `weed shell`
(ClickHouse's own signed requests worked).

## Relation to `scripts/firstboot` and `packer/`

`scripts/firstboot/ironlog-schema.service` (the old reconciliation unit) and
`ironlog-schema.container` produce the **same unit name**. These quadlets
replace that dependency. `scripts/firstboot` and `packer/` were deliberately not
edited here (they are being retired separately), so as shipped the appliance
build still installs the old unit and `/opt/ironlog/...` config, and the firstboot
secret resolver does not yet write `IRONLOG_CLICKHOUSE_*` (the defaults above
make that unnecessary on one host). Do not install both schema units on one host.

## Enabling `ironlog-vector.service` (AWS ingestion)

No `[Install]` section, mirroring Compose's `aws` profile. Put `AWS_REGION`,
the four `SQS_URL_*` and optionally static `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` in `ironlog.env` (an instance or task role works without
static keys), then `sudo systemctl start ironlog-vector.service`. Logs:
`journalctl -u ironlog-vector.service -f`, `podman logs -f ironlog-vector`. See
`docs/aws-ingestion.md`.

## Verify on a target host

Live-tested 2026-11-04 on an Oracle Linux 9.8 VM (UEK 6.12, SELinux enforcing,
podman 5.8.2, Proxmox): fresh image builds from the repo, arbitrary-UID runs,
Quadlet install and start, HEC to ClickHouse to Grafana, port exposure, no AVC
denials, every unit restarted, and a full reboot with the stack coming back on
its own and the earlier rows intact.

`scripts/tests/ol9-quadlet-e2e.sh` repeats all of it except the reboot. Copy the
repo to the host (for example `git archive HEAD | ssh host 'mkdir ironlog &&
tar x -C ironlog'`), then on the host:

```bash
cd ironlog
./scripts/tests/ol9-quadlet-e2e.sh                         # build, install, test
IRONLOG_E2E_SKIP_BUILD=1 ./scripts/tests/ol9-quadlet-e2e.sh  # reuse built images
```

It needs passwordless sudo, reuses `/etc/ironlog/ironlog.env` if present
(otherwise writes random passwords there, mode 600), never prints secrets,
leaves the stack running and exits non-zero on any failure. For the reboot
check, `sudo reboot`, then confirm `systemctl is-active 'ironlog-*'`, the
`ironlog-schema` journal line `SIEM schema, TTLs and service accounts verified`
and that row counts are unchanged.

The manual steps behind the script:

```bash
sudo cp quadlets/ironlog.network quadlets/*.container /etc/containers/systemd/
/usr/libexec/podman/quadlet -dryrun                  # prints generated units, shows key errors
sudo systemctl daemon-reload
sudo systemctl start ironlog-clickhouse.service ironlog-schema.service
sudo systemctl start ironlog-grafana.service ironlog-vector-hosts.service
podman ps
systemctl status 'ironlog-*.service'
sudo podman inspect ironlog-clickhouse --format '{{.HostConfig.PortBindings}}'   # expect 127.0.0.1 unless IRONLOG_CLICKHOUSE_BIND is set
```

Check in the dry-run output that `PublishPort` shows `127.0.0.1:8123:8123`,
that `ironlog-schema.service` is `Type=oneshot`, and that no unsupported-key
warning appears.

## Open items

- A dry-run on podman 4.9 if any
  host still runs OL 9.4. S3 tier against real AWS S3 / instance roles (AWS phase).
- Image publication to ghcr.io (tags above are the contract's, not yet pushed).
- Retiring `scripts/firstboot/ironlog-schema.service` and the `/opt/ironlog`
  config staging in `packer/`.
- TLS between hosts.
