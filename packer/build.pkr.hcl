// Shared build block. Both amazon-ebs sources run through this SAME
// provisioner list — this is the "one shared source of truth" the RHEL/
// Rocky split (and any future Azure/OCI source) is built to reuse. Nothing
// AWS-specific appears below; every path referenced here is a repo path
// that another worker owns (see CLAUDE.md-adjacent task contract) — this
// template does not create those files, only calls them by path.

locals {
  # Documentation/parity only: the authoritative image list lives in
  # scripts/ami/20-container-images.sh (owned by another worker). Passed
  # through as an env var in case that script wants a single source of
  # truth to read from instead of hardcoding the list twice.
  container_images = join(" ", [
    "clickhouse/clickhouse-server:24.8",
    "postgres:16-alpine",
    "quay.io/keycloak/keycloak:26.0",
    "grafana/grafana-oss:11.4.0",
    "docker.hyperdx.io/hyperdx/hyperdx:2.19.0",
    "mongo:7.0",
    "quay.io/oauth2-proxy/oauth2-proxy:v7.15.3",
    "timberio/vector:0.57.0-debian",
  ])
}

build {
  name = "ironlog"

  sources = [
    "source.amazon-ebs.rhel9",
    "source.amazon-ebs.rocky9",
  ]

  # --- 1. disk layout / partitioning ---
  provisioner "shell" {
    script          = "${path.root}/../scripts/ami/00-partition.sh"
    execute_command = "sudo -E sh -c '{{ .Path }}'"
  }

  # --- 2. baseline packages, podman, dnf update ---
  provisioner "shell" {
    script          = "${path.root}/../scripts/ami/10-baseline.sh"
    execute_command = "sudo -E sh -c '{{ .Path }}'"
  }

  # --- 3. repo config -> /opt/ironlog/{clickhouse,grafana,keycloak,vector} ---
  # Stage as the SSH user under /tmp (file provisioner has no sudo of its
  # own), then move into place as root in one follow-up shell provisioner.
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /tmp/ironlog-stage",
      "sudo chown $(whoami) /tmp/ironlog-stage",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../clickhouse"
    destination = "/tmp/ironlog-stage/clickhouse"
  }
  provisioner "file" {
    source      = "${path.root}/../grafana"
    destination = "/tmp/ironlog-stage/grafana"
  }
  provisioner "file" {
    source      = "${path.root}/../keycloak"
    destination = "/tmp/ironlog-stage/keycloak"
  }
  provisioner "file" {
    source      = "${path.root}/../vector"
    destination = "/tmp/ironlog-stage/vector"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/ironlog",
      "sudo cp -r /tmp/ironlog-stage/clickhouse /opt/ironlog/clickhouse",
      "sudo cp -r /tmp/ironlog-stage/grafana /opt/ironlog/grafana",
      "sudo cp -r /tmp/ironlog-stage/keycloak /opt/ironlog/keycloak",
      "sudo cp -r /tmp/ironlog-stage/vector /opt/ironlog/vector",
      "sudo chown -R root:root /opt/ironlog",
      "sudo find /opt/ironlog -type d -exec chmod 0755 {} \\;",
      "sudo find /opt/ironlog -type f -exec chmod 0644 {} \\;",
      "sudo rm -rf /tmp/ironlog-stage/clickhouse /tmp/ironlog-stage/grafana /tmp/ironlog-stage/keycloak /tmp/ironlog-stage/vector",
    ]
  }

  # --- 4. quadlets/*.container + quadlets/*.network -> /etc/containers/systemd/ ---
  # Whole quadlets/ tree staged (it also has README.md and hyperdx/ which are
  # NOT unit files), then only *.container/*.network copied into the target
  # dir — matches the contract literally instead of assuming the directory
  # only ever contains unit files.
  provisioner "file" {
    source      = "${path.root}/../quadlets"
    destination = "/tmp/ironlog-stage/quadlets"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/containers/systemd",
      "sudo find /tmp/ironlog-stage/quadlets -maxdepth 1 -type f \\( -name '*.container' -o -name '*.network' \\) -exec cp {} /etc/containers/systemd/ \\;",
      "sudo chown -R root:root /etc/containers/systemd",
      "sudo chmod 0644 /etc/containers/systemd/*.container /etc/containers/systemd/*.network",
      "sudo rm -rf /tmp/ironlog-stage/quadlets",
    ]
  }

  # --- 5. scripts/firstboot/ -> /usr/local/lib/ironlog/ ---
  provisioner "file" {
    source      = "${path.root}/../scripts/firstboot"
    destination = "/tmp/ironlog-stage/firstboot"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /usr/local/lib/ironlog",
      "sudo cp -r /tmp/ironlog-stage/firstboot/. /usr/local/lib/ironlog/",
      "sudo chown -R root:root /usr/local/lib/ironlog",
      "sudo find /usr/local/lib/ironlog -type f -name '*.sh' -exec chmod 0755 {} \\;",
      "sudo rm -rf /tmp/ironlog-stage",
    ]
  }

  # --- 6. pre-pull all container images for air-gapped first boot ---
  provisioner "shell" {
    environment_vars = [
      "IRONLOG_CONTAINER_IMAGES=${local.container_images}",
      "IRONLOG_PULL_ARCH=arm64",
    ]
    script          = "${path.root}/../scripts/ami/20-container-images.sh"
    execute_command = "sudo -E sh -c '{{ .Vars }} {{ .Path }}'"
  }

  # --- 7. STIG hardening ---
  provisioner "shell" {
    script          = "${path.root}/../scripts/ami/30-stig.sh"
    execute_command = "sudo -E sh -c '{{ .Path }}'"
  }

  # --- 8. FIPS mode ---
  # See README.md "FIPS / Vector open risk" — this step is expected to
  # succeed at the OS level; whether Vector then starts cleanly with FIPS on
  # and no TLS configured is REASONED BUT UNTESTED, and only on real RHEL 9.
  provisioner "shell" {
    script          = "${path.root}/../scripts/ami/40-fips.sh"
    execute_command = "sudo -E sh -c '{{ .Path }}'"
  }

  # --- 8b. Reboot so FIPS mode actually takes effect ---
  # `fips-mode-setup --enable` only stages the change: it regenerates initramfs
  # and adds fips=1 to the kernel command line, but the running kernel is still
  # non-FIPS until reboot. Without this step the AMI would be snapshotted in a
  # staged-but-inactive state, and `fips-mode-setup --check` on a launched
  # instance would report FIPS enabled while the build never verified it.
  provisioner "shell" {
    inline            = ["sudo systemctl reboot"]
    expect_disconnect = true
  }

  # --- 8c. Confirm FIPS is live in the running kernel, post-reboot ---
  # Fail the build here rather than shipping an image that only looks hardened.
  provisioner "shell" {
    pause_before = "30s"
    inline = [
      "set -eu",
      "echo '[fips-verify] crypto.fips_enabled =' $(cat /proc/sys/crypto/fips_enabled)",
      "test \"$(cat /proc/sys/crypto/fips_enabled)\" = '1' || { echo '[fips-verify] FAIL: kernel is not in FIPS mode after reboot'; exit 1; }",
      "sudo fips-mode-setup --check",
    ]
  }

  # --- 9. log/ssh-key/cloud-init cleanup before snapshot ---
  provisioner "shell" {
    script          = "${path.root}/../scripts/ami/90-cleanup.sh"
    execute_command = "sudo -E sh -c '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
    custom_data = {
      build_git_sha = var.build_git_sha
      aws_region    = var.aws_region
    }
  }
}
