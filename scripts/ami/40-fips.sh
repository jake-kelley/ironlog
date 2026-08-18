#!/usr/bin/env bash
# scripts/ami/40-fips.sh — enable FIPS mode.
#
# Runs after STIG hardening (packer/build.pkr.hcl step 8), before cleanup.
#
# REBOOT REQUIREMENT: `fips-mode-setup --enable` rewrites the kernel command
# line (adds fips=1, regenerates the initramfs with dracut --fips) but does
# NOT take effect until the next boot — the running kernel stays non-FIPS
# for the rest of THIS provisioning session. CHECKED: packer/build.pkr.hcl
# (read in full) has no reboot provisioner anywhere in its list — steps 8
# (this script) and 9 (90-cleanup.sh) both run against the same
# not-yet-rebooted kernel. This is a GENUINE GAP in packer/, reported here
# per task scope rather than fixed there:
#   - Packer's shell provisioner has no built-in "reboot and reconnect"
#     primitive for Linux the way `windows-restart` provides for Windows.
#     The standard pattern is a small inline shell provisioner
#     (`reboot; sleep 5`) combined with `expect_disconnect = true` and
#     `pause_before` on the NEXT provisioner, OR the community
#     `packer-provisioner-windows-restart`-style approach ported to Linux
#     via a raw `reboot` + a following provisioner that just waits for SSH.
#   - Until packer/build.pkr.hcl adds that step (after step 8, before step
#     9 ideally, so cleanup and the AMI snapshot capture a rebooted,
#     FIPS-active system), every AMI this template produces is registered
#     from an instance that ENABLED FIPS but never actually BOOTED under it.
#     `fips-mode-setup --check` will report enabled-pending-reboot, not
#     active, at snapshot time.
#   - Whoever owns packer/build.pkr.hcl next should add a reboot provisioner
#     between steps 8 and 9. Not fixed here (packer/ is out of scope for
#     this worker).
set -euo pipefail

LOG_TAG="ironlog-fips"
log() { echo "[$LOG_TAG] $*"; }
warn() { echo "[$LOG_TAG] WARNING: $*" >&2; }

. /etc/os-release
OS_ID="$ID"

command -v fips-mode-setup >/dev/null || { echo "[$LOG_TAG] FATAL: fips-mode-setup not found (crypto-policies-scripts package missing?)" >&2; exit 1; }

if fips-mode-setup --check >/dev/null 2>&1; then
  log "FIPS mode already enabled (fips-mode-setup --check passed) — idempotent no-op"
else
  log "enabling FIPS mode (fips-mode-setup --enable) — takes effect on next boot, see header comment"
  fips-mode-setup --enable
fi

if [ "$OS_ID" = "rhel" ]; then
  cat <<'EOF'
[ironlog-fips] RHEL 9: FIPS mode uses Red Hat's CMVP-validated cryptographic
modules:
  - OpenSSL:      certs #4746 / #4857
  - GnuTLS:       certs #4780 / #4846
  - Kernel Crypto API: certs #4796 / #5034
This is the ONLY build path from which FIPS compliance evidence should be
drawn for an assessor.
EOF
elif [ "$OS_ID" = "rocky" ]; then
  cat <<'EOF' >&2
[ironlog-fips] *** ROCKY LINUX FIPS WARNING ***
FIPS mode turns ON (same fips=1 kernel flag, same dracut --fips initramfs
mechanism) but Rocky Linux carries NONE of Red Hat's CMVP module
certificates (#4746/#4857 OpenSSL, #4780/#4846 GnuTLS, #4796/#5034 Kernel
Crypto). A Rocky 9 build with this script run is FUNCTIONAL TESTING ONLY —
it proves the appliance's own code paths tolerate FIPS mode being on, NOT
that the cryptography is validated. NEVER present a Rocky-build artifact
(scan report, `fips-mode-setup --check` output, or otherwise) as FIPS
compliance evidence to an assessor. All such evidence must come from a real
RHEL 9 build, per the operator's standing dev/ship convention
(Rocky = dev/iteration, RHEL = shipping + anything compliance-touching).
EOF
fi

# --- KNOWN RISK: Vector + FIPS + TLS -----------------------------------
# Vector's system-OpenSSL build is broken on FIPS-enabled kernels: PKCS12KDF
# is not a FIPS-approved KDF, and Vector calls into it during TLS setup even
# when TLS config looks unrelated. Open upstream issues, unresolved as of
# this writing:
#   - https://github.com/vectordotdev/vector/issues/23147
#   - https://github.com/vectordotdev/vector/issues/21232
#
# DESIGNED MITIGATION (implemented in intent, NOT verified against a running
# instance): remove TLS from Vector's own config entirely.
#   - Inbound agent TLS (Linux/Windows agents -> :6000, K8s HEC -> :8088)
#     terminates at nginx or stunnel on loopback in front of Vector, not in
#     Vector itself.
#   - Outbound TLS to AWS (S3/SQS for the CloudTrail/GuardDuty/VPC
#     Flow/S3 Access sources) goes through a forward proxy, not Vector's own
#     TLS stack.
#   - The ClickHouse sink is already loopback-only, plaintext HTTP
#     (see CLAUDE.md's Vector clickhouse-sink healthcheck note) — no TLS
#     there regardless of FIPS.
#
# WHETHER VECTOR STARTS CLEANLY WITH FIPS ON AND NO TLS CONFIGURED IS
# REASONED BUT UNTESTED. This could not be verified in this session: no
# live instance, no reboot (see header comment above — FIPS isn't even
# ACTIVE yet on the instance this script runs against, only staged for next
# boot), and per the operator's standing convention this test is only valid
# on real RHEL 9, never Rocky.
#
# TODO(real RHEL 9 build, post-reboot): run and record the output of:
#   systemctl status ironlog-vector.service ironlog-vector-hosts.service
#   journalctl -u ironlog-vector.service -u ironlog-vector-hosts.service --no-pager -n 200
# and confirm no PKCS12KDF / FIPS self-test errors appear before trusting
# this mitigation in production.
warn "Vector-under-FIPS-with-no-TLS is REASONED BUT UNTESTED — see TODO above. Not something this script can verify (no reboot has happened yet)."

log "FIPS provisioning step complete (OS=$OS_ID). fips-mode-setup --check will report the true state only after the caller reboots the instance."
