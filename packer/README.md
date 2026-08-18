# packer/ — ironlog appliance image build

Builds the ironlog all-in-one SIEM appliance as an AMI, aarch64 (Graviton),
via Packer HCL2. Two builders share one provisioner list:

| Source | Base | Purpose |
|---|---|---|
| `amazon-ebs.rhel9` | RHEL 9, aarch64 | Shipping image — GovCloud / C2S / SC2S |
| `amazon-ebs.rocky9` | Rocky Linux 9, aarch64 | Local dev/iteration image |

Everything except FIPS validation and STIG scan results is expected to
behave identically on both — that gap is the whole reason the split exists
(RHEL subscription/repo friction slows dev iteration; RHEL is still required
for anything compliance-touching). This is an operator decision already
made; this template does not relitigate it.

## Files

- `ironlog.pkr.hcl` — `packer {}` block, required plugins.
- `variables.pkr.hcl` — all variable declarations (region, instance type,
  AMI filters, volume sizes, tags, ...).
- `sources.pkr.hcl` — the two `amazon-ebs` source blocks, plus a commented
  Azure/OCI stub (see "Multi-cloud extension path" below).
- `build.pkr.hcl` — the single `build` block both sources run through: one
  provisioner list, in the required order (see below).
- `variables.auto.pkrvars.hcl.example` — copy to
  `variables.auto.pkrvars.hcl` and edit; not committed with real values.

## Building

Run from a Unix-like shell (WSL/Linux — matches this repo's existing
convention of running `bootstrap.sh` from WSL Ubuntu, per `CLAUDE.md` "Host
environment"). From the repo root:

```sh
cd packer
packer init .
packer validate .

# RHEL 9 shipping image
packer build -only=ironlog.amazon-ebs.rhel9 \
  -var-file=variables.auto.pkrvars.hcl \
  -var "build_git_sha=$(git rev-parse --short HEAD)" \
  .

# Rocky 9 dev image
packer build -only=ironlog.amazon-ebs.rocky9 \
  -var-file=variables.auto.pkrvars.hcl \
  -var "build_git_sha=$(git rev-parse --short HEAD)" \
  .
```

Both builds emit a `manifest.json` in this directory (via the `manifest`
post-processor) with the resulting AMI ID(s), region, and `build_git_sha` —
consume that from CI rather than scraping `packer build` stdout.

## Required AWS permissions

Packer's `amazon-ebs` builder needs, at minimum:
`ec2:DescribeImages`, `ec2:RunInstances`, `ec2:DescribeInstances`,
`ec2:CreateImage`, `ec2:DeregisterImage`, `ec2:DescribeSnapshots`,
`ec2:DeleteSnapshot`, `ec2:CreateSnapshot`, `ec2:CreateTags`,
`ec2:CreateKeyPair`, `ec2:DeleteKeyPair`, `ec2:CreateSecurityGroup`,
`ec2:DeleteSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`,
`ec2:GetPasswordData`, `ec2:StopInstances`, `ec2:TerminateInstances`,
`ec2:DescribeSubnets`, `ec2:DescribeVpcs`, `ec2:DescribeSecurityGroups`,
`ec2:DescribeRegions`, `ec2:DescribeInstanceTypes`, plus `kms:*` grants on
the CMK if `kms_key_id` is set. AWS's own `AmazonEC2FullAccess` covers this
with room to spare; use HashiCorp's documented minimal Packer IAM policy if
you need least-privilege (not vendored here — see the `amazon-ebs`
plugin docs). Not independently re-derived/tested against a real account in
this session.

## GovCloud

Override `aws_region` to `us-gov-west-1` or `us-gov-east-1` in
`variables.auto.pkrvars.hcl` (or `-var`). GovCloud is a **separate AWS
partition**: your AWS credentials/profile must already be scoped to a
GovCloud account — a commercial-partition profile cannot see or build in it.

Two things to confirm before a real GovCloud build, neither verified in
this session:
- Whether Red Hat's official RHEL AMI owner account ID
  (`309956199498`, the commercial-partition value used as the
  `rhel_ami_owner` default) is the same ID in the GovCloud partition. AWS
  account IDs are not guaranteed portable across partitions for
  vendor-published images — confirm with `aws ec2 describe-images` against
  a GovCloud credential before trusting the default.
- C2S/SC2S build separately again: those are their own isolated partitions
  with their own endpoint and credential wiring, outside anything this
  template or a normal AWS CLI profile reaches. Treat a C2S/SC2S build as
  needing an operator with access to that enclave to supply region/
  endpoint/AMI-owner overrides; this template only carries the region
  variable that far, deliberately, rather than guessing at endpoints it has
  no way to verify.

## Source AMI owner IDs — VERIFIED 2026-08-17

Both resolved with a live `aws ec2 describe-images` call (profile `il`,
account 196280209837) in **us-east-1 and us-west-1**.

- **RHEL 9 aarch64**: owner `309956199498`, filter `RHEL-9*_HVM-*-arm64-*`.
  Resolves; most recent at time of check was
  `RHEL-9.8.0_HVM-20260728-arm64-0-Hourly2-GP3`.
- **Rocky Linux 9 aarch64**: owner `792107900819` is correct, but the name
  filter was **wrong and has been fixed**. It was `Rocky-9-*-aarch64-*`,
  which matched **zero** images and would have failed the build at source-AMI
  resolution. Real names are `Rocky-9-EC2-LVM-9.8-20260525.0.aarch64` — the
  architecture is dot-separated and terminal, not `-aarch64-<suffix>`. The
  default is now `Rocky-9-EC2-LVM-9.*.aarch64`.
- **LVM, not Base.** Rocky publishes both `Rocky-9-EC2-Base-*` and
  `Rocky-9-EC2-LVM-*`. Only the LVM variant is LVM-on-partition, which is
  what `scripts/ami/00-partition.sh` expects (its loop-device fallback is
  there for when it is not). Do not switch to Base without revisiting that
  script.
- A second AWS account, `679593333241`, distributes the same Rocky 9 images
  via AWS Marketplace (subscription-gated) — do not swap it in without also
  adding Marketplace-subscription handling; it is a different distribution
  mechanism, not just a different owner ID for the same AMIs.

Re-check in any new region or partition before a first build there:

```sh
aws ec2 describe-images --owners 792107900819   --filters "Name=name,Values=Rocky-9-EC2-LVM-9.*.aarch64"   --query 'reverse(sort_by(Images,&CreationDate))[:5].[ImageId,Name]' --output table
```

## Disk layout (contract — do not change without updating `scripts/ami/00-partition.sh`)

- **Root EBS volume** (`/dev/sda1`, default 60 GiB gp3): the OS, with
  STIG-required separate partitions carved out by
  `scripts/ami/00-partition.sh`. The STIG LV layout alone carves ~26 GiB,
  before the base OS, the baked `/opt/ironlog` config, ~8 pre-pulled
  container images, and the STIG scan evidence written into the image — so
  30 GiB is not enough and 60 is the working default.
- **Second EBS volume** (`/dev/sdb`, default 100 GiB gp3): appliance data,
  mounted at `/var/lib/ironlog`. Declared as a second
  `launch_block_device_mappings` block, `delete_on_termination = false` —
  deliberately NOT part of the root volume/AMI snapshot, so it can be
  resized and snapshotted independently of the OS image. This matches the
  quadlets contract in `quadlets/README.md` (`/var/lib/ironlog/<name>/` bind
  mounts, not podman named volumes).

**Open item, not solved here**: `/dev/sdb` is the *launch-time* device name
requested from EC2. On Nitro-based instance families — which `c7g`/`m7g`/
`r8g` all are — EBS volumes typically enumerate inside the guest as NVMe
devices (e.g. `/dev/nvme1n1`), not as `/dev/sdb`/`/dev/xvdb`. Whoever's
`scripts/ami/00-partition.sh` decides how to locate the data volume should
resolve it by NVMe volume-ID metadata (`nvme id-ctrl`/`ebsnvme-id`) or a
udev-stable path, not assume the launch-time device name is what appears in
the guest. Flagging this here since it's exactly the kind of assumption that
silently breaks a partitioning script; not fixed in this template because
`00-partition.sh` is owned by another worker.

## Provisioner order

Both sources run this exact list, in order (`build.pkr.hcl`):

1. `scripts/ami/00-partition.sh` — disk layout, separate partitions
2. `scripts/ami/10-baseline.sh` — packages, podman, `dnf update`
3. file provisioner: `clickhouse/`, `grafana/`, `keycloak/`, `vector/` → `/opt/ironlog/...`
4. file provisioner: `quadlets/*.container`, `quadlets/*.network` → `/etc/containers/systemd/`
5. file provisioner: `scripts/firstboot/` → `/usr/local/lib/ironlog/`
6. `scripts/ami/20-container-images.sh` — pre-pull all 8 container images (arm64) into containers-storage
7. `scripts/ami/30-stig.sh` — STIG hardening
8. `scripts/ami/40-fips.sh` — FIPS mode
9. `scripts/ami/90-cleanup.sh` — log/ssh-key/cloud-init cleanup before snapshot

File uploads stage under `/tmp/ironlog-stage` (the SSH user has no direct
write access to `/opt`, `/etc/containers/systemd`, or `/usr/local/lib`) and a
following `shell` provisioner moves them into place as root, fixes
ownership, and cleans up the staging dir. Steps 3–5 upload whole
directories (not just the files named in the contract) because Packer's
`file` provisioner doesn't glob — step 4's follow-up shell provisioner then
`find`s and copies only `*.container`/`*.network` out of the staged
`quadlets/` tree, so `quadlets/README.md` and `quadlets/hyperdx/` do NOT
land in `/etc/containers/systemd/`.

Container image list (baked into `scripts/ami/20-container-images.sh`,
passed through here as `IRONLOG_CONTAINER_IMAGES` env var for
documentation/single-source-of-truth purposes — the script is authoritative,
this is not a second definition to drift):

`clickhouse/clickhouse-server:24.8`, `postgres:16-alpine`,
`quay.io/keycloak/keycloak:26.0`, `grafana/grafana-oss:11.4.0`,
`docker.hyperdx.io/hyperdx/hyperdx:2.19.0`, `mongo:7.0`,
`quay.io/oauth2-proxy/oauth2-proxy:v7.15.3`, `timberio/vector:0.57.0-debian`.

## Multi-cloud extension path (Azure/OCI — not now)

`sources.pkr.hcl` ends with a commented stub. When Azure/OCI become a real
requirement: add the plugin to `required_plugins`, add an `azure-arm` or
`oracle-oci` source block with the same shape (region/image-filter/disk
variables, no provisioner logic of its own), and add it to the `sources =
[...]` list in `build.pkr.hcl`. Every provisioner in `build.pkr.hcl` is
already cloud-agnostic — file paths and shell commands only, nothing reaches
into AWS-specific values outside the `source` blocks themselves — so adding
a cloud is a `sources.pkr.hcl` + `build.pkr.hcl` list-membership change, not
a provisioner rewrite.

## Dev loop alternative considered (and rejected as the default)

The task allows arguing for a QEMU or vagrant dev builder instead of AWS.
Considered and rejected as the *default* dev path, for three reasons: (1) no
official Rocky 9 aarch64 qcow2/vagrant box is as turn-key as filtering the
AWS AMI catalog the same way the RHEL build does; (2) a local VM builder
can't exercise the two-EBS-volume block-device-mapping contract that most
needs day-to-day testing before a real RHEL build; (3) it would drift the
dev and shipping paths apart on exactly the AWS-specific mechanics (block
device mappings, tags, `manifest` post-processor) that this template is
trying to keep unified. The real tradeoff: the AWS-based Rocky dev build
needs credentials and costs money per iteration where a local VM would be
free and offline. If iteration cost becomes painful, a `qemu` source
restricted to provisioner-script/config-rendering iteration (skipping the
AWS-specific blocks entirely) is a reasonable follow-up — not built here.

## FIPS / Vector — open risk (not solved here, documented per task spec)

`scripts/ami/40-fips.sh` (step 8) turns FIPS mode on. Vector's system-OpenSSL
build is **known broken** on FIPS-enabled kernels: PKCS12KDF is not
FIPS-approved, and the relevant upstream issues
([vectordotdev/vector#23147](https://github.com/vectordotdev/vector/issues/23147),
[#21232](https://github.com/vectordotdev/vector/issues/21232)) are open as
of this writing. The designed mitigation is to take TLS out of Vector
entirely: nginx or stunnel terminates inbound agent TLS and forwards
plaintext on loopback, a forward proxy handles outbound S3/SQS TLS, and the
ClickHouse sink is already loopback-only (per `CLAUDE.md`'s Vector
healthcheck note).

**Whether Vector starts cleanly with FIPS ON and no TLS configured is
REASONED BUT UNTESTED, and per the operator's standing convention on this
build (Rocky 9 for development, RHEL 9 for shipping and anything
compliance-touching, set 2026-08-16), that test must run on real RHEL 9,
not Rocky.** This template runs `40-fips.sh` on
both sources for build-path parity, but a Rocky-built AMI passing this step
is NOT evidence that Vector-under-FIPS works — only a RHEL 9 build/boot,
with an actual `systemctl status ironlog-vector` and `journalctl -u
ironlog-vector` check post-boot, settles it. Not attempted in this session
(no AWS credentials, no live instance to boot).

## `ena_support` / `sriov_net_support`

`ena_support = true` is set on both sources. `sriov_net_support` is
deliberately omitted: it's the legacy Xen-HVM "simple" enhanced-networking
flag, and the Graviton/Nitro instance families this appliance targets
(`c7g`/`m7g`/`r8g`) are ENA-only — setting `sriov_net_support` on a
Nitro-only AMI is a no-op at best.

## `packer validate`

**Packer was not installed on this machine** (`command -v packer` found
nothing). HCL was hand-checked for syntax and cross-referenced against the
`amazon-ebs` builder / `manifest` post-processor schemas from memory, and
every provisioner path was checked against the exact paths given in the
task contract, but `packer validate`/`packer init` were NOT run and this
is not a substitute for actually running them before a real build. Run
`packer init . && packer validate .` from `packer/` on a machine with
Packer installed before relying on this.
