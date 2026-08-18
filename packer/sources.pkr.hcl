// Source (builder) definitions. Both aarch64 amazon-ebs builders point at
// the SAME build block (see build.pkr.hcl) so provisioning never forks.

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")

  common_tags = merge({
    Project       = "ironlog"
    ManagedBy     = "packer"
    build-git-sha = var.build_git_sha
  }, var.extra_tags)
}

# --- RHEL 9 aarch64 — shipping image (GovCloud / C2S / SC2S) ----------------

source "amazon-ebs" "rhel9" {
  region        = var.aws_region
  instance_type = var.instance_type
  vpc_id        = var.vpc_id != "" ? var.vpc_id : null
  subnet_id     = var.subnet_id != "" ? var.subnet_id : null

  associate_public_ip_address = var.associate_public_ip_address
  ssh_username                = var.rhel_ssh_username
  communicator                = "ssh"

  ena_support = true
  # sriov_net_support intentionally omitted: it's the legacy Xen "simple"
  # enhanced-networking flag. Graviton/Nitro instance families (c7g/m7g/r8g)
  # are ENA-only; ena_support above is the correct (and sufficient) setting.

  source_ami_filter {
    owners      = [var.rhel_ami_owner]
    most_recent = true
    filters = {
      name                = var.rhel_ami_name_filter
      architecture        = "arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
  }

  ami_name                = "${var.ami_name_prefix}-rhel9-${local.timestamp}"
  ami_description         = "${var.ami_description} (RHEL 9, aarch64) sha=${var.build_git_sha}"
  ami_regions             = var.ami_regions
  ami_virtualization_type = "hvm"
  encrypt_boot            = var.encrypt_volumes
  kms_key_id              = var.kms_key_id != "" ? var.kms_key_id : null

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    throughput            = var.root_volume_throughput
    delete_on_termination = true
    encrypted             = var.encrypt_volumes
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
  }

  # Second, independently-manageable volume for /var/lib/ironlog. NOT baked
  # into the AMI snapshot beyond this launch spec — every instance launched
  # from this AMI gets a fresh volume of this size/type, resizable and
  # snapshottable on its own. See scripts/ami/00-partition.sh for the
  # in-guest filesystem/mount setup and README.md "Disk layout" for why this
  # must stay a second device rather than a root-volume partition.
  launch_block_device_mappings {
    device_name           = "/dev/sdb"
    volume_type           = "gp3"
    volume_size           = var.data_volume_size
    iops                  = var.data_volume_iops
    throughput            = var.data_volume_throughput
    delete_on_termination = false
    encrypted             = var.encrypt_volumes
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
  }

  tags = merge(local.common_tags, {
    Name     = "${var.ami_name_prefix}-rhel9-${local.timestamp}"
    OS       = "rhel9"
    Shipping = "true"
  })

  snapshot_tags = merge(local.common_tags, {
    OS = "rhel9"
  })

  run_tags = merge(local.common_tags, {
    Name = "${var.ami_name_prefix}-rhel9-builder-${local.timestamp}"
  })
}

# --- Rocky Linux 9 aarch64 — local dev build --------------------------------
#
# Chosen over a QEMU/vagrant dev loop so the dev and shipping paths run
# through the SAME builder plugin, the SAME source_ami_filter mechanism, and
# the SAME provisioner list — the only difference is which AMI account/name
# filter resolves. A QEMU builder would need its own base-image pipeline
# (no official Rocky 9 aarch64 qcow2/vagrant box pairing is as
# turn-key as "filter the AWS AMI catalog"), a different provisioner
# environment (no EBS block device mapping to test the data-volume contract
# against), and would drift from the AWS-specific pieces (block device
# mappings, tags, manifest) that most need day-to-day testing before a real
# RHEL build. The tradeoff is real: this dev loop needs AWS credentials and
# costs money per iteration, where a local VM would be free and offline. If
# that becomes painful, revisit a `qemu` source for pure config-rendering /
# provisioner-script iteration that doesn't touch AWS-specific blocks (see
# README.md "Dev loop alternative").

source "amazon-ebs" "rocky9" {
  region        = var.aws_region
  instance_type = var.instance_type
  vpc_id        = var.vpc_id != "" ? var.vpc_id : null
  subnet_id     = var.subnet_id != "" ? var.subnet_id : null

  associate_public_ip_address = var.associate_public_ip_address
  ssh_username                = var.rocky_ssh_username
  communicator                = "ssh"

  ena_support = true

  source_ami_filter {
    owners      = [var.rocky_ami_owner]
    most_recent = true
    filters = {
      name                = var.rocky_ami_name_filter
      architecture        = "arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
  }

  ami_name                = "${var.ami_name_prefix}-rocky9-dev-${local.timestamp}"
  ami_description         = "${var.ami_description} (Rocky 9 dev build, aarch64) sha=${var.build_git_sha}"
  ami_regions             = var.ami_regions
  ami_virtualization_type = "hvm"
  encrypt_boot            = var.encrypt_volumes
  kms_key_id              = var.kms_key_id != "" ? var.kms_key_id : null

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    throughput            = var.root_volume_throughput
    delete_on_termination = true
    encrypted             = var.encrypt_volumes
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
  }

  launch_block_device_mappings {
    device_name           = "/dev/sdb"
    volume_type           = "gp3"
    volume_size           = var.data_volume_size
    iops                  = var.data_volume_iops
    throughput            = var.data_volume_throughput
    delete_on_termination = false
    encrypted             = var.encrypt_volumes
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
  }

  tags = merge(local.common_tags, {
    Name     = "${var.ami_name_prefix}-rocky9-dev-${local.timestamp}"
    OS       = "rocky9"
    Shipping = "false"
  })

  snapshot_tags = merge(local.common_tags, {
    OS = "rocky9"
  })

  run_tags = merge(local.common_tags, {
    Name = "${var.ami_name_prefix}-rocky9-builder-${local.timestamp}"
  })
}

# --- Multi-cloud extension stub (NOT active) --------------------------------
# Do not uncomment until Azure/OCI are an actual requirement (see README.md
# "Multi-cloud extension path"). When that day comes:
#   1. add the plugin under required_plugins in ironlog.pkr.hcl
#      (github.com/hashicorp/azure, github.com/hashicorp/oracle)
#   2. add a source block below following this same shape (region/image
#      filter/disk vars, no provisioner-specific logic)
#   3. add the new source to the `sources = [...]` list in build.pkr.hcl
# Nothing else changes — every provisioner in build.pkr.hcl is already
# cloud-agnostic (paths and shell commands only, no aws_* references outside
# the source blocks themselves).
#
# source "azure-arm" "rhel9" {
#   # subscription_id, client_id, client_secret, tenant_id via env/CLI auth
#   # managed_image_resource_group_name = var.azure_resource_group
#   # managed_image_name                = "${var.ami_name_prefix}-rhel9-${local.timestamp}"
#   # os_type                           = "Linux"
#   # image_publisher = "RedHat" / image_offer = "RHEL" / image_sku = "9-arm64-..."
#   # vm_size                           = "Standard_D4ps_v5"  # Ampere Altra arm64
# }
#
# source "oracle-oci" "rhel9" {
#   # availability_domain, compartment_ocid, subnet_ocid via variables
#   # base_image_filter { operating_system = "Red Hat Enterprise Linux" ... }
#   # shape = "VM.Standard.A1.Flex"  # Ampere arm64
# }
