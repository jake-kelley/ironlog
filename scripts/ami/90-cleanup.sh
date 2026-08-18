#!/usr/bin/env bash
# scripts/ami/90-cleanup.sh — pre-snapshot hygiene.
#
# Runs last (packer/build.pkr.hcl step 9), right before Packer stops the
# instance and creates the AMI snapshot. Idempotent in the sense that running
# it twice is harmless, but most of what it does is one-way (there is
# nothing left to "re-clean" the second time).
set -euo pipefail

LOG_TAG="ironlog-cleanup"
log() { echo "[$LOG_TAG] $*"; }

EVIDENCE_DIR="/var/log/ironlog-build"

# --- SSH host keys ----------------------------------------------------------
# Every instance launched from this AMI must get its OWN host keys, not a
# copy of the builder instance's. cloud-init regenerates these on first boot
# via the standard ssh-keygen cloud-init module IF the keys are absent —
# removing them here is what triggers that regeneration.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
log "removed SSH host keys (regenerate at first boot via cloud-init)"

# --- cloud-init state ---------------------------------------------------
# Without this, an instance launched from the AMI would see cloud-init's
# "already ran on this instance-id" markers from the BUILDER instance and
# skip first-boot processing entirely (wrong hostname, no user-data, no
# fresh SSH keys).
if command -v cloud-init >/dev/null; then
  cloud-init clean --logs --seed || true
fi
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/data/*
log "cleared cloud-init instance state and seed"

# --- logs -----------------------------------------------------------
# Truncate (not delete — units/logrotate expect the files to exist) the
# builder session's own log noise. journald is rotated by vacuuming instead
# of touching /var/log/journal files directly.
if command -v journalctl >/dev/null; then
  journalctl --rotate || true
  journalctl --vacuum-time=1s || true
fi
find /var/log -type f \( -name '*.log' -o -name '*.log.*' \) ! -path "$EVIDENCE_DIR/*" -print0 2>/dev/null \
  | xargs -0 -r truncate -s 0
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true
: > /var/log/audit/audit.log 2>/dev/null || true
log "truncated build-time logs under /var/log (left $EVIDENCE_DIR untouched — STIG evidence)"

# --- dnf caches ----------------------------------------------------------
dnf clean all
rm -rf /var/cache/dnf/*
log "cleared dnf caches"

# --- build-time credentials --------------------------------------------
# Packer's own transient artifacts (SSH temp key material it may have
# dropped for the communicator, any staged files under /tmp from the file
# provisioners in build.pkr.hcl — those provisioners already clean up their
# own /tmp/ironlog-stage dirs, this is belt-and-braces).
rm -rf /tmp/ironlog-stage
# packer's remote_folder for every provisioner after 00-partition.sh; see
# the BUILD_SCRATCH block there for why it is not /tmp.
rm -rf /opt/ironlog-build
rm -f /root/.ssh/authorized_keys
find /home -maxdepth 2 -name authorized_keys -exec rm -f {} \; 2>/dev/null || true
rm -rf /root/.aws /home/*/.aws 2>/dev/null || true
log "removed build-time SSH authorized_keys and any stray AWS credential dirs"

# --- shell history -----------------------------------------------------
history -c 2>/dev/null || true
rm -f /root/.bash_history
find /home -maxdepth 2 -name '.bash_history' -exec rm -f {} \; 2>/dev/null || true
unset HISTFILE
log "cleared bash history"

# --- machine-id -------------------------------------------------------
# Must be regenerated per-instance (DHCP client identifiers, systemd-journal
# machine tagging, etc. all key off this). Leaving it set means every
# instance launched from the AMI would share one machine-id.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
log "cleared /etc/machine-id (regenerates at first boot)"

# --- free space zeroing -----------------------------------------------
# fstrim (not dd-zero-fill): EBS is backed by an SSD-class block device that
# supports discard, so fstrim tells the hypervisor which blocks are free —
# much faster than writing zeros across the whole disk, and it's what
# actually shrinks the resulting AMI snapshot (freed-but-never-zeroed blocks
# from deleted dnf cache / log churn otherwise still get copied into the
# snapshot).
if command -v fstrim >/dev/null; then
  fstrim -av || log "fstrim reported a non-fatal issue on at least one mount (some loop-backed STIG mounts from 00-partition.sh's fallback path may not support discard — expected, not an error)"
  log "fstrim complete"
else
  log "fstrim not available, skipping free-space discard"
fi

log "cleanup complete — instance ready for AMI snapshot. $EVIDENCE_DIR (STIG scan evidence) was preserved."
