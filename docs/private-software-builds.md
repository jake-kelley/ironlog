---
type: Guide
title: RHEL 9 and private software builds
description: Select a RHEL 9 base and provision the appliance from a local or S3 software bundle.
tags: [deployment, rhel, aws, air-gap]
timestamp: 2026-09-15T00:00:00Z
---

# RHEL 9 and private software builds

RHEL 9 is the shipping target; Rocky 9 remains the development option. Both
use the same appliance provisioners and local Grafana/HyperDX authentication.
The architecture remains **arm64**. This change does not add x86_64 support
or establish RHEL FIPS/STIG compliance through Rocky testing.

There are two software sources:

| Mode | Build-time software | Appliance boot |
|---|---|---|
| `internet` | Configured OS repositories, public container registries, Grafana plugin download | Baked images and plugin |
| `bundle` | A directory containing an RPM repository, image archives, and plugin files | Baked images and plugin |

The S3 download happens on the **Packer runner**, before provisioning. Packer
uploads the staged directory to the build instance over its existing SSH
connection. The instance does not need AWS CLI, S3 credentials, or a public
package repository to bootstrap the bundle. There is no fallback to public
repositories or image registries when a bundle is incomplete.

## Select the operating system

From the repository root, use Bash (Git Bash on Windows):

```bash
bash scripts/build-ami.sh --os rhel9
bash scripts/build-ami.sh --os rocky9
```

Use `-var 'source_ami_id=ami-YOUR_APPROVED_RHEL9_ARM64_IMAGE'` to select an
approved or account-local base explicitly. This bypasses the public name
and owner lookup. The provisioner verifies that the running OS matches the
selected RHEL/Rocky 9 target. Use an appropriately entitled RHEL base and
RHEL RPM content; do not reuse a Rocky RPM repository for RHEL.

Packer and its Amazon plugin must already be installed on a disconnected
runner. Install the plugin through your approved software distribution
process; do not run `packer init` expecting it to work without access to
the plugin distribution service. The wrapper does not install it for you.

## Bundle layout

Prepare one release bundle for each OS and architecture:

```text
bundle.env
rpm-repo/
  repodata/repomd.xml
  ... signed RPMs and repository metadata ...
keys/
  vendor.asc
images.tsv
images/
  clickhouse.tar
  grafana.tar
  hyperdx.tar
  mongo.tar
  vector.tar
grafana-plugins/
  grafana-clickhouse-datasource/
    plugin.json
    ... plugin files, signature and linux_arm64 backend ...
```

`bundle.env` contains literal values, not shell code:

```text
FORMAT_VERSION=1
OS_ID=rhel9
ARCH=arm64
```

Use `OS_ID=rocky9` for a Rocky bundle. `images.tsv` has one fully qualified
image reference and one relative archive filename per line, separated by
a literal tab. Use LF line endings for `bundle.env` and `images.tsv`.
The required appliance references are:

```text
docker.io/clickhouse/clickhouse-server:24.8
docker.io/grafana/grafana-oss:11.4.0
docker.hyperdx.io/hyperdx/hyperdx:2.19.0
docker.io/library/mongo:7.0
docker.io/timberio/vector:0.57.0-debian
```

On an approved connected preparation host, save each arm64 image with
`podman save --format docker-archive --output images/NAME.tar IMAGE_REFERENCE`.
Keep the exact reference in the archive and index. If your internal registry
uses a different name, retag the approved image to the appliance reference
before saving. Import uses `podman load`; it does not reconstruct images
from exported container filesystems.

The RPM repository must contain the required packages and dependency closure
for the **specific base AMI**. Include packages used by partitioning, baseline,
SCAP remediation and FIPS setup: `lvm2`, `parted`, `util-linux`, `gdisk`,
`podman`, `podman-plugins`, `chrony`, `rsync`, `policycoreutils`, `audit`,
`openssl`, `file`, `openscap-scanner`, `scap-security-guide`, and
`crypto-policies-scripts`, plus their dependencies and any intended updates.
Mirror entitled content using your approved RHEL repository process and
include valid repository metadata. A directory of arbitrary RPMs without
dependency closure is not sufficient. RPM signature checks stay enabled;
the bundle's `keys/*.asc` must match vendor key files already installed under
`/etc/pki/rpm-gpg` on the approved base AMI. A key supplied only by the bundle
does not establish trust in itself.

Include an approved Grafana ClickHouse datasource plugin release compatible
with Grafana 11.4.0 and Linux arm64. Preserve its signature and executable
backend permissions. Record the chosen plugin version when publishing the release.

## Package and stage the bundle

Paths inside the bundle must use letters, numbers, `_`, `-`, `.`, `+`, `@`, and `/`,
without spaces or parent traversal. Symlinks, hard links in tar archives,
special files and duplicate archive entries are rejected. From inside the
bundle directory, create an archive:

```bash
tar -czf ../ironlog-rhel9-arm64.tar.gz .
```

Store the archive in an S3 bucket your credentials can read, or copy it onto
local media. No checksum manifest or bucket-owner check is required. The
following commands only read artifacts; they do not create a bucket or
launch infrastructure.

For S3, using Python 3 and AWS CLI installed on the runner:

```bash
python scripts/prepare-artifacts.py \
  --source s3://YOUR-BUCKET/ironlog/releases/ironlog-rhel9-arm64.tar.gz \
  --profile YOUR_BUILD_PROFILE --region YOUR_REGION \
  --os rhel9 --output .decurion/artifacts/rhel9-release
```

The helper uses normal S3 access permissions; the bucket can be in another
account. It does not call STS to check ownership. Use `--endpoint-url` for a
custom S3 endpoint when necessary; TLS certificate verification remains enabled.

For a local archive:

```bash
python scripts/prepare-artifacts.py \
  --source /approved-media/ironlog-rhel9-arm64.tar.gz \
  --os rhel9 --output .decurion/artifacts/rhel9-release
```

For a local directory, use that directory as `--source`. Output must be a
new directory. The helper checks bundle structure, OS and image references
and does not overwrite an existing release.

## Build through private networking

Run Packer from a host that can reach the builder's private address. Use a
profile authorized to build in the target account. Supply the approved
base AMI, subnet and security group:

```bash
AWS_PROFILE=YOUR_BUILD_PROFILE bash scripts/build-ami.sh --os rhel9 \
  -var 'source_ami_id=ami-YOUR_APPROVED_RHEL9_ARM64_IMAGE' \
  -var 'software_source=bundle' \
  -var "artifact_bundle_dir=$(pwd)/.decurion/artifacts/rhel9-release" \
  -var 'aws_region=YOUR_REGION' \
  -var 'vpc_id=vpc-YOUR_VPC' \
  -var 'subnet_id=subnet-YOUR_PRIVATE_SUBNET' \
  -var 'security_group_id=sg-YOUR_BUILD_SG' \
  -var 'associate_public_ip_address=false' \
  -var 'ssh_interface=private_ip'
```

No NAT/public internet is needed for software in bundle mode. AWS control
plane connectivity is still required: the runner uses EC2 APIs to build the
AMI, and the S3 staging command uses S3. Provide private endpoints
and DNS/routing appropriate to your AWS partition. The runner's SSH path to
the builder is separate from S3 access. The build scripts do not create
endpoints or alter VPC routing.

The runner needs `s3:GetObject` for the archive and, for SSE-KMS, permission
to decrypt it with the relevant KMS key. Packer additionally needs its usual
EC2 build permissions. Use an endpoint policy and bucket policy restricted
to your approved account and prefix. Avoid static credentials inside bundles.

## Verification and remaining limits

Host preparation tests cover bundles without checksums, OS mismatch, unsafe
tar entries and S3 requests without owner checks. Provisioning tests use
mock package/container commands to exercise the offline path. These checks
are not a substitute for a real build with your approved RHEL base and RPM
mirror. Validate the finished appliance with internet egress denied, including
Grafana datasource queries and a reboot.

No AWS infrastructure is launched by the code change itself. The prior test
AMIs and snapshots were deleted at the operator's request; a fresh build is
required. The previously deferred Packer builder data-volume cleanup issue
remains separate: inspect and remove build-only leftover volumes after a
build without deleting appliance data or retained snapshots.

## Reference documentation

- [Packer Amazon EBS builder](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs)
- [S3 GetObject](https://docs.aws.amazon.com/cli/latest/reference/s3api/get-object.html)
- [Private S3 connectivity](https://docs.aws.amazon.com/AmazonS3/latest/userguide/privatelink-interface-endpoints.html)
- [Podman image archives](https://docs.podman.io/en/latest/markdown/podman-save.1.html)
