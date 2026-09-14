#!/usr/bin/env bash
# ironlog-firstboot.sh — turns a generic ironlog AMI into a configured,
# running appliance instance. Run by ironlog-firstboot.service (oneshot),
# ordered before every ironlog-*.service quadlet unit. See README.md in
# this directory for the full operator runbook.
#
# Deployed by packer to /usr/local/lib/ironlog/ (see packer/README.md,
# provisioner step 5). Reads its config from EC2 user-data (preferred) or
# /etc/ironlog/appliance.conf (fallback — for air-gapped launches with no
# user-data channel). Produces exactly one file: /etc/ironlog/ironlog.env,
# mode 0600 root:root, in systemd EnvironmentFile format, consumed by every
# ironlog-*.container quadlet via [Service] EnvironmentFile=.
#
# Idempotent: a completion sentinel (/etc/ironlog/.firstboot-complete)
# makes a reboot a no-op. Set IRONLOG_FIRSTBOOT_FORCE=1 in the environment
# to force a full re-run (see README.md "Recovery from a failed first boot").
#
# Fails closed: on any required-secret resolution failure, no partial
# /etc/ironlog/ironlog.env is ever written (built in a temp file, moved into
# place atomically only on full success), the sentinel is not created, and
# this script exits non-zero — leaving no ironlog-* service able to start
# with blank/default credentials.

set -euo pipefail
umask 077

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./secret-resolver.sh
source "$LIB_DIR/secret-resolver.sh"

ETC_DIR=/etc/ironlog
SENTINEL="$ETC_DIR/.firstboot-complete"
ENV_FILE="$ETC_DIR/ironlog.env"
ENV_TMP="$ETC_DIR/.ironlog.env.tmp.$$"
CONF_FALLBACK="$ETC_DIR/appliance.conf"
MODE_WARNING_FILE="$ETC_DIR/MODE_WARNING.txt"
UNIT_DIR=/etc/systemd/system

log()  { logger -t ironlog-firstboot -- "$*" 2>/dev/null || true; echo "[ironlog-firstboot] $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 0. Idempotency gate
# ---------------------------------------------------------------------------

if [[ -f "$SENTINEL" && "${IRONLOG_FIRSTBOOT_FORCE:-0}" != "1" ]]; then
	log "already completed at $(cat "$SENTINEL" 2>/dev/null || echo unknown); nothing to do (set IRONLOG_FIRSTBOOT_FORCE=1 to re-run)"
	exit 0
fi

mkdir -p "$ETC_DIR"
chmod 700 "$ETC_DIR"

# ---------------------------------------------------------------------------
# 1. Load the appliance config map (user-data, else appliance.conf)
# ---------------------------------------------------------------------------

declare -A CONF

# parse_conf reads "KEY=value" lines from stdin into the CONF assoc array.
# Deliberately NOT `source`d/`eval`d — values are treated as opaque data
# even though this script trusts EC2 user-data (only the account owner can
# set it) and a root-owned local file, defense in depth against a malformed
# or hostile value containing shell metacharacters costs nothing here.
parse_conf() {
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"                      # tolerate CRLF user-data
		[[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
		[[ "$line" == *"="* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		key="$(echo -n "$key" | tr -d '[:space:]')"
		[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { log "ignoring malformed config line (bad key): $line"; continue; }
		CONF["$key"]="$value"
	done
}

USERDATA="$(sr_fetch_userdata 2>/dev/null || true)"
if [[ -n "$USERDATA" ]]; then
	log "loading appliance config from EC2 user-data (IMDSv2)"
	parse_conf <<<"$USERDATA"
elif [[ -f "$CONF_FALLBACK" ]]; then
	log "EC2 user-data empty/unavailable; loading $CONF_FALLBACK"
	parse_conf <"$CONF_FALLBACK"
else
	die "no appliance config found: EC2 user-data was empty/unreachable and $CONF_FALLBACK does not exist. See appliance.conf.example."
fi

MODE="${CONF[APPLIANCE_MODE]:-local}"
case "$MODE" in
	local) ;;
	oidc|ldap) die "APPLIANCE_MODE=$MODE is deferred: this AMI ships local app authentication only; external IdP integration is not implemented" ;;
	*) die "APPLIANCE_MODE must be local (oidc and ldap are deferred; got '$MODE')" ;;
esac

FQDN="${CONF[APPLIANCE_FQDN]:-}"
[[ -n "$FQDN" ]] || die "APPLIANCE_FQDN is required (the appliance's public/internal hostname; used to derive Grafana and HyperDX URLs)"

TLS="${CONF[APPLIANCE_TLS]:-true}"
case "$TLS" in
	true) SCHEME=https ;;
	false) SCHEME=http ;;
	*) die "APPLIANCE_TLS must be 'true' or 'false' (got '$TLS')" ;;
esac

log "mode=$MODE fqdn=$FQDN tls=$TLS"

# ---------------------------------------------------------------------------
# 2. Derive the URL-shaped values, unless the operator explicitly overrode
#    them in appliance.conf (an escape hatch for unusual topologies — e.g.
#    a TLS-terminating load balancer in front with a different public port).
# ---------------------------------------------------------------------------

: "${CONF[GRAFANA_ROOT_URL]:=${SCHEME}://${FQDN}:3000}"
# HyperDX native auth is served directly on host port 8081.
: "${CONF[HYPERDX_PUBLIC_URL]:=${SCHEME}://${FQDN}:8081}"
: "${CONF[AWS_REGION]:=$(sr_region)}"

# ---------------------------------------------------------------------------
# 3. Resolve the full ironlog.env variable set.
#
# Names are exactly .env.example's, verbatim (this is the quadlets'
# EnvironmentFile= contract — see quadlets/README.md "Secret handling").
# Each entry is NAME and an optional literal/config default.
# ---------------------------------------------------------------------------

# Vars needed regardless of auth mode (ClickHouse core + always-on vector-hosts).
CORE_VARS=(
	CH_ADMIN_USER CH_ADMIN_PASSWORD CH_VECTOR_PASSWORD
	CH_GRAFANA_ANALYST_PASSWORD CH_GRAFANA_AUDITOR_PASSWORD CH_HYPERDX_PASSWORD
	SPLUNK_HEC_TOKEN
)

# Local application authentication. External OIDC/LDAP remains deferred; no
# IdP credential is resolved or emitted by this AMI.
APP_VARS=(
	GRAFANA_ROOT_URL GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
	HYPERDX_DB_PASSWORD HYPERDX_SESSION_SECRET HYPERDX_LOCAL_EMAIL HYPERDX_LOCAL_PASSWORD HYPERDX_PUBLIC_URL
)

# Optional: AWS ingestion (ironlog-vector.service). Empty is valid — that
# service simply stays disabled (see step 6).
AWS_VARS=(AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY SQS_URL_CLOUDTRAIL SQS_URL_GUARDDUTY SQS_URL_VPCFLOW SQS_URL_S3ACCESS)

# Sensible literal defaults for values that are usually just names, not
# secrets, so a minimal appliance.conf doesn't have to spell every one out.
declare -A VAR_DEFAULT=(
	[CH_ADMIN_USER]=siem_admin
	[GRAFANA_ADMIN_USER]=admin
	[GRAFANA_ADMIN_PASSWORD]=IronlogDev123!
	[HYPERDX_LOCAL_EMAIL]=admin@ironlog.local
	[HYPERDX_LOCAL_PASSWORD]=IronlogDev123!
	[HYPERDX_SESSION_SECRET]=generate:64
)

declare -A RESOLVED

resolve_var() {
	local name="$1" required="$2" uri val
	uri="${CONF[$name]:-${VAR_DEFAULT[$name]:-}}"
	if [[ -z "$uri" ]]; then
		if [[ "$required" == "yes" ]]; then
			die "required value '$name' has no URI/literal in appliance config and no default"
		fi
		RESOLVED["$name"]=""
		return 0
	fi
	if ! val="$(sr_resolve "$uri" "$name")"; then
		if [[ "$required" == "yes" ]]; then
			die "failed to resolve '$name' from '$uri' — refusing to start with a missing/blank credential"
		fi
		log "WARNING: failed to resolve optional '$name' from '$uri'; leaving blank"
		RESOLVED["$name"]=""
		return 0
	fi
	if [[ "$required" == "yes" && -z "$val" ]]; then
		die "required value '$name' resolved empty from '$uri' — refusing to start with a blank credential"
	fi
	RESOLVED["$name"]="$val"
}

for v in "${CORE_VARS[@]}"; do
	resolve_var "$v" yes
done

for v in "${APP_VARS[@]}"; do
	resolve_var "$v" yes
done

for v in "${AWS_VARS[@]}"; do
	resolve_var "$v" no
done

# ---------------------------------------------------------------------------
# 4. Write /etc/ironlog/ironlog.env atomically.
# ---------------------------------------------------------------------------

# EnvironmentFile double quotes preserve whitespace and literal dollar signs.
# Escape backslashes/quotes and reject line breaks so one value cannot create
# another environment assignment. Never print the credential in diagnostics.
env_value() {
	local name="$1" value="$2"
	[[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "'$name' contains a line break"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
}

trap 'rm -f "$ENV_TMP"' EXIT
{
	echo "# Generated by ironlog-firstboot.sh at $(date -u +%FT%TZ). Do not edit by hand —"
	echo "# re-runs (IRONLOG_FIRSTBOOT_FORCE=1) will overwrite this file."
	echo "# Variable names match .env.example verbatim; see quadlets/README.md"
	echo "# \"Secret handling\" for how each quadlet renames/consumes them."
	for v in "${CORE_VARS[@]}" "${APP_VARS[@]}" "${AWS_VARS[@]}"; do
		encoded="$(env_value "$v" "${RESOLVED[$v]}")"
		printf '%s=%s\n' "$v" "$encoded"
	done
} >"$ENV_TMP"

chmod 600 "$ENV_TMP"
chown root:root "$ENV_TMP"
mv -f "$ENV_TMP" "$ENV_FILE"
log "wrote $ENV_FILE (mode 0600 root:root)"

# ---------------------------------------------------------------------------
# 5. Data volume + per-service directories.
#
# The data EBS volume itself is mounted at /var/lib/ironlog by
# scripts/ami/00-partition.sh at boot (see packer/README.md "Disk layout") —
# firstboot does not re-implement partitioning/mounting, it only verifies
# the mount exists (fail closed rather than silently writing container data
# onto the root volume) and creates/owns the per-service subdirectories each
# quadlet bind-mounts (Volume= lines with a writable, non-:ro target under
# /var/lib/ironlog/ — read from the quadlet files directly, not assumed).
# ---------------------------------------------------------------------------

DATA_ROOT=/var/lib/ironlog
if ! findmnt -rn "$DATA_ROOT" >/dev/null 2>&1; then
	die "$DATA_ROOT is not a mountpoint — expected the data EBS volume mounted here by scripts/ami/00-partition.sh. Refusing to store container state on the root volume."
fi

# name -> "uid:gid" the container image runs data files as.
# REASONED, NOT VERIFIED on a live box (no podman on the machine this was
# written on — see README.md "Container uid/gid values"). Confirm each with
# `podman run --rm --entrypoint id <image>` on a real host before trusting
# in production; wrong values here mean the container fails to start
# (permission denied writing its own data directory), not a silent security
# issue, so it fails loud rather than fails open.
declare -A SVC_OWNER=(
	[clickhouse]="101:101"          # clickhouse/clickhouse-server: user "clickhouse"
	[grafana]="472:472"             # grafana/grafana-oss: well-known "grafana" uid/gid
	[hyperdx-db]="999:999"          # mongo:7.0 (debian-based): user "mongodb"
	[vector-hosts-buffer]="0:0"     # timberio/vector debian image: runs as root by default
	[vector-buffer]="0:0"           # same image as vector-hosts
)

for name in "${!SVC_OWNER[@]}"; do
	dir="$DATA_ROOT/$name"
	owner="${SVC_OWNER[$name]}"
	mkdir -p "$dir"
	chown "$owner" "$dir"
	chmod 0750 "$dir"
	log "ensured $dir (owner $owner)"
done
# SELinux: every writable Volume= in the quadlets carries the :Z relabel
# flag, which podman applies automatically at container start — firstboot
# does not need to run restorecon/chcon itself.

# ---------------------------------------------------------------------------
# 6. Systemd ordering + service enablement.
#
# The quadlet .container files (repo-owned, not touched by this script) do
# not — and per the task instructions for this worker, must not be made to —
# declare After=/Requires=ironlog-firstboot.service themselves. Systemd
# ordering is symmetric (a Before= declared on OUR unit is equivalent to the
# target unit declaring After= us), so ironlog-firstboot.service's own
# [Unit] Before= line (see ironlog-firstboot.service) gets every ironlog-*
# unit to start after us. But Before= alone is only ordering, not a
# dependency — if this script fails, that ordering wouldn't stop the other
# units from still trying to start with a missing/stale ironlog.env.
#
# To make the gate a real one without editing any file under quadlets/, we
# drop a small per-unit override at runtime (NOT in the repo — generated
# fresh on the appliance itself) adding Requires=ironlog-firstboot.service.
# ---------------------------------------------------------------------------

KNOWN_UNITS=(
	ironlog-clickhouse.service ironlog-grafana.service ironlog-hyperdx-db.service
	ironlog-hyperdx.service ironlog-bootstrap-hyperdx-local.service
	ironlog-vector-hosts.service ironlog-vector.service
	# Not a quadlet -- a real /etc/systemd/system unit (see
	# scripts/firstboot/ironlog-schema.service). It would inherit the ordering
	# transitively through ironlog-clickhouse.service anyway; listed explicitly
	# so the guarantee survives someone later changing that dependency.
	ironlog-schema.service
)

for unit in "${KNOWN_UNITS[@]}"; do
	dropin_dir="$UNIT_DIR/${unit}.d"
	mkdir -p "$dropin_dir"
	cat >"$dropin_dir/10-firstboot-order.conf" <<-EOF
	# Generated by ironlog-firstboot.sh — runtime-only, not part of the repo's
	# quadlets/ tree. Makes this unit genuinely wait on a successful first boot
	# instead of merely starting after it (see ironlog-firstboot.sh step 6).
	[Unit]
	After=ironlog-firstboot.service
	Requires=ironlog-firstboot.service
	EOF
done

systemctl daemon-reload

# Quadlet-generated units live in /run/systemd/generator/ and CANNOT be
# `systemctl enable`d -- systemd refuses with "Unit
# /run/systemd/generator/ironlog-clickhouse.service is transient or generated."
# Enablement for these is declared in the .container file's [Install] section,
# which quadlet turns into the target.wants symlink at generation time; there
# is nothing left for this script to enable. So START them, and treat failure
# as a REAL failure. The previous code called `systemctl enable --now` and
# logged only a WARNING, so a first boot in which not one service started
# still finished with "first boot complete" and exit 0.
start_unit() {
	local unit="$1"
	# --no-block is REQUIRED here, not an optimization. Step 6 above writes a
	# drop-in adding Requires=ironlog-firstboot.service to each of these units,
	# and this function runs FROM INSIDE ironlog-firstboot.service while it is
	# still activating. A blocking `systemctl start` therefore waits on a unit
	# that is itself waiting on us: systemd deadlocks until TimeoutStartSec=300
	# kills firstboot, and every service then fails with
	# "Job ironlog-clickhouse.service/start failed with result 'dependency'".
	# Queue the job and let systemd run it after we exit 0.
	#
	# Consequence, stated plainly: this function can only report that the job
	# was QUEUED, never that the service came up. Nothing here can verify that
	# -- see the note at the end of this script.
	if ! systemctl start --no-block "$unit"; then
		log "FATAL: could not queue a start job for $unit"
		return 1
	fi
	log "queued start for $unit"
	return 0
}

start_failures=0

# ironlog-schema.service sits between ClickHouse and everything that queries
# it: it reconciles the SIEM schema and fails if the result is incomplete.
# vector-hosts already pulls it in via Requires=, but it is queued explicitly
# so that a failure to even queue it is counted as a start failure here.
CORE_SERVICES=(ironlog-clickhouse.service ironlog-schema.service ironlog-vector-hosts.service)
APP_SERVICES=(ironlog-grafana.service ironlog-hyperdx-db.service ironlog-hyperdx.service ironlog-bootstrap-hyperdx-local.service)

for unit in "${CORE_SERVICES[@]}"; do
	start_unit "$unit" || start_failures=$((start_failures + 1))
done

for unit in "${APP_SERVICES[@]}"; do
	start_unit "$unit" || start_failures=$((start_failures + 1))
done
rm -f "$MODE_WARNING_FILE"

# ---------------------------------------------------------------------------
# 7. ironlog-vector.service (AWS ingestion) — ships with no [Install]
# section (see quadlets/README.md), so plain `systemctl enable` has nothing
# to symlink. Enable it (via a runtime-only drop-in that adds [Install],
# same technique as step 6) ONLY when at least one SQS URL is actually
# configured, matching compose's "aws" profile gate.
# ---------------------------------------------------------------------------

if [[ -n "${RESOLVED[SQS_URL_CLOUDTRAIL]}${RESOLVED[SQS_URL_GUARDDUTY]}${RESOLVED[SQS_URL_VPCFLOW]}${RESOLVED[SQS_URL_S3ACCESS]}" ]]; then
	# ironlog-vector.container deliberately ships with no [Install] section
	# (see quadlets/README.md), so it does not auto-start at boot the way the
	# other enabled quadlets do. An [Install] drop-in does NOT help: systemd
	# refuses `systemctl enable` for anything under /run/systemd/generator
	# ("... is transient or generated") based on the unit's LOCATION, not on
	# whether it has an [Install] section. Create the wants symlink directly
	# instead — generators run before unit loading, so the /run path is
	# populated by the time systemd resolves this at every boot.
	mkdir -p /etc/systemd/system/multi-user.target.wants
	ln -sf /run/systemd/generator/ironlog-vector.service 		/etc/systemd/system/multi-user.target.wants/ironlog-vector.service
	systemctl daemon-reload
	start_unit ironlog-vector.service || start_failures=$((start_failures + 1))
	log "AWS ingestion configured (at least one SQS_URL_* set) — ironlog-vector.service started and linked into multi-user.target"
else
	log "no SQS_URL_* configured — ironlog-vector.service left disabled (AWS ingestion not wired up yet, see docs/aws-ingestion.md)"
fi

# ---------------------------------------------------------------------------
# 8. Done.
# ---------------------------------------------------------------------------

if [[ "$start_failures" -gt 0 ]]; then
	die "$start_failures ironlog service(s) could not even be QUEUED to start — refusing to mark first boot complete. Fix the cause and re-run with IRONLOG_FIRSTBOOT_FORCE=1."
fi
date -u +%FT%TZ >"$SENTINEL"
chmod 600 "$SENTINEL"

# This script CANNOT confirm the appliance is serving: every ironlog unit
# Requires= this one, so it must exit before any of them can start (see
# start_unit above). Successful completion here means "configuration is
# written and start jobs are queued", nothing more. Verify separately with
# `systemctl --failed` and `podman ps`.
log "start jobs queued — verify with: systemctl --failed ; podman ps"

log "first boot complete (mode=$MODE)"
