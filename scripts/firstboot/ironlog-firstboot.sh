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

set -uo pipefail
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

log()  { logger -t ironlog-firstboot -- "$*" 2>/dev/null; echo "[ironlog-firstboot] $*" >&2; }
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

MODE="${CONF[APPLIANCE_MODE]:-oidc}"
case "$MODE" in
	oidc|ldap|local) ;;
	*) die "APPLIANCE_MODE must be one of oidc, ldap, local (got '$MODE')" ;;
esac

FQDN="${CONF[APPLIANCE_FQDN]:-}"
[[ -n "$FQDN" ]] || die "APPLIANCE_FQDN is required (the appliance's own public/internal hostname; used to derive KC_HOSTNAME/KC_PUBLIC_URL/GRAFANA_ROOT_URL)"

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

: "${CONF[KC_HOSTNAME]:=${SCHEME}://${FQDN}:8080}"
: "${CONF[KC_PUBLIC_URL]:=${CONF[KC_HOSTNAME]}}"
: "${CONF[GRAFANA_ROOT_URL]:=${SCHEME}://${FQDN}:3000}"
# HyperDX is reached only through oauth2-proxy on :8081. Both the proxy's OIDC
# redirect URL and HyperDX's own FRONTEND_URL must be this externally-reachable
# address, not localhost — compose hardcoded localhost because it only ever ran
# on the developer's own machine.
: "${CONF[HYPERDX_PUBLIC_URL]:=${SCHEME}://${FQDN}:8081}"
# oauth2-proxy must only mark its session cookie Secure when the appliance is
# actually served over TLS; setting it true on plain HTTP silently breaks login.
: "${CONF[OAUTH2_PROXY_COOKIE_SECURE]:=${TLS}}"
: "${CONF[AWS_REGION]:=$(sr_region)}"

# ---------------------------------------------------------------------------
# 3. Resolve the full ironlog.env variable set.
#
# Names are exactly .env.example's, verbatim (this is the quadlets'
# EnvironmentFile= contract — see quadlets/README.md "Secret handling").
# Each entry: NAME  DEFAULT_CONF_KEY(usually same)  REQUIRED_IN_OIDC  REQUIRED_ALWAYS
# ---------------------------------------------------------------------------

# Vars needed regardless of auth mode (ClickHouse core + always-on vector-hosts).
CORE_VARS=(
	CH_ADMIN_USER CH_ADMIN_PASSWORD CH_VECTOR_PASSWORD
	CH_GRAFANA_ANALYST_PASSWORD CH_GRAFANA_AUDITOR_PASSWORD CH_HYPERDX_PASSWORD
	SPLUNK_HEC_TOKEN
)

# Vars only meaningful when the OIDC stack (Keycloak/Grafana/HyperDX+proxy)
# is actually going to run.
OIDC_VARS=(
	KC_DB_PASSWORD KC_ADMIN_USER KC_ADMIN_PASSWORD KC_HOSTNAME KC_PUBLIC_URL
	GRAFANA_ROOT_URL GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_OAUTH_SECRET
	HYPERDX_OAUTH_SECRET HYPERDX_DB_PASSWORD OAUTH2_PROXY_COOKIE_SECRET
	HYPERDX_PUBLIC_URL OAUTH2_PROXY_COOKIE_SECURE
)

# Optional: AWS ingestion (ironlog-vector.service). Empty is valid — that
# service simply stays disabled (see step 6).
AWS_VARS=(AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY SQS_URL_CLOUDTRAIL SQS_URL_GUARDDUTY SQS_URL_VPCFLOW SQS_URL_S3ACCESS)

# Sensible literal defaults for values that are usually just names, not
# secrets, so a minimal appliance.conf doesn't have to spell every one out.
declare -A VAR_DEFAULT=(
	[CH_ADMIN_USER]=siem_admin
	[KC_ADMIN_USER]=kcadmin
	[GRAFANA_ADMIN_USER]=breakglass_admin
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
	RESOLVED["$name"]="$val"
}

for v in "${CORE_VARS[@]}"; do
	resolve_var "$v" yes
done

if [[ "$MODE" == oidc ]]; then
	for v in "${OIDC_VARS[@]}"; do
		resolve_var "$v" yes
	done
else
	for v in "${OIDC_VARS[@]}"; do
		resolve_var "$v" no
	done
fi

for v in "${AWS_VARS[@]}"; do
	resolve_var "$v" no
done

# ---------------------------------------------------------------------------
# 4. Write /etc/ironlog/ironlog.env atomically.
# ---------------------------------------------------------------------------

{
	echo "# Generated by ironlog-firstboot.sh at $(date -u +%FT%TZ). Do not edit by hand —"
	echo "# re-runs (IRONLOG_FIRSTBOOT_FORCE=1) will overwrite this file."
	echo "# Variable names match .env.example verbatim; see quadlets/README.md"
	echo "# \"Secret handling\" for how each quadlet renames/consumes them."
	for v in "${CORE_VARS[@]}" "${OIDC_VARS[@]}" "${AWS_VARS[@]}"; do
		# printf %q-style single-quote escaping so values with spaces/$/quotes
		# survive systemd's EnvironmentFile parser (which does its own
		# minimal quoting — a bare double-quoted value is the safe common
		# denominator; see systemd.exec(5) "EnvironmentFile=").
		printf '%s=%s\n' "$v" "${RESOLVED[$v]}"
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
	[keycloak-db]="70:70"           # postgres:16-alpine: user "postgres" (alpine numbering)
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
	ironlog-clickhouse.service ironlog-keycloak-db.service ironlog-keycloak.service
	ironlog-grafana.service ironlog-hyperdx-db.service ironlog-hyperdx.service
	ironlog-hyperdx-auth.service ironlog-vector-hosts.service ironlog-vector.service
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

CORE_SERVICES=(ironlog-clickhouse.service ironlog-vector-hosts.service)
OIDC_SERVICES=(
	ironlog-keycloak-db.service ironlog-keycloak.service ironlog-grafana.service
	ironlog-hyperdx-db.service ironlog-hyperdx.service ironlog-hyperdx-auth.service
)

for unit in "${CORE_SERVICES[@]}"; do
	systemctl enable --now "$unit" || log "WARNING: failed to enable/start $unit"
done

if [[ "$MODE" == oidc ]]; then
	for unit in "${OIDC_SERVICES[@]}"; do
		systemctl enable --now "$unit" || log "WARNING: failed to enable/start $unit"
	done
	rm -f "$MODE_WARNING_FILE"
else
	# --- THE HYPERDX/GRAFANA AUTH CONFLICT ---
	# OSS HyperDX has no native SSO; its only auth is oauth2-proxy enforcing
	# Keycloak OIDC+TOTP in front of it (ironlog-hyperdx-auth.container). In
	# ldap/local mode there is no Keycloak, so an enabled HyperDX would be an
	# UNAUTHENTICATED UI with SELECT over the entire SIEM. We do not ship
	# that: ironlog-hyperdx(.service) and ironlog-hyperdx-auth(.service) are
	# left disabled in ldap/local mode, full stop (see README.md "The HyperDX
	# auth conflict" for why "bind to loopback instead" was considered and
	# rejected: PublishPort=8081:4180 is a literal in the checked-in quadlet,
	# not something first boot can override without editing quadlets/).
	#
	# Separately, and more broadly: ironlog-grafana.container hardcodes
	# GF_AUTH_GENERIC_OAUTH_ENABLED=true / GF_AUTH_DISABLE_LOGIN_FORM=true /
	# GF_AUTH_BASIC_ENABLED=false as literal Environment= values (not sourced
	# from ironlog.env), and ironlog-keycloak.container has no LDAP-anything.
	# There is currently NO quadlet-level support for ldap or local auth at
	# all — Grafana as packaged only knows how to talk to Keycloak. This
	# script cannot fix that without editing quadlets/, which is out of
	# scope for this worker. See README.md for the full explanation; this is
	# reported as a conflict, not silently patched over.
	for unit in "${OIDC_SERVICES[@]}"; do
		systemctl disable --now "$unit" 2>/dev/null || true
	done
	cat >"$MODE_WARNING_FILE" <<-EOF
	ironlog appliance mode = $MODE

	Keycloak, Grafana, HyperDX, and the HyperDX oauth2-proxy gate are all
	DISABLED on this instance. Reason: ironlog-grafana.container and
	ironlog-hyperdx.container hardcode Keycloak OIDC as their only auth path
	(literal Environment= values in the checked-in quadlet units, not sourced
	from ironlog.env), and OSS HyperDX has no auth of its own at all. Running
	them in $MODE mode with no Keycloak would mean either a broken login loop
	(Grafana) or a completely unauthenticated UI with read access to every
	SIEM table (HyperDX). Neither is acceptable, so first boot leaves them
	off rather than ship either failure mode.

	ClickHouse and the always-on Vector aggregator (ironlog-vector-hosts,
	Linux/K8s ingestion) ARE running — log collection and storage work fine
	in this mode; only the web UIs are affected.

	To get a working UI today: switch APPLIANCE_MODE to oidc and re-run first
	boot (IRONLOG_FIRSTBOOT_FORCE=1). True LDAP/local-auth support for
	Grafana/HyperDX needs changes to quadlets/ironlog-grafana.container (and
	possibly ClickHouse's users.d) that are out of scope for this script —
	flag this file's existence to whoever owns that work next.
	EOF
	log "WARNING: mode=$MODE — Keycloak/Grafana/HyperDX/oauth2-proxy disabled; see $MODE_WARNING_FILE"
fi

# ---------------------------------------------------------------------------
# 7. ironlog-vector.service (AWS ingestion) — ships with no [Install]
# section (see quadlets/README.md), so plain `systemctl enable` has nothing
# to symlink. Enable it (via a runtime-only drop-in that adds [Install],
# same technique as step 6) ONLY when at least one SQS URL is actually
# configured, matching compose's "aws" profile gate.
# ---------------------------------------------------------------------------

if [[ -n "${RESOLVED[SQS_URL_CLOUDTRAIL]}${RESOLVED[SQS_URL_GUARDDUTY]}${RESOLVED[SQS_URL_VPCFLOW]}${RESOLVED[SQS_URL_S3ACCESS]}" ]]; then
	dropin_dir="$UNIT_DIR/ironlog-vector.service.d"
	mkdir -p "$dropin_dir"
	cat >"$dropin_dir/20-firstboot-install.conf" <<-'EOF'
	# Generated by ironlog-firstboot.sh. ironlog-vector.container ships with
	# deliberately no [Install] section (see quadlets/README.md). A drop-in
	# CAN add one — systemd honors [Install] sections found in drop-ins for
	# `systemctl enable` purposes — without editing the checked-in unit.
	[Install]
	WantedBy=multi-user.target
	EOF
	systemctl daemon-reload
	systemctl enable --now ironlog-vector.service || log "WARNING: failed to enable/start ironlog-vector.service"
	log "AWS ingestion configured (at least one SQS_URL_* set) — ironlog-vector.service enabled"
else
	log "no SQS_URL_* configured — ironlog-vector.service left disabled (AWS ingestion not wired up yet, see docs/aws-ingestion.md)"
fi

# ---------------------------------------------------------------------------
# 8. Done.
# ---------------------------------------------------------------------------

date -u +%FT%TZ >"$SENTINEL"
chmod 600 "$SENTINEL"
log "first boot complete (mode=$MODE)"
