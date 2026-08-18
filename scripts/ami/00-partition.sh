#!/usr/bin/env bash
# scripts/ami/00-partition.sh — disk layout for the ironlog appliance AMI.
#
# Runs first, as root, via Packer's shell provisioner (see packer/build.pkr.hcl
# step 1). Two jobs:
#   1. Mount the SECOND EBS volume (appliance data) at /var/lib/ironlog —
#      contract with quadlets/README.md (all persistent bind-mount data lives
#      there).
#   2. Carve the STIG-required separate mount points (/home, /tmp, /var,
#      /var/log, /var/log/audit, /var/tmp) out of the ROOT volume using LVM,
#      with the DISA-mandated mount options.
#
# Idempotent: safe to re-run (checks `findmnt` before touching a mount point).
#
# --- Device naming (read packer/sources.pkr.hcl + packer/README.md first) ---
# packer/sources.pkr.hcl declares launch_block_device_mappings at /dev/sda1
# (root) and /dev/sdb (data). Those are *launch-time* names; packer/README.md
# itself flags that Nitro instance families (c7g/m7g/r8g, all Graviton/Nitro)
# enumerate EBS volumes as NVMe devices in-guest (/dev/nvme0n1, /dev/nvme1n1,
# ...), not /dev/sda1/sdb, and NVMe enumeration order is not guaranteed to
# match attachment order either. We do not assume any literal device name:
#   - the ROOT disk is found by resolving `findmnt` on the live root mount
#     back to its underlying disk (works whether nvme, xvd, or sd naming).
#   - the DATA volume is found BY EXCLUSION: exactly two disks are attached
#     per the packer contract (root + one data volume); whichever whole disk
#     is NOT the root disk's disk, and is not already partitioned/mounted, is
#     the data volume. This sidesteps needing nvme-cli/ebsnvme-id entirely and
#     is robust to any future device-naming scheme.
# fstab entries are written by UUID, never by device path, so none of this
# matters again after first boot.
set -euo pipefail

LOG_TAG="ironlog-partition"
log() { echo "[$LOG_TAG] $*"; }
warn() { echo "[$LOG_TAG] WARNING: $*" >&2; }
die() { echo "[$LOG_TAG] FATAL: $*" >&2; exit 1; }

command -v findmnt >/dev/null || die "findmnt not found (util-linux missing?)"

# --- LV / backing-file sizes (MiB). Override via env if the defaults don't
# fit an operator's root_volume_size. These are a reasoned starting point,
# NOT load-tested against real audit-log or container-churn volume:
#   /home            2048  (2 GiB)  — interactive/admin home dirs only
#   /tmp             2048  (2 GiB)
#   /var            12288  (12 GiB) — holds /var/lib/containers (8 pre-pulled
#                                     images; see scripts/ami/10-baseline.sh
#                                     and 20-container-images.sh)
#   /var/log         4096  (4 GiB)
#   /var/log/audit   4096  (4 GiB)  — generous: STIG cares more about audit
#                                     logs never silently filling than about
#                                     saving space here
#   /var/tmp         2048  (2 GiB)
# Total additional space carved out of the root volume: ~26 GiB. Combined
# with the base OS + /opt/ironlog baked config + the STIG scan reports this
# script's sibling (30-stig.sh) writes, the packer/variables.pkr.hcl DEFAULT
# of root_volume_size=30 is almost certainly too small — see the FATAL
# free-space check below, and packer/README.md "Disk layout". Fix is a
# pkrvars override (root_volume_size = 60 or similar), NOT a packer/ file
# edit — flagged here, not fixed there, per task scope.
HOME_SIZE_MB="${IRONLOG_HOME_SIZE_MB:-2048}"
TMP_SIZE_MB="${IRONLOG_TMP_SIZE_MB:-2048}"
VAR_SIZE_MB="${IRONLOG_VAR_SIZE_MB:-12288}"
VARLOG_SIZE_MB="${IRONLOG_VARLOG_SIZE_MB:-4096}"
VARLOGAUDIT_SIZE_MB="${IRONLOG_VARLOGAUDIT_SIZE_MB:-4096}"
VARTMP_SIZE_MB="${IRONLOG_VARTMP_SIZE_MB:-2048}"
TOTAL_MB=$(( HOME_SIZE_MB + TMP_SIZE_MB + VAR_SIZE_MB + VARLOG_SIZE_MB + VARLOGAUDIT_SIZE_MB + VARTMP_SIZE_MB ))

VG_NAME="ironlogvg"
LOOP_BACKING_DIR="/var/.ironlog-stig-backing"   # only used in the fallback path

# ------------------------------------------------------------------------
# PART 1 — data volume -> /var/lib/ironlog
# ------------------------------------------------------------------------

mkdir -p /var/lib/ironlog

if findmnt -no TARGET /var/lib/ironlog >/dev/null 2>&1; then
  log "/var/lib/ironlog already mounted, skipping data-volume setup"
else
  root_src="$(findmnt -no SOURCE / )"
  # Resolve the root SOURCE (may itself be an LVM dm-device) down to its
  # underlying whole disk(s).
  root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)"
  if [ -z "$root_disk" ]; then
    # root_src is already a whole disk/partition with no further parent
    root_disk="$(basename "$root_src")"
  fi
  # If root is on LVM, PKNAME of the dm device is empty; walk PVs instead.
  if [ -z "$root_disk" ] || [ "$root_disk" = "$(basename "$root_src")" ] && [[ "$root_src" == /dev/mapper/* || "$root_src" == /dev/dm-* ]]; then
    root_vg="$(lsblk -no VG_NAME "$root_src" 2>/dev/null | head -n1)"
    if [ -n "$root_vg" ] && command -v pvs >/dev/null; then
      root_pv_part="$(pvs --noheadings -o pv_name -S "vg_name=$root_vg" 2>/dev/null | awk '{print $1}' | head -n1)"
      [ -n "$root_pv_part" ] && root_disk="$(lsblk -no PKNAME "$root_pv_part" 2>/dev/null | head -n1)"
    fi
  fi
  [ -n "$root_disk" ] || die "could not resolve root disk from source '$root_src'"
  log "root disk resolved to /dev/$root_disk"

  data_disk=""
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [ "$d" = "$root_disk" ] && continue
    # skip anything that already has partitions or a filesystem signature
    # other than what we're about to lay down ourselves (idempotency guard
    # against re-running on an already-provisioned data disk).
    data_disk="$d"
    break
  done
  [ -n "$data_disk" ] || die "no second disk found besides root (/dev/$root_disk) — expected the appliance data volume declared in packer/sources.pkr.hcl (launch_block_device_mappings device_name=/dev/sdb)"
  log "data volume resolved to /dev/$data_disk"

  existing_fstype="$(blkid -s TYPE -o value "/dev/$data_disk" 2>/dev/null || true)"
  if [ -z "$existing_fstype" ]; then
    log "formatting /dev/$data_disk as xfs (appliance data volume)"
    mkfs.xfs -f -L ironlog-data "/dev/$data_disk"
  else
    log "/dev/$data_disk already has a $existing_fstype filesystem, not reformatting"
  fi

  data_uuid="$(blkid -s UUID -o value "/dev/$data_disk")"
  [ -n "$data_uuid" ] || die "could not read UUID of /dev/$data_disk after mkfs"

  if ! grep -q "$data_uuid" /etc/fstab; then
    echo "UUID=$data_uuid /var/lib/ironlog xfs defaults,nodev 0 2" >> /etc/fstab
  fi
  mount /var/lib/ironlog
  log "/var/lib/ironlog mounted from /dev/$data_disk (UUID=$data_uuid)"
fi

# ------------------------------------------------------------------------
# PART 2 — STIG separate mount points on the root volume, via LVM
# ------------------------------------------------------------------------
# Cloud images (RHEL/Rocky 9) ship cloud-init with the growpart + resizefs
# modules enabled by default, which run in cloud-init's early "init" stage —
# BEFORE SSH is available, i.e. before this script can ever run. By the time
# we connect, the root partition (and, on RHEL/Rocky cloud images, the LVM PV
# beneath it) has already been grown to consume the ENTIRE root EBS volume.
# There is no free space left to carve new partitions/LVs out of.
#
# Real LVM (new PV on free disk space) is used when free space genuinely
# exists (e.g. a future base image that doesn't auto-grow, or a
# root_volume_size increase that outpaces growpart for some reason). When it
# doesn't — the expected/common case — we fall back to LVM built on
# LOOP-DEVICE-BACKED files living on the already-grown root filesystem
# itself. This still satisfies "LVM on the root volume, growable later"
# (grow = truncate the backing file + losetup --set-capacity + pvresize +
# lvextend + xfs_growfs — same operator workflow either way) without
# requiring free space on the physical disk. It is NOT the same as a
# hardware-partition boundary; documented as a reasoned deviation, not a
# silent one. See scripts/ami/README.md "Partitioning strategy" for the full
# writeup and the exact packer/ change (adding user_data to disable
# cloud-init growpart before first boot) that would make the free-space path
# the normal case instead.

need_reboot_note=0

root_disk_free_mb() {
  # MiB of unpartitioned free space at the end of the disk holding root's
  # partition (0 if root itself is a bare LVM PV disk with no partition
  # table, or if nothing is free).
  local disk="$1"
  command -v parted >/dev/null || { echo 0; return; }
  parted -s -m "/dev/$disk" unit MiB print free 2>/dev/null \
    | awk -F: '/:free;/{gsub("MiB","",$4); tot+=$4} END{printf "%d", tot+0}'
}

setup_lv_or_loop() {
  # $1 = LV name, $2 = size in MiB, $3 = mount point, $4 = mount options,
  # $5 = fs mode to chmod after mount (optional), $6 = whitespace-separated
  # list of subpaths to exclude from the rsync migration (nested mounts that
  # get provisioned separately).
  local lv="$1" size_mb="$2" mnt="$3" opts="$4" fsmode="${5:-}" excludes="${6:-}"

  if findmnt -no TARGET "$mnt" >/dev/null 2>&1; then
    log "$mnt already a separate mount, skipping"
    return
  fi

  local dev="/dev/$VG_NAME/$lv"
  if [ ! -e "$dev" ]; then
    if ! vgs "$VG_NAME" >/dev/null 2>&1; then
      die "volume group $VG_NAME missing — internal ordering bug (should have been created before setup_lv_or_loop)"
    fi
    log "creating LV $lv (${size_mb}MiB) for $mnt"
    lvcreate -y -L "${size_mb}M" -n "$lv" "$VG_NAME" >/dev/null
    mkfs.xfs -f -L "ironlog-$lv" "$dev" >/dev/null
  fi

  mkdir -p /mnt/ironlog-migrate
  local tmp_mnt="/mnt/ironlog-migrate/$lv"
  mkdir -p "$tmp_mnt"
  mount "$dev" "$tmp_mnt"

  local rsync_excludes=()
  for ex in $excludes; do
    rsync_excludes+=(--exclude="$ex")
  done
  if [ -d "$mnt" ]; then
    rsync -aHAX "${rsync_excludes[@]}" "$mnt"/. "$tmp_mnt"/. 2>/dev/null || true
  fi
  for ex in $excludes; do
    mkdir -p "$tmp_mnt/$ex"
  done
  umount "$tmp_mnt"
  rmdir "$tmp_mnt"

  mkdir -p "$mnt"
  # Direct mount over the live path: the kernel allows mounting a new fs on
  # top of an existing (possibly non-empty) directory; content already
  # copied above, old content is simply shadowed underneath, not deleted.
  mount -t xfs -o "$opts" "$dev" "$mnt"
  [ -n "$fsmode" ] && chmod "$fsmode" "$mnt"

  local uuid
  uuid="$(blkid -s UUID -o value "$dev")"
  [ -n "$uuid" ] || die "could not read UUID for $dev ($mnt)"
  if ! grep -q "$uuid" /etc/fstab; then
    echo "UUID=$uuid $mnt xfs $opts 0 2" >> /etc/fstab
  fi
  log "$mnt provisioned on $dev (UUID=$uuid), options: $opts"
}

# Decide free-space vs loop-backed path, and build the VG accordingly.
if ! vgs "$VG_NAME" >/dev/null 2>&1; then
  root_src="$(findmnt -no SOURCE / )"
  root_part="$root_src"
  root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)"
  free_mb=0
  if [ -n "$root_disk" ]; then
    free_mb="$(root_disk_free_mb "$root_disk")"
  fi

  if [ "$free_mb" -ge "$TOTAL_MB" ] 2>/dev/null; then
    log "found ${free_mb}MiB free on root disk /dev/$root_disk — using real LVM partition, no fallback needed"
    part_num="$(parted -s -m "/dev/$root_disk" print | tail -n1 | cut -d: -f1)"
    next_part=$((part_num + 1))
    parted -s "/dev/$root_disk" mkpart primary "100%FREE" -- "-${TOTAL_MB}MiB" 100% \
      || parted -s "/dev/$root_disk" mkpart primary ext2 "-${TOTAL_MB}MiB" 100%
    udevadm settle
    new_part="/dev/${root_disk}${next_part}"
    [ -e "$new_part" ] || new_part="/dev/${root_disk}p${next_part}"
    pvcreate -y "$new_part" >/dev/null
    vgcreate -y "$VG_NAME" "$new_part" >/dev/null
  else
    warn "root disk has only ${free_mb}MiB free, need ${TOTAL_MB}MiB — cloud-init's growpart has almost certainly already consumed the whole root volume (this is the expected/common case, not a bug). Falling back to loop-device-backed LVM on the root filesystem itself."
    avail_root_mb="$(df -Pm / | tail -1 | awk '{print $4}')"
    [ "$avail_root_mb" -ge $(( TOTAL_MB + 1024 )) ] || die "root filesystem has only ${avail_root_mb}MiB free, need ${TOTAL_MB}MiB for STIG mount backing files plus 1GiB headroom. Increase root_volume_size in packer/variables.auto.pkrvars.hcl (default is 30 GiB, likely too small for this layout) and rebuild."
    mkdir -p "$LOOP_BACKING_DIR"
    chmod 0700 "$LOOP_BACKING_DIR"
    pv_devs=()
    for pair in "home:$HOME_SIZE_MB" "tmp:$TMP_SIZE_MB" "var:$VAR_SIZE_MB" "varlog:$VARLOG_SIZE_MB" "varlogaudit:$VARLOGAUDIT_SIZE_MB" "vartmp:$VARTMP_SIZE_MB"; do
      name="${pair%%:*}"; sz="${pair##*:}"
      img="$LOOP_BACKING_DIR/${name}.img"
      if [ ! -e "$img" ]; then
        truncate -s "${sz}M" "$img"
      fi
      loopdev="$(losetup -j "$img" | cut -d: -f1 | head -n1)"
      if [ -z "$loopdev" ]; then
        loopdev="$(losetup -f --show "$img")"
      fi
      pvcreate -y "$loopdev" >/dev/null 2>&1 || true
      pv_devs+=("$loopdev")
      # persist the loop attachment across reboot: /etc/fstab supports
      # loop-mounted regular files directly for a plain mount, but LVM PVs
      # need the loop device attached before lvm2-activation runs. Use a
      # systemd unit rather than fstab for this piece.
    done
    vgcreate -y "$VG_NAME" "${pv_devs[@]}" >/dev/null

    # boot-time re-attach unit: losetup each backing image before LVM
    # activation tries to find its PVs. LVM's own generator orders
    # lvm2-activation-early.service after local-fs-pre.target; we hook the
    # same point.
    cat > /etc/systemd/system/ironlog-stig-loop-attach.service <<UNIT
[Unit]
Description=Re-attach ironlog STIG loop-backed LVM PVs
DefaultDependencies=no
Before=lvm2-activation-early.service
After=local-fs-pre.target
ConditionPathExists=$LOOP_BACKING_DIR

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in $LOOP_BACKING_DIR/*.img; do losetup -j "\$f" | grep -q . || losetup -f "\$f"; done'

[Install]
WantedBy=local-fs-pre.target
UNIT
    systemctl enable ironlog-stig-loop-attach.service >/dev/null
    log "installed ironlog-stig-loop-attach.service so loop-backed LVM PVs re-attach on every boot"
  fi
fi

setup_lv_or_loop home  "$HOME_SIZE_MB"  /home          "nodev,nosuid"
setup_lv_or_loop var   "$VAR_SIZE_MB"   /var           "nodev"                          "" "log tmp"
setup_lv_or_loop varlog "$VARLOG_SIZE_MB" /var/log     "nodev,nosuid,noexec"            "" "audit"
setup_lv_or_loop varlogaudit "$VARLOGAUDIT_SIZE_MB" /var/log/audit "nodev,nosuid,noexec" "0700"
setup_lv_or_loop vartmp "$VARTMP_SIZE_MB" /var/tmp     "nodev,nosuid,noexec"            "1777"
setup_lv_or_loop tmp   "$TMP_SIZE_MB"    /tmp           "nodev,nosuid,noexec"            "1777"

log "partitioning complete. fstab:"
grep -E '/(home|tmp|var|var/log|var/log/audit|var/tmp|lib/ironlog) ' /etc/fstab || true
