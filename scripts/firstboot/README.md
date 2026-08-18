# scripts/firstboot/ — appliance first-boot configuration

Turns a generic ironlog AMI (built by `packer/`, running the `quadlets/`
Podman units) into a configured, running appliance instance. Deployed by
Packer to `/usr/local/lib/ironlog/` (provisioner step 5 in
`packer/README.md`); `ironlog-firstboot.service` itself is installed to
`/etc/systemd/system/` by `scripts/ami` (not this worker's scope — this
directory ships the unit file, `scripts/ami` is responsible for actually
placing it and enabling it at build time).

## Files

| File | Purpose |
|---|---|
| `ironlog-firstboot.sh` | Main first-boot logic (idempotent, oneshot) |
| `secret-resolver.sh` | URI → plaintext resolver (`ssm://`, `asm://`, `file://`, `generate:`, literal); separately testable |
| `ironlog-firstboot.service` | systemd oneshot unit, ordered before every `ironlog-*.service` |
| `appliance.conf.example` | Fully commented config — every scheme, all three modes |
| `ironlog-apply-schema.sh` | Reconciles the ClickHouse SIEM schema/service accounts and **verifies** the result — runs on EVERY boot, not just the first |
| `ironlog-schema.service` | systemd oneshot unit for the above, ordered after `ironlog-clickhouse.service` |
| `README.md` | This file |

## Why a schema unit lives in a directory called `firstboot`

`ironlog-apply-schema.sh` and `ironlog-schema.service` are **not**
first-boot-only. They ship here because this is the directory packer installs
to `/usr/local/lib/ironlog/`, but the unit has no `ConditionPathExists` guard
and runs on every boot deliberately.

The reason, measured on a real `c7g.large` on 2026-08-18: the
`clickhouse-server` image executes `/docker-entrypoint-initdb.d/*` **exactly
once**, and only when `/var/lib/clickhouse/metadata` is empty. On the appliance
that path is a bind mount on the persistent data volume, so a first boot that
fails *part way* leaves a non-empty metadata dir — and every later start then
sets `DATABASE_ALREADY_EXISTS` and skips initdb permanently. The observed
result was an appliance with **no `siem` database, no `audit` database and no
service accounts**, in which every container reported `healthy` and every
dependent unit started successfully, because the ClickHouse healthcheck is
`SELECT 1` and `SELECT 1` answers fine against a server with no schema at all.

So the schema is now *reconciled* rather than *initialised*. Every statement in
`clickhouse/ddl/*.sql` is `CREATE ... IF NOT EXISTS` and ClickHouse `GRANT` is a
no-op when already granted, so re-applying on each boot is safe. The script
then asserts 7 `siem` tables, `audit.query_archive`, and 4 service accounts, and
exits non-zero otherwise. Every unit that queries ClickHouse (`vector-hosts`,
`vector`, `grafana`, `hyperdx`) has been repointed from
`Requires=ironlog-clickhouse.service` to `Requires=ironlog-schema.service`, so
an incomplete schema now blocks them instead of letting them start against
nothing.

Two design points worth not undoing:

- The script `podman exec`s the container's own
  `/docker-entrypoint-initdb.d/99-init.sh` instead of reimplementing it. That
  keeps one copy of the user-creation SQL, and the container already holds the
  `CH_*_PASSWORD` values in its environment — **no secret is read, copied or
  logged by the host-side script**.
- The schema check is **not** in the ClickHouse `HealthCmd`. Making the
  healthcheck schema-aware would make ClickHouse wait on this unit while this
  unit waits on ClickHouse to be healthy — a deadlock.

## Launch procedure

1. Build/select the ironlog AMI (see `packer/README.md`).
2. Launch an EC2 instance from it with **user-data** set to your filled-in
   copy of `appliance.conf.example` (plain text — no cloud-init/MIME
   wrapper needed, `ironlog-firstboot.sh` reads it as raw text via IMDSv2's
   `/latest/user-data`).
   - If your launch path can't set user-data (or you're in an enclave where
     the user-data channel is restricted/stripped), instead place the same
     content at `/etc/ironlog/appliance.conf` on the instance before first
     boot (e.g. via a custom AMI overlay, EC2 Image Builder step, or an SSM
     document run before the `ironlog-firstboot.service` unit fires).
3. Boot. `ironlog-firstboot.service` runs once, automatically, ordered
   before every `ironlog-*.service` (see "Ordering" below). On success it
   writes `/etc/ironlog/.firstboot-complete` and the stack for your chosen
   mode comes up.
4. Verify: `systemctl status 'ironlog-*.service'`, `podman ps`,
   `journalctl -u ironlog-firstboot.service`.

## Input: user-data vs. `appliance.conf`

Both are the same `KEY=VALUE` line format (see `appliance.conf.example` for
the full annotated list). `ironlog-firstboot.sh` tries EC2 user-data first
(via IMDSv2 — token-required, no IMDSv1 fallback, per STIG); if that's empty
or unreachable, it falls back to `/etc/ironlog/appliance.conf`. Lines are
parsed directly (never `source`d/`eval`d), so a malformed or hostile value
can't execute code on the appliance.

Every value is a URI (`ssm://`, `asm://`, `file://`, `generate:<bytes>`) or
a literal used as-is. Scheme matching is by exact prefix, not a generic
`scheme://` regex — so a literal like `KC_HOSTNAME=http://keycloak:8080`
(a normal, valid value) is never misparsed as an unsupported scheme.

## The three modes

- **`oidc`** — on-box Keycloak, the full stack as documented in the
  top-level `README.md`/`CLAUDE.md`. Everything works: Grafana OIDC login,
  HyperDX behind the oauth2-proxy SSO gate. This is the only mode the
  current `quadlets/` units actually implement end-to-end.
- **`ldap`** — intended to mean ClickHouse LDAP external directory +
  Grafana against LDAP. **Not implementable by this worker without editing
  `quadlets/`, which was out of scope.** See "ldap / local mode
  limitations" below.
- **`local`** — intended to mean no external IdP at all. **Same limitation
  as `ldap`.**

In `ldap`/`local` mode, first boot still brings up ClickHouse and the
always-on Vector aggregator (`ironlog-vector-hosts`, Linux/K8s log
ingestion) — those don't depend on the auth mode — but leaves Keycloak,
Grafana, HyperDX, and the HyperDX oauth2-proxy gate **disabled**, and writes
`/etc/ironlog/MODE_WARNING.txt` explaining why. Log collection and storage
work; there is no web UI until you either switch to `oidc` mode or someone
extends the quadlets to support LDAP/local auth.

## The HyperDX auth conflict — decision and reasoning

OSS HyperDX has no native SSO. Its only auth is
`ironlog-hyperdx-auth.container` (oauth2-proxy) enforcing Keycloak OIDC +
TOTP in front of the unpublished `ironlog-hyperdx.container`. In `ldap`/
`local` mode there is no Keycloak — running HyperDX anyway would mean an
**unauthenticated UI with SELECT access to the entire SIEM** (it reads
`siem.*` as `svc_hyperdx`).

Two options were on the table: leave HyperDX+oauth2-proxy stopped/disabled,
or bind HyperDX to loopback so it's reachable only via an SSH tunnel. **This
script leaves them disabled**, for a reason beyond preference: this worker
was explicitly told not to edit `quadlets/`, and
`ironlog-hyperdx-auth.container` hardcodes `PublishPort=8081:4180` as a
literal in the checked-in unit file — there is no environment-variable hook
first boot can use to change that to a loopback-only bind without editing
the quadlet itself. Disabling the unit entirely was the only option
actually available from `scripts/firstboot/`. **This is a decision the
operator should confirm** — if loopback-only HyperDX access is preferred
over full disablement, `ironlog-hyperdx-auth.container`'s `PublishPort=`
needs to change to `127.0.0.1:8081:4180`, which is a `quadlets/` edit
outside this worker's scope.

## `ldap` / `local` mode limitations (conflict found, not fixed)

Beyond the HyperDX issue above, the conflict runs deeper:
`ironlog-grafana.container` hardcodes `GF_AUTH_GENERIC_OAUTH_ENABLED=true`,
`GF_AUTH_DISABLE_LOGIN_FORM=true`, and `GF_AUTH_BASIC_ENABLED=false` as
literal `Environment=` values (not sourced from `ironlog.env`), and
`ironlog-keycloak.container`/ClickHouse's baked `users.d/00-lockdown.xml`
have no LDAP directive surfaced anywhere first boot can reach. Concretely:
**Grafana as currently packaged only knows how to authenticate against
Keycloak.** There is no quadlet-level LDAP or local-auth support to enable
at all right now — `ldap` and `local` are only placeholders in this
script's mode switch until someone adds that support to `quadlets/` (and
possibly a ClickHouse LDAP config file baked at `/opt/ironlog/clickhouse/
config.d/`, which isn't part of the current file list either). Flagging
this here rather than attempting a partial fix that would only mask the gap.

## Container uid/gid values used, and their verification status

No podman is available on the machine this was written on, so every value
below is **reasoned from each image's well-documented default user, not
independently verified**. Confirm with `podman run --rm --entrypoint id
<image>` on a real host before trusting in production — a wrong value here
means the container fails closed (permission denied on its own data
directory) rather than a silent security gap, but it will block first boot.

| Directory | Image | uid:gid used | Basis |
|---|---|---|---|
| `/var/lib/ironlog/clickhouse` | `clickhouse/clickhouse-server:24.8` | `101:101` | official image's "clickhouse" system user |
| `/var/lib/ironlog/keycloak-db` | `postgres:16-alpine` | `70:70` | Alpine's "postgres" user numbering |
| `/var/lib/ironlog/grafana` | `grafana/grafana-oss:11.4.0` | `472:472` | Grafana's well-known conventional uid/gid |
| `/var/lib/ironlog/hyperdx-db` | `mongo:7.0` (debian-based) | `999:999` | official image's "mongodb" user |
| `/var/lib/ironlog/vector-hosts-buffer`, `/var/lib/ironlog/vector-buffer` | `timberio/vector:0.57.0-debian` | `0:0` | Vector's debian image runs as root by default (least confidence of the five — please verify first) |

SELinux: every writable `Volume=` line in the quadlets already carries the
`:Z` relabel flag, which podman applies automatically at container start.
First boot only needs to get ownership right; it does not run
`restorecon`/`chcon` itself.

`/var/lib/ironlog` itself is **not** mounted by this script — that's
`scripts/ami/00-partition.sh`'s job (the data EBS volume, per
`packer/README.md` "Disk layout"). First boot only verifies the mountpoint
exists (`findmnt`) and fails closed if it doesn't, rather than silently
writing container state onto the root volume.

## Enabling `ironlog-vector.service` (AWS ingestion)

`ironlog-vector.container` ships with no `[Install]` section (see
`quadlets/README.md`), so a plain `systemctl enable` has nothing to
symlink. First boot enables it only when at least one `SQS_URL_*` value
resolves to something non-empty, by writing a **runtime-only** drop-in
(`/etc/systemd/system/ironlog-vector.service.d/20-firstboot-install.conf`,
generated on the instance — not part of the repo) that adds an `[Install]`
section, then `systemctl enable --now`s it. If no `SQS_URL_*` is
configured, the unit is left exactly as shipped: present, but not started
and not enabled.

## Ordering, without editing `quadlets/`

None of the `ironlog-*.container` units declare `After=`/
`Requires=ironlog-firstboot.service` (they can't — editing `quadlets/` was
out of scope for this worker). `ironlog-firstboot.service`'s own `[Unit]
Before=` list orders it ahead of every `ironlog-*.service` (systemd
ordering is symmetric — `Before=` on our unit is equivalent to `After=` on
theirs), but `Before=` alone is only ordering, not a dependency: a failed
first boot wouldn't stop the others from starting anyway.

To make the gate real without touching the repo's `quadlets/` tree, the
script itself writes a small **runtime-only** drop-in onto each known
`ironlog-*.service`
(`/etc/systemd/system/<unit>.d/10-firstboot-order.conf`, generated fresh on
the appliance, not committed anywhere) adding `Requires=` +
`After=ironlog-firstboot.service`. A failed first boot now genuinely blocks
every other ironlog unit from starting with a missing/stale `ironlog.env`.

## Idempotency / re-runs

`/etc/ironlog/.firstboot-complete` is the sentinel; both the systemd unit
(`ConditionPathExists=!.../.firstboot-complete`) and the script itself
check it, so a reboot is a no-op. To force a full re-run (e.g. after fixing
a broken `appliance.conf`):

```sh
sudo rm -f /etc/ironlog/.firstboot-complete
sudo IRONLOG_FIRSTBOOT_FORCE=1 systemctl restart ironlog-firstboot.service
```

`OAUTH2_PROXY_COOKIE_SECRET` (and any other `generate:` value) is
**persisted** under `/etc/ironlog/generated/<VARNAME>.secret` and reused on
every re-run — it does not regenerate on a forced re-run or reboot, which
matters because a changed cookie secret invalidates every live session. To
deliberately rotate a generated secret, delete its specific file under
`/etc/ironlog/generated/` before forcing a re-run — do not delete the whole
directory unless you intend to rotate everything in it.

## Recovery from a failed first boot

First boot fails closed: if any *required* value can't be resolved, no
`/etc/ironlog/ironlog.env` is written at all (built in a temp file, moved
into place only on full success) and the sentinel is never created — no
`ironlog-*.service` can start with a blank/default credential, because of
the `Requires=` drop-ins described above.

1. `journalctl -u ironlog-firstboot.service` — the failure is logged loudly
   (`FATAL: ...`) with which variable/URI failed to resolve.
2. Fix the cause — usually a wrong `ssm://`/`asm://` path, missing IAM
   permission on the instance role, or IMDS being blocked by an overly
   strict hop-limit/security-group setting.
3. Re-run per "Idempotency / re-runs" above.
4. If the failure was mid-way through a *previous partial success* (should
   not happen — the env file write is atomic — but if `/etc/ironlog/
   ironlog.env` looks suspicious), just re-run; it's fully idempotent and
   safe to run repeatedly.

## What was reasoned vs. tested

Nothing in this directory was run against real EC2/IMDS/SSM/Secrets
Manager, and no podman/systemd was available to exercise the quadlet
ordering or the drop-in mechanism — none of that is claimed as tested.
What was actually done:
- `bash -n` on every `.sh` file (see below for results).
- Cross-referenced every variable name against `.env.example` and every
  `Environment=`/`Volume=` line in all nine `quadlets/*.container` files
  plus `quadlets/ironlog.network`, by reading them directly (not from
  memory) — see the tables above.
- The uid/gid table is reasoned from each image's documented default user,
  explicitly flagged as unverified.
- The systemd `Before=`/runtime-drop-in ordering mechanism is standard,
  documented systemd behavior (`systemd.unit(5)` on ordering symmetry;
  drop-ins may add `[Install]` sections), not something specific to
  quadlets, but was not exercised on a live system.

## Known conflicts with `quadlets/`/`packer/` (reported, not fixed)

1. **`OAUTH2_PROXY_REDIRECT_URL`, `FRONTEND_URL`, `OAUTH2_PROXY_COOKIE_SECURE`
   are hardcoded `localhost`/`false` literals** in `ironlog-hyperdx.container`
   and `ironlog-hyperdx-auth.container` — not sourced from `ironlog.env` at
   all. This script derives `KC_HOSTNAME`/`KC_PUBLIC_URL`/`GRAFANA_ROOT_URL`
   from the operator's FQDN as instructed (those three ARE wired via `$VAR`
   substitution in the quadlets), but has **no way** to do the same for
   HyperDX's redirect URL or cookie security flag, because the quadlet units
   don't reference a variable for them. Practical effect: even in `oidc`
   mode, HyperDX's OIDC callback is only reachable at
   `http://localhost:8081/oauth2/callback` — real, non-tunnelled browser
   access to HyperDX at the appliance's FQDN will not complete login, and
   the cookie is never marked `Secure` even when the rest of the appliance
   is served over TLS. Fixing this needs `ironlog-hyperdx-auth.container`'s
   `OAUTH2_PROXY_REDIRECT_URL`/`OAUTH2_PROXY_COOKIE_SECURE` and
   `ironlog-hyperdx.container`'s `FRONTEND_URL` changed to `$VAR`
   substitutions from `ironlog.env` (e.g. new `HYPERDX_PUBLIC_URL` /
   `APPLIANCE_TLS`-derived vars) — a `quadlets/` edit, out of scope here.
   Until fixed, reach HyperDX via `ssh -L 8081:localhost:8081 <appliance>`
   and browse to `http://localhost:8081`.
2. **`ldap`/`local` auth modes have no quadlet-level implementation at
   all** — see "ldap / local mode limitations" above.
3. No other conflicts found: every `.env.example` variable name is
   referenced verbatim by at least one quadlet's `Environment=` (directly or
   via `$VAR` rename), and every writable `Volume=` target under
   `/var/lib/ironlog/` has a corresponding directory created here.

## Testing this directory

```sh
bash -n scripts/firstboot/ironlog-firstboot.sh
bash -n scripts/firstboot/secret-resolver.sh
shellcheck scripts/firstboot/*.sh   # if installed
```

`secret-resolver.sh` can be exercised standalone, without the rest of first
boot, e.g.:

```sh
./secret-resolver.sh resolve 'file:///etc/hostname'
./secret-resolver.sh resolve 'generate:32' MY_TEST_VAR   # persists under $IRONLOG_GENERATED_DIR
./secret-resolver.sh resolve 'literal-value-here'
./secret-resolver.sh region
```
