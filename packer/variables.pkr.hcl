// Variable declarations for the ironlog appliance build.
// Defaults are safe for a commercial us-east-1 dev build. Override via
// variables.auto.pkrvars.hcl (copy from the .example file) or -var.

# --- region / partition -----------------------------------------------------

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = <<-EOT
    Commercial AWS region to build in. For GovCloud, override to
    us-gov-west-1 or us-gov-east-1 AND point the AWS credentials/profile at a
    GovCloud account (GovCloud is a separate partition with its own IAM
    principals — a commercial-account profile cannot see it). C2S/SC2S build
    in their own isolated partitions with their own endpoint/credential
    wiring; this template does not attempt to special-case them beyond the
    region variable — treat any C2S/SC2S build as needing an operator with
    access to that enclave to supply region/endpoint/AMI-owner overrides.
    See README.md "GovCloud" section.
  EOT
}

variable "instance_type" {
  type        = string
  default     = "c7g.xlarge"
  description = <<-EOT
    Graviton (aarch64) build instance. The shipping appliance targets r8g at
    runtime, but the BUILD instance only needs to run the provisioners
    (partitioning, package install, pulling 8 container images, STIG/FIPS
    scripts) — it doesn't need r8g's memory profile. c7g.xlarge (4 vCPU,
    8 GiB, Nitro/ENA, up to 12.5 Gbps network) is comfortably enough to pull
    ~8 arm64 images in parallel without being memory-bound, and is
    substantially cheaper per build-hour than r8g. Bump to c7g.2xlarge if
    image-pull steps are network-bound in your account/region.
  EOT
}

# --- source AMI selection (by filter, not hardcoded id) ---------------------

variable "rhel_ami_owner" {
  type        = string
  default     = "309956199498"
  description = <<-EOT
    Red Hat's official AWS account ID for RHEL AMIs (commercial partition).
    Given by the task spec; not independently re-verified here. CONFIRM this
    owner ID resolves AMIs in GovCloud too before a GovCloud build — Red
    Hat's GovCloud-partition account ID is not guaranteed to be the same
    number and was not verified in this session.
  EOT
}

variable "rhel_ami_name_filter" {
  type        = string
  default     = "RHEL-9*_HVM-*-arm64-*"
  description = "Name filter for official RHEL 9 aarch64 AMIs, most-recent selected by creation date."
}

variable "rocky_ami_owner" {
  type        = string
  default     = "792107900819"
  description = <<-EOT
    Rocky Linux's own AWS account ID for publicly-shared (non-Marketplace)
    AMIs. VERIFY BEFORE FIRST BUILD: this value comes from Rocky Linux
    community/forum sources cross-checked in this session (rockylinux.org
    itself lists "Cloud Images" but this session did not load that page
    directly), not a primary rockylinux.org document read end-to-end. A
    second AWS account, 679593333241, distributes Rocky 9 through AWS
    Marketplace (subscription-gated, not a pure public AMI) — do not
    substitute it here without adding Marketplace subscription handling.
    Confirm with:
      aws ec2 describe-images --owners 792107900819 \
        --filters "Name=name,Values=Rocky-9-*-aarch64-*" \
        --query 'Images[*].[ImageId,Name,CreationDate]' --output table
    before relying on this for real dev builds.
  EOT
}

variable "rocky_ami_name_filter" {
  type        = string
  default     = "Rocky-9-*-aarch64-*"
  description = "Name filter for official Rocky Linux 9 aarch64 AMIs, most-recent selected by creation date."
}

variable "rhel_ssh_username" {
  type        = string
  default     = "ec2-user"
}

variable "rocky_ssh_username" {
  type        = string
  default     = "rocky"
}

# --- volumes -----------------------------------------------------------------

variable "root_volume_size" {
  type        = number
  default     = 60
  description = "Root (OS) EBS volume size in GiB, gp3. Holds STIG-required separate partitions (see scripts/ami/00-partition.sh). 30 GiB is NOT enough: the STIG LV layout alone carves ~26 GiB, before the base OS, the baked /opt/ironlog config, ~8 pre-pulled container images, and the STIG scan evidence written into the image."
}

variable "data_volume_size" {
  type        = number
  default     = 100
  description = <<-EOT
    Size in GiB, gp3, of the SECOND EBS volume carrying appliance data
    (/var/lib/ironlog — ClickHouse data, Grafana/Keycloak/HyperDX state,
    Vector disk buffers). Declared as a launch_block_device_mapping, not
    baked into the AMI's own snapshot, so it can be resized/snapshotted
    independently and survives an AMI rebuild.
  EOT
}

variable "root_volume_throughput" {
  type        = number
  default     = 125
  description = "gp3 throughput (MiB/s) for the root volume."
}

variable "data_volume_throughput" {
  type        = number
  default     = 250
  description = "gp3 throughput (MiB/s) for the data volume — higher than root since ClickHouse/Vector are the write-heavy tenants."
}

variable "data_volume_iops" {
  type        = number
  default     = 3000
  description = "gp3 baseline IOPS for the data volume."
}

variable "encrypt_volumes" {
  type        = bool
  default     = true
  description = "Encrypt both EBS volumes at rest. Leave true for anything compliance-touching; kms_key_id below to use a CMK instead of the account default key."
}

variable "kms_key_id" {
  type        = string
  default     = ""
  description = "Optional CMK ARN/ID for EBS encryption. Empty string uses the account's default aws/ebs key."
}

# --- networking ---------------------------------------------------------------

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC to build in. Empty string lets the amazon-ebs builder pick the account's default VPC."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet to build in (must have a route to the internet, directly or via NAT, so yum/dnf and the container pulls in step 6 can reach their sources at BUILD time). Empty string lets the builder pick."
}

variable "associate_public_ip_address" {
  type        = bool
  default     = true
  description = "Whether the build instance gets a public IP for Packer's SSH connection. Set false + use a bastion/SSM if your subnet is private-only."
}

# --- AMI metadata ---------------------------------------------------------------

variable "ami_name_prefix" {
  type        = string
  default     = "ironlog"
}

variable "ami_description" {
  type        = string
  default     = "ironlog SIEM all-in-one appliance"
}

variable "build_git_sha" {
  type        = string
  default     = "unknown"
  description = "Short git SHA of the commit being built, for the build-git-sha tag. Pass with -var build_git_sha=$(git rev-parse --short HEAD)."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags merged into every source/snapshot/AMI tag set."
}

variable "ami_regions" {
  type        = list(string)
  default     = []
  description = "Optional additional regions to copy the finished AMI to (amazon-ebs ami_regions). Empty = build region only."
}
