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

# Resolve a mount source (which may itself be an LVM dm device) down to the
# underlying whole-disk name, e.g. "nvme0n1". Echoes empty if unresolvable.
#
# Every command substitution below is guarded with `|| true`. Under
# `set -euo pipefail` an assignment inherits the exit status of its command
# substitution, so one failing lookup aborts the whole script -- and because
# stderr is redirected to /dev/null it aborts with NO output at all. That is
# exactly how the original version failed: it used `lsblk -no VG_NAME`, but
# VG_NAME is not an lsblk column, so lsblk exited non-zero on every LVM root.
resolve_disk_of() {
  local src="$1" disk vg pv
  disk="$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -n1 || true)"
  if [ -n "$disk" ]; then
    echo "$disk"
    return 0
  fi
  # dm devices have no PKNAME -- walk LV -> VG -> PV -> parent disk instead.
  command -v lvs >/dev/null 2>&1 || { echo ""; return 0; }
  vg="$(lvs --noheadings -o vg_name "$src" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [ -n "$vg" ] || { echo ""; return 0; }
  command -v pvs >/dev/null 2>&1 || { echo ""; return 0; }
  pv="$(pvs --noheadings -o pv_name -S "vg_name=$vg" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
  [ -n "$pv" ] || { echo ""; return 0; }
  # -d is essential: without it lsblk walks the whole tree and the LVM
  # children report the PV PARTITION as their parent, so this returned
  # "nvme0n1p3" instead of "nvme0n1" -- which then matched no disk, and the
  # data-volume search below selected the root disk and tried to mkfs it.
  disk="$(lsblk -ndo PKNAME "$pv" 2>/dev/null | head -n1 || true)"
  [ -n "$disk" ] || disk="$(basename "$pv")"
  echo "$disk"
}

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
  root_disk="$(resolve_disk_of "$root_src")"
  [ -n "$root_disk" ] || die "could not resolve root disk from source '$root_src'"
  log "root disk resolved to /dev/$root_disk"

  data_disk=""
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    if [ "$d" = "$root_disk" ]; then continue; fi
    # Belt-and-braces: name comparison alone is not enough to bet an
    # unrecoverable `mkfs -f` on. Skip any disk with a mounted filesystem
    # anywhere in its tree, whichever name resolution produced.
    if lsblk -no MOUNTPOINT "/dev/$d" 2>/dev/null | grep -q '[^[:space:]]'; then
      log "skipping /dev/$d: already has mounted filesystem(s), not the data volume"
      continue
    fi
    # skip anything that already has partitions or a filesystem signature
    # other than what we're about to lay down ourselves (idempotency guard
    # against re-running on an already-provisioned data disk).
    data_disk="$d"
    break
  done
  [ -n "$data_disk" ] || die "no second disk found besides root (/dev/$root_disk) — expected the appliance data volume declared in packer/sources.pkr.hcl (launch_block_device_mappings device_name=/dev/sdb)"
  log "data volume resolved to /dev/$data_disk"

  if lsblk -no MOUNTPOINT "/dev/$data_disk" 2>/dev/null | grep -qx '/'; then
    die "refusing to format /dev/$data_disk: it carries the running root filesystem (root disk resolved to /dev/$root_disk -- resolution bug)"
  fi

  existing_fstype="$(blkid -s TYPE -o value "/dev/$data_disk" 2>/dev/null || true)"
  if [ -z "$existing_fstype" ]; then
    log "formatting /dev/$data_disk as xfs (appliance data volume)"
    mkfs.xfs -f -L ironlog-data "/dev/$data_disk"
  else
    log "/dev/$data_disk already has a $existing_fstype filesystem, not reformatting"
  fi

  data_uuid="$(blkid -s UUID -o value "/dev/$data_disk" || true)"
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
# BEFORE SSH is available, i.e. before this script can ever run.
#
# MEASURED 2026-08-18 on Rocky-9-EC2-LVM-9.8 aarch64 with root_volume_size=60:
# growpart did NOT consume the volume. cloud-init grew the root PARTITION and
# filesystem within the source image's original ~10GiB GPT, and this script
# found 51200MiB genuinely free — so the real-LVM path below is what actually
# runs on the shipping configuration, and the loop-device fallback did not
# trigger. An earlier revision of this comment asserted the opposite ("no free
# space left", fallback is "the expected/common case"); that was reasoned, not
# observed, and the build data contradicts it. Do not re-derive the old claim.
#
# Two consequences worth keeping in mind:
#   - The stale GPT is the real obstacle, not missing space: the backup header
#     still describes the small source disk, so mkpart must fix it first (see
#     the parted --fix call below).
#   - The fallback path below is therefore NOT exercised by the normal Rocky
#     build. It remains correct-by-construction but is now UNTESTED in CI
#     terms; treat any change to it as unverified until a build actually takes
#     that branch.
#
# Real LVM (new PV on free disk space) is used when free space genuinely
# exists — the measured case above. When it does not (a base image that really
# does auto-grow to the full volume, or a root_volume_size that growpart fully
# consumes), we fall back to LVM built on
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
    # XFS labels are capped at 12 characters and mkfs.xfs treats an over-long
    # one as a usage error, not a warning: "Invalid value ironlog-varlog for -L
    # option". The old "ironlog-$lv" scheme silently fit for home (12) and var
    # (11) and then failed on the first longer name. "il-" keeps the labels
    # namespaced without eating the budget; only varlogaudit needs truncating,
    # and it stays distinct from every other label in the set.
    local label="il-$lv"
    label="${label:0:12}"
    mkfs.xfs -f -L "$label" "$dev" >/dev/null
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
  if [ -n "$fsmode" ]; then chmod "$fsmode" "$mnt"; fi

  local uuid
  uuid="$(blkid -s UUID -o value "$dev" || true)"
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
  root_disk="$(resolve_disk_of "$root_src")"
  free_mb=0
  if [ -n "$root_disk" ]; then
    free_mb="$(root_disk_free_mb "$root_disk" || true)"
  fi

  if [ "$free_mb" -ge "$TOTAL_MB" ] 2>/dev/null; then
    log "found ${free_mb}MiB free on root disk /dev/$root_disk — using real LVM partition, no fallback needed"
    # The root EBS volume is launched larger than the source AMI's snapshot, so
    # the GPT backup header still sits at the OLD end-of-disk and the header's
    # LastUsableLBA is stale. `parted print free` reports the real free space
    # regardless -- that is why free_mb above is correct -- but writing into
    # that space needs the header relocated first. parted --fix answers the
    # "fix the GPT" prompt that -s otherwise declines silently.
    if ! parted -s -f "/dev/$root_disk" print >/dev/null 2>&1; then
      # parted < 3.3 has no --fix; sgdisk -e does the same job where present.
      if command -v sgdisk >/dev/null 2>&1; then
        sgdisk -e "/dev/$root_disk" >/dev/null 2>&1 || true
      fi
    fi

    # Absolute start/end taken from parted's own free-space table -- NOT a
    # negative offset like "-${TOTAL_MB}MiB". Two separate parted-argument bugs
    # lived here and both are worth naming so they do not come back:
    #   1. `mkpart primary "100%FREE" -- "-${TOTAL_MB}MiB" 100%` -- 100%FREE is
    #      not parted syntax, and with `--` mid-command parted read the three
    #      remaining words as name/start/end, making start=100% (end of disk)
    #      and end=-26624MiB: "Can't have the end before the start!
    #      (start sector=125829119 length=-54525951)".
    #   2. the `|| parted ... "-${TOTAL_MB}MiB" 100%` fallback put a
    #      leading-dash value in option position with no preceding `--`, so
    #      getopt shredded it one character at a time:
    #      "parted: invalid option -- '2'" ... "invalid option -- 'B'".
    # parted -m free-space lines are `num:start:end:size:free;`, hence $2/$3.
    # The end is rounded DOWN and then backed off a further 1MiB: `print free`
    # reports the trailing region as ending at the device size (61440MiB on a
    # 60GiB volume) because `unit MiB` rounds the last usable sector up, but
    # mkpart rejects that exact value -- "Error: The location 61440MiB is
    # outside of the device /dev/nvme1n1." The secondary GPT header needs the
    # last 33 sectors anyway, so 1MiB of slack costs nothing and is correct for
    # a mid-disk region too.
    free_region="$(parted -s -m "/dev/$root_disk" unit MiB print free 2>/dev/null \
      | awk -F: '/:free;/{ s=$2; e=$3; gsub("MiB","",s); gsub("MiB","",e);
                           if (e - s > best) { best = e - s; bs = s; be = e } }
                 END { if (best > 0) printf "%d %d", int(bs) + 1, int(be) - 1 }' || true)"
    start_mb=""; end_mb=""
    read -r start_mb end_mb <<<"$free_region" || true
    if [ -z "$start_mb" ] || [ -z "$end_mb" ] || [ "$((end_mb - start_mb))" -lt "$TOTAL_MB" ]; then
      die "no single free region on /dev/$root_disk large enough for ${TOTAL_MB}MiB (parted reported ${free_mb}MiB free in total, largest contiguous region: '${free_region:-none}')"
    fi

    # Identify the new partition by diffing the device list, rather than by
    # guessing "<disk><n+1>" vs "<disk>p<n+1>": the suffix differs between nvme
    # and xvd naming, and the highest existing partition NUMBER is not
    # necessarily n when the table has gaps.
    parts_before="$(lsblk -nro NAME "/dev/$root_disk" | tail -n +2 | sort)"
    parted -s -a optimal "/dev/$root_disk" mkpart ironlogpv "${start_mb}MiB" "${end_mb}MiB"
    udevadm settle
    partprobe "/dev/$root_disk" >/dev/null 2>&1 || true
    udevadm settle
    parts_after="$(lsblk -nro NAME "/dev/$root_disk" | tail -n +2 | sort)"
    new_name="$(comm -13 <(echo "$parts_before") <(echo "$parts_after") | head -n1 || true)"
    [ -n "$new_name" ] || die "parted reported success but no new partition appeared on /dev/$root_disk"
    new_part="/dev/$new_name"
    log "created $new_part (${start_mb}MiB-${end_mb}MiB) as the ironlog LVM PV"
    pvcreate -y "$new_part" >/dev/null
    vgcreate -y "$VG_NAME" "$new_part" >/dev/null
  else
    warn "root disk has only ${free_mb}MiB free, need ${TOTAL_MB}MiB — cloud-init's growpart appears to have consumed the whole root volume. NOTE: on the measured Rocky 9.8 LVM build this branch does NOT normally trigger (51200MiB was free), so reaching it means either a different base image or a root_volume_size too close to the source image size. Falling back to loop-device-backed LVM on the root filesystem itself."
    avail_root_mb="$(df -Pm / | tail -1 | awk '{print $4}' || true)"
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
      loopdev="$(losetup -j "$img" 2>/dev/null | cut -d: -f1 | head -n1 || true)"
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

# Packer uploads every subsequent shell provisioner as a file and then EXECUTES
# it, using remote_folder (default /tmp). The STIG mount options applied above
# make /tmp noexec, so from this point on every later provisioner would die with
# "sh: line 1: /tmp/script_NNNN.sh: Permission denied" (exit 126). That is not a
# packer bug and not something to fix by relaxing /tmp: the live mounts must
# stay STIG-correct for the whole build so the openscap scan in 30-stig.sh
# measures the real thing. Instead give packer an exec-capable, SSH-user-owned
# scratch directory on the root filesystem, and point remote_folder at it in
# packer/build.pkr.hcl. 90-cleanup.sh removes it before the snapshot.
#
# SUDO_USER, not a hardcoded name: the SSH user is `rocky` on Rocky and
# `ec2-user` on RHEL, and sudo sets this itself (it is not inherited, so the
# absence of `sudo -E` in execute_command does not matter here).
BUILD_SCRATCH="/opt/ironlog-build"
mkdir -p "$BUILD_SCRATCH"
if [ -n "${SUDO_USER:-}" ]; then
  chown "$SUDO_USER" "$BUILD_SCRATCH"
fi
chmod 0700 "$BUILD_SCRATCH"
log "build scratch dir $BUILD_SCRATCH created (owner ${SUDO_USER:-root}) — packer remote_folder, exec-capable unlike the now-noexec /tmp"

log "partitioning complete. fstab:"
grep -E '/(home|tmp|var|var/log|var/log/audit|var/tmp|lib/ironlog) ' /etc/fstab || true
