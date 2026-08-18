# scripts/ami/ — AMI build provisioner scripts

Six shell provisioners, run in order as root by `packer/build.pkr.hcl`
(steps 1, 2, 6, 7, 8, 9), turning a stock RHEL 9 / Rocky 9 aarch64 cloud
image into the hardened ironlog appliance base. All are `bash`, `set -euo
pipefail`, idempotent where practical, and log every action with an
`[ironlog-<stage>]` prefix.

Filenames are contract (packer/build.pkr.hcl calls them by exact path) — do
not rename.

| Script | Does |
|---|---|
| `00-partition.sh` | Mounts the data EBS volume at `/var/lib/ironlog`; carves `/home /tmp /var /var/log /var/log/audit /var/tmp` out of the root volume as LVM logical volumes with STIG mount options |
| `10-baseline.sh` | `dnf update`, installs podman + supporting packages, creates `/opt/ironlog` `/etc/ironlog` `/var/lib/ironlog`, configures container storage, disables podman auto-update, enables chronyd |
| `20-container-images.sh` | Pre-pulls all 8 appliance images with `--arch arm64`, verifies each is actually arm64, fails the build otherwise |
| `30-stig.sh` | `oscap xccdf eval --remediate` against `ssg-rhel9-ds.xml`, tailored to skip container-incompatible rules, then a second evidence-only scan; reports land in `/var/log/ironlog-build/` inside the image |
| `40-fips.sh` | `fips-mode-setup --enable`; logs the RHEL-validated module cert numbers or the Rocky-not-validated warning; documents the outstanding reboot requirement |
| `90-cleanup.sh` | SSH host keys, cloud-init state, logs, dnf caches, credentials, bash history, machine-id, `fstrim` — preserves `/var/log/ironlog-build/` |

## Partitioning strategy (00-partition.sh)

Two devices, identified without assuming a launch-time name (Nitro/Graviton
instances enumerate EBS as NVMe in-guest, not `/dev/sda1`/`/dev/sdb` — see
`packer/README.md` "Disk layout" and the comment header in
`00-partition.sh`):
- **root disk** — resolved via `findmnt` on the live `/` mount, walking
  through LVM if the root fs is already on a PV.
- **data disk** — whichever attached whole disk is *not* the root disk
  (exactly two disks are attached per the packer contract, so exclusion is
  sufficient and doesn't need `nvme-cli`/`ebsnvme-id`).

**Cloud-init already grows the root partition before we ever connect.**
RHEL/Rocky 9 cloud images run cloud-init's `growpart`+`resizefs` modules in
the early `init` stage — before SSH is up, before Packer's shell provisioner
can run. By the time `00-partition.sh` executes, the root partition (and its
LVM PV, since RHEL/Rocky cloud images are LVM-on-partition by default) has
already been grown to consume the entire root EBS volume. There is no free
space to carve new partitions from.

`00-partition.sh` handles this with two paths:
1. **Free-space path** (real LVM on a new partition) — used automatically
   if free space is actually found on the root disk.
2. **Loop-backed fallback** (the expected/common case) — LVM built on
   loop-device-backed sparse files living on the already-grown root
   filesystem itself, with a `systemd` unit
   (`ironlog-stig-loop-attach.service`) that re-attaches the loop devices
   before `lvm2-activation-early.service` on every subsequent boot. This
   still satisfies "LVM, growable later" (grow = `truncate` the backing
   file + `losetup --set-capacity` + `pvresize` + `lvextend` +
   `xfs_growfs`), just not as a hardware partition boundary.

**Genuine conflict, not fixed here (packer/ is out of scope):** the real fix
that would make the free-space path the *normal* case is disabling
cloud-init's growpart module for the FIRST boot only, via `user_data` on the
`amazon-ebs` source blocks in `packer/sources.pkr.hcl` — neither source
declares `user_data`/`user_data_file` today. Flagging for whoever owns
`packer/` next; not attempted here per task scope ("do not edit packer/").

**Sizing — RESOLVED 2026-08-16.** The STIG LV layout totals ~26 GiB carved
out of the root volume, on top of base OS + `/opt/ironlog` baked config +
~8 pre-pulled container images + the STIG scan evidence this pipeline
writes into the image. `packer/variables.pkr.hcl`'s `root_volume_size`
default was **30 GiB**, which is not enough; it is now **60 GiB**.
`00-partition.sh` still fails fast with an actionable message if the
loop-backed fallback path doesn't have enough free space, rather than
silently running out mid-build.

Mount options applied (standard DISA STIG RHEL 9 requirements):

| Mount | Options |
|---|---|
| `/home` | `nodev,nosuid` |
| `/tmp` | `nodev,nosuid,noexec` |
| `/var` | `nodev` |
| `/var/log` | `nodev,nosuid,noexec` |
| `/var/log/audit` | `nodev,nosuid,noexec`, mode `0700` |
| `/var/tmp` | `nodev,nosuid,noexec`, mode `1777` |
| `/var/lib/ironlog` (data volume) | `nodev` |

All fstab entries are written by UUID.

## STIG vs. containers — the exception list

Full rationale lives in the header comment of `30-stig.sh` (POA&M-style
block); summary here for anyone who doesn't want to read the script:

1. **`sysctl_net_ipv4_ip_forward`** — STIG wants `ip_forward=0`; podman's
   bridge network needs `=1`. **Tailored out**, then pinned back to `1`
   explicitly via `/etc/sysctl.d/99-ironlog-podman.conf` with a comment
   explaining why.
2. **Firewalld default-deny** — a real, wanted control, NOT tailored out.
   SSG's remediation turns firewalld on with a default-deny zone but knows
   nothing about ironlog's published ports; `30-stig.sh` opens
   `8080,3000,8081,8088,6000/tcp` explicitly afterward. **Cross-team
   follow-up, not fixed here:** none of the quadlet units declare
   `After=`/`Wants=firewalld.service`, so there's a boot-order race between
   firewalld loading these rules and a quadlet publishing its ports — flag
   for whoever owns `quadlets/` next.
3. **Unused-filesystem kernel-module-disable rules** (cramfs, freevxfs, hfs,
   hfsplus, jffs2, squashfs, udf) — checked and confirmed these do **not**
   include `overlay`/`bridge`/`veth` (podman's storage/network modules), so
   this is **not** a real conflict despite superficially looking like one.
   Documented so nobody "fixes" a non-problem later. Verify on first real
   boot: `lsmod | grep -E 'overlay|bridge|veth'`.
4. **World-writable-file / SUID remediation rules** — real, wanted
   controls, NOT tailored out, but flagged: podman intentionally creates
   permissive files/sockets under `/run/user/*`, `/run/containers`,
   `/var/lib/containers` in narrow spots. Could not enumerate exact paths
   without a live scan. If any `ironlog-*` service fails to start after
   this step, check its journal for permission-denied errors and
   cross-reference this family of rules before assuming it's unrelated.
5. **`sysctl_user_max_user_namespaces`** — UNVERIFIED whether the RHEL 9 SSG
   `stig` profile actually includes this rule (couldn't confirm against a
   live scan). Tailored out defensively anyway — costs nothing if it turns
   out not to be in-profile; would break rootless-podman internals if it
   fired and weren't excluded.
6. **SELinux enforcing/targeted** — NOT a conflict, not tailored out.
   Podman is fully SELinux-aware; `quadlets/README.md`'s "SELinux
   labelling" section already covers the `:Z`/`:ro,Z` relabeling every bind
   mount needs. Confirmation, not a new finding.

Rocky note: the RHEL 9 SSG content and profile ID
(`xccdf_org.ssgproject.content_profile_stig`) apply identically on Rocky 9
(same package set/paths, no Rocky-specific SSG content ships) — the only
difference is what the resulting evidence is worth (see below).

Evidence lands in `/var/log/ironlog-build/` inside the shipped image:
`stig-remediate-{results.xml,report.html}` (first pass, with remediation),
`stig-postremediate-{results.xml,report.html}` (second, evidence-only pass),
`ironlog-tailoring.xml` (the exclusions above, machine-readable), and a copy
of `ssg-rhel9-ds.xml` itself. `90-cleanup.sh` explicitly preserves this
directory.

## FIPS (40-fips.sh)

- **RHEL 9**: validated modules — OpenSSL #4746/#4857, GnuTLS #4780/#4846,
  Kernel Crypto API #4796/#5034. This is the only build path FIPS evidence
  should be drawn from.
- **Rocky 9**: FIPS mode turns on functionally but carries **none** of
  Red Hat's CMVP certificates. A Rocky-built AMI passing this step is
  functional testing only, never compliance evidence — matches the
  operator's standing dev/ship convention (Rocky = dev/iteration, RHEL =
  shipping + anything compliance-touching).
- **Reboot requirement — RESOLVED 2026-08-16.** `fips-mode-setup --enable`
  only stages the change (regenerates initramfs, adds `fips=1` to the kernel
  command line); the running kernel stays non-FIPS until reboot. Previously
  `packer/build.pkr.hcl` had no reboot provisioner at all, so every AMI it
  produced was registered from an instance that *enabled* FIPS but never
  *booted* under it. `build.pkr.hcl` now has a reboot step (8b) plus a
  post-reboot verification step (8c) that reads `/proc/sys/crypto/fips_enabled`
  and fails the build if it is not `1`, so an image that only looks hardened
  cannot ship. `40-fips.sh` still logs the requirement at build time.
- **Known open risk, documented not solved:** Vector's system-OpenSSL build
  is broken under FIPS (`PKCS12KDF` not FIPS-approved — see
  vectordotdev/vector#23147 and #21232, open upstream). Mitigation is
  removing TLS from Vector entirely (loopback-terminated inbound, forward
  proxy for outbound, ClickHouse sink already loopback-only). **Whether
  Vector starts cleanly with FIPS on and no TLS configured is REASONED BUT
  UNTESTED** — no reboot has happened in this build path yet, and per the
  operator's standing convention this can only be validated on real RHEL 9.
  `40-fips.sh` leaves a `TODO` with the exact `systemctl`/`journalctl`
  commands to run once a real RHEL 9 instance reboots under this AMI.

## What's tested vs. reasoned

- All six scripts pass `bash -n` (verified this session).
- `shellcheck` was **not available in this environment** (`command -v
  shellcheck` found nothing) — not run, not claimed to have been run.
- Nothing here was executed against a live RHEL 9 or Rocky 9 instance; no
  AWS credentials / EC2 access in this session. Every idempotency check,
  every `findmnt`/`lsblk`/`parted` device-resolution path, the LVM and
  loop-device fallback logic, the `oscap` tailoring-file mechanics, and the
  FIPS/Vector interaction are REASONED from documented tool behavior, not
  verified by a real run. Treat a first real build as the actual test of
  this code, and expect to iterate on `00-partition.sh`'s device-resolution
  logic in particular — it's the highest-complexity, least-testable-here
  piece.

## Assumptions that could not be verified in this session

- Exact SSG RHEL 9 rule IDs (`content_rule_sysctl_net_ipv4_ip_forward`,
  `content_rule_sysctl_user_max_user_namespaces`) — standard SSG naming
  convention, not confirmed against the literal `<Rule id=...>` attributes
  in an installed `ssg-rhel9-ds.xml` (no package available in this
  environment).
- Whether `sysctl_user_max_user_namespaces` is actually part of the RHEL 9
  SSG `stig` profile at all (tailored out defensively regardless — see
  exception #5 above).
- RHEL/Rocky 9 cloud images being LVM-on-partition by default, and
  cloud-init's growpart module consuming all free space before SSH is
  reachable — well-documented general behavior, not confirmed against the
  specific AMI IDs `packer/sources.pkr.hcl` resolves to.
- Container image storage sizing (12 GiB `/var` default) — a reasoned
  estimate for 8 images including ClickHouse/Keycloak, not measured against
  actual pulled image sizes on real hardware.
- Whether `firewalld` is even installed/active by default on the base
  cloud images before STIG remediation runs (`30-stig.sh` handles either
  case, but which one is real wasn't confirmed).
