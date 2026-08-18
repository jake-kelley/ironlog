#!/usr/bin/env bash
# scripts/ami/10-baseline.sh — dnf update, podman, base directories, chrony.
#
# Runs second (packer/build.pkr.hcl step 2), after 00-partition.sh has laid
# down /home /tmp /var /var/log /var/log/audit /var/tmp and mounted
# /var/lib/ironlog. Idempotent.
set -euo pipefail

LOG_TAG="ironlog-baseline"
log() { echo "[$LOG_TAG] $*"; }
warn() { echo "[$LOG_TAG] WARNING: $*" >&2; }

. /etc/os-release
OS_ID="$ID"
log "detected OS: $OS_ID $VERSION_ID"

# --- dnf update --------------------------------------------------------
# RHEL: subscription-manager/RHUI repos are assumed already attached by the
# base AMI (Red Hat's own cloud-access AMIs register against RHUI
# automatically on boot). We do not call subscription-manager ourselves —
# if the instance isn't entitled, `dnf update` below will simply find no
# repos and this step becomes a no-op rather than a hard failure (matches
# the "never fail merely because a step is RHEL-only" instruction — the
# inverse case, a step that's a silent no-op on an unentitled RHEL host, is
# logged clearly instead of failing).
log "running dnf update -y"
if ! dnf update -y; then
  warn "dnf update failed or found no repos (unentitled RHEL host? offline builder?) — continuing, this is not fatal to the AMI build"
fi

# --- packages ------------------------------------------------------------
PKGS=(
  podman
  podman-plugins       # netavark/aardvark-dns for the ironlog-siem bridge network
  chrony
  rsync
  lvm2
  parted
  policycoreutils      # semanage etc., needed for SELinux context work in 30-stig.sh
  audit
  openssl
)
log "installing: ${PKGS[*]}"
dnf install -y "${PKGS[@]}"

# --- directories -----------------------------------------------------------
install -d -m 0755 -o root -g root /opt/ironlog
install -d -m 0700 -o root -g root /etc/ironlog
install -d -m 0755 -o root -g root /var/lib/ironlog   # already a mount point from 00-partition.sh; harmless if it is
log "created /opt/ironlog (0755), /etc/ironlog (0700), confirmed /var/lib/ironlog"

# --- container image storage sizing -----------------------------------------
# containers-storage (overlay driver) defaults to /var/lib/containers, which
# lives on the /var LV created by 00-partition.sh (default 12 GiB — sized
# there specifically to hold the 8 pre-pulled images from
# scripts/ami/20-container-images.sh; ClickHouse and Keycloak are the two
# large ones). If an operator overrides IRONLOG_VAR_SIZE_MB down, this step
# will not catch it until 20-container-images.sh actually runs out of space —
# warn now so the signal shows up as early as possible.
avail_var_mb="$(df -Pm /var/lib/containers 2>/dev/null | tail -1 | awk '{print $4}' || df -Pm /var | tail -1 | awk '{print $4}')"
if [ -n "$avail_var_mb" ] && [ "$avail_var_mb" -lt 8192 ]; then
  warn "/var has only ${avail_var_mb}MiB free — the 8-image pull in 20-container-images.sh (ClickHouse + Keycloak are large) may not fit. See 00-partition.sh IRONLOG_VAR_SIZE_MB."
fi

mkdir -p /etc/containers
cat > /etc/containers/storage.conf <<'EOF'
# ironlog appliance container storage — overlay on /var/lib/containers
# (sized by scripts/ami/00-partition.sh's /var LV for the 8-image manifest
# in scripts/ami/20-container-images.sh).
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF
log "wrote /etc/containers/storage.conf (overlay driver, graphroot on /var)"

# --- do NOT auto-update images from a registry ------------------------------
# The appliance boots air-gapped (see 20-container-images.sh); podman must
# never try to reach a registry on its own. Two independent belt-and-braces
# controls:
#   1. no `io.containers.autoupdate` label gets set anywhere in
#      quadlets/*.container (verified: that's the other worker's file, not
#      edited here — grep it if this ever needs re-confirming) so
#      `podman auto-update` has nothing to act on even if invoked.
#   2. we do not enable/start podman-auto-update.timer, and explicitly mask
#      it so a stray `systemctl enable` later can't turn it on by accident.
systemctl mask podman-auto-update.timer >/dev/null 2>&1 || true
log "podman-auto-update.timer masked (appliance never pulls from a registry post-boot)"

# podman.socket: quadlets do not need the API socket (Quadlet talks to
# podman via ExecStart=, not the REST API), so it is deliberately left
# disabled — do not enable it here.
if systemctl is-enabled podman.socket >/dev/null 2>&1; then
  log "podman.socket already enabled by the base image; leaving as-is (not disabling something the base image chose, not enabling something quadlets don't need)"
else
  log "podman.socket not enabled (expected — quadlets don't need it)"
fi

# --- chrony (time sync) ------------------------------------------------------
# A SIEM's evidentiary value depends on event timestamps being trustworthy —
# AU-8 (Time Stamps) in docs/control-mapping.md assumes NTP-disciplined
# clocks on every agent AND the aggregator/appliance itself. Use whatever
# chrony.conf ships with the distro's chrony package (Amazon Time Sync
# Service, 169.254.169.123, is reachable from any VPC without internet
# egress and most current RHEL/Rocky cloud images already point chrony at
# it) — we only confirm the service is enabled+running, not override pool
# config that's already correct for EC2.
systemctl enable --now chronyd
if chronyc tracking >/dev/null 2>&1; then
  log "chronyd running: $(chronyc tracking 2>/dev/null | awk -F': ' '/Leap status/{print $2}')"
else
  warn "chronyc tracking failed — chronyd may not have synced yet this early in boot; this is expected on a fresh instance and should resolve within minutes, not a build failure"
fi

log "baseline provisioning complete (OS=$OS_ID)"
