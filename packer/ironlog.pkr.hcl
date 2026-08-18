// ironlog appliance image build — Packer entrypoint.
//
// Two builders share one provisioner list (see build.pkr.hcl):
//   amazon-ebs.rhel9   RHEL 9 aarch64 — shipping image (GovCloud/C2S/SC2S)
//   amazon-ebs.rocky9  Rocky Linux 9 aarch64 — local dev/iteration image
//
// Build one at a time with -only, e.g.:
//   packer build -only=amazon-ebs.rhel9 -var-file=variables.auto.pkrvars.hcl packer/
//   packer build -only=amazon-ebs.rocky9 packer/
//
// See README.md for required variables, IAM permissions, and open risks.

packer {
  required_version = ">= 1.9.0"

  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}
