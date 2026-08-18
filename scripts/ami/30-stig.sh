#!/usr/bin/env bash
# scripts/ami/30-stig.sh — DISA STIG hardening via OpenSCAP / SCAP Security
# Guide, remediate + re-scan, evidence shipped in the image.
#
# Runs after images are pre-pulled (packer/build.pkr.hcl step 7), before FIPS.
#
# WHY oscap instead of hand-rolled sed: produces a machine-checkable XCCDF
# results file + a human-readable HTML report an assessor can open directly —
# that's the whole point of using SSG here rather than scripting individual
# `sysctl`/`sed` calls (see docs/control-mapping.md CM-6 row).
#
# ============================================================================
# POA&M — STIG rules tailored OUT of blind remediation, with rationale
# ============================================================================
# Blindly running `--remediate` against a host that must also run 8
# containerized services is how you get a STIG-compliant appliance that
# doesn't boot its own workload. The rules below are excluded from automatic
# remediation via an XCCDF tailoring file (built at runtime, see
# `build_tailoring_file` below) and handled explicitly instead. Rule IDs are
# the standard scap-security-guide RHEL 9 naming; confirm them against the
# *installed* ssg-rhel9-ds.xml version's <Rule id=...> attributes if this
# script's oscap invocation ever reports "rule not found" — SSG renumbers/
# renames rules between releases occasionally and this list cannot be
# verified against a live scan in this environment.
#
# 1. xccdf_org.ssgproject.content_rule_sysctl_net_ipv4_ip_forward
#    STIG wants net.ipv4.ip_forward=0 (host is not a router). Podman's
#    default bridge network (netavark, the ironlog-siem network in
#    quadlets/ironlog.network) REQUIRES ip_forward=1 for inter-container and
#    NAT/outbound traffic. CONFIRMED, well-known conflict. Handled: rule
#    tailored out, then this script explicitly sets
#    net.ipv4.ip_forward=1 via /etc/sysctl.d/99-ironlog-podman.conf (higher
#    lexical precedence than SSG's own drop-in) with a comment recording why.
#
# 2. Firewalld default-deny rules (the STIG "deny-all, allow-by-exception"
#    requirement, remediated via the firewalld service + default zone rules).
#    NOT tailored out — this is a real, wanted control, not a container
#    conflict to dodge. But SSG's remediation only turns firewalld on with a
#    default-deny zone; it has no idea about ironlog's own published ports.
#    Handled: after remediation, this script adds explicit firewalld rules
#    for the ports the quadlets publish (see quadlets/README.md's
#    compose-diff table): 8080 (keycloak), 3000 (grafana), 8081
#    (hyperdx-auth), 8088 (vector-hosts HEC), 6000 (vector-hosts agents).
#    ClickHouse's 8123/9000 and Keycloak's own container-to-container calls
#    stay loopback/bridge-internal and are NOT opened on the host firewall.
#    CROSS-TEAM FOLLOW-UP (not fixed here, out of scope — quadlets/ is owned
#    by another worker): none of the quadlet units declare
#    `After=firewalld.service`/`Wants=firewalld.service`, so on a fresh boot
#    there's a race where a quadlet's bridge/port-publish could come up
#    before firewalld has loaded the rules this script adds. Flagging for
#    whoever owns quadlets/ next.
#
# 3. Kernel module "unused filesystem" disable rules (cramfs, freevxfs, hfs,
#    hfsplus, jffs2, squashfs, udf — the actual DISA RHEL9 STIG "unused
#    filesystem" catalog). NOT tailored out — these do not touch `overlay`,
#    `bridge`, or `veth` (podman's storage/network kernel modules), so there
#    is no real conflict here despite how it might look at a glance. Called
#    out explicitly so nobody "fixes" a non-problem later. VERIFY on the
#    first real boot anyway: `lsmod | grep -E 'overlay|bridge|veth'` should
#    show all three loaded once podman starts a container.
#
# 4. Any world-writable-file / unauthorized-SUID remediation rules
#    (`file_permissions_unauthorized_world_writable`,
#    `file_permissions_ungroupowned` and similar). NOT tailored out (real,
#    wanted controls) but flagged: podman deliberately creates
#    group/world-permissive sockets and files under /run/user/*,
#    /run/containers, and /var/lib/containers in narrow, intentional spots
#    (rootless user namespaces, the podman.sock, etc.). This script cannot
#    enumerate the exact paths SSG's rule will touch without a live scan.
#    ACTION FOR THE OPERATOR: diff the post-remediation report
#    (/var/log/ironlog-build/stig-postremediate-report.html) against
#    `podman ps`/`systemctl status ironlog-*` on first real boot — if any
#    ironlog-* service fails to start after this step, check its journal for
#    permission-denied errors first, cross-reference against this rule
#    family before assuming it's unrelated.
#
# 5. `sysctl_user_max_user_namespaces` (some STIG/CIS overlays set
#    `user.max_user_namespaces=0` on hosts not expected to run containers).
#    UNVERIFIED whether the RHEL9 SSG `stig` profile (as opposed to a
#    Kubernetes/container-platform overlay profile) actually includes this
#    rule — could not confirm against a live scan in this environment. If
#    the post-remediation report shows it fired, user namespaces (needed for
#    rootless podman internals even when running as root) would break;
#    tailoring it out preemptively costs nothing if it turns out not to be
#    in-profile, so it's included in the tailoring file below defensively.
#
# 6. SELinux enforcing/targeted rules — NOT a conflict, not tailored out.
#    Podman is fully SELinux-aware; quadlets/README.md's "SELinux labelling"
#    section already documents the :Z/:ro,Z relabeling every bind mount
#    needs. This is confirmation, not a new finding.
#
# All six items above are also mirrored in scripts/ami/README.md.
# ============================================================================
set -euo pipefail

LOG_TAG="ironlog-stig"
log() { echo "[$LOG_TAG] $*"; }
warn() { echo "[$LOG_TAG] WARNING: $*" >&2; }
die() { echo "[$LOG_TAG] FATAL: $*" >&2; exit 1; }

. /etc/os-release
OS_ID="$ID"

EVIDENCE_DIR="/var/log/ironlog-build"
install -d -m 0750 -o root -g root "$EVIDENCE_DIR"

log "installing openscap-scanner + scap-security-guide"
dnf install -y openscap-scanner scap-security-guide

SSG_DS="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
if [ ! -f "$SSG_DS" ]; then
  die "expected SSG datastream not found at $SSG_DS — scap-security-guide package layout may have changed; check 'rpm -ql scap-security-guide | grep rhel9'"
fi

PROFILE_ID="xccdf_org.ssgproject.content_profile_stig"
if [ "$OS_ID" = "rocky" ]; then
  log "OS is Rocky Linux — the RHEL 9 SSG content applies directly (Rocky is a RHEL 9 rebuild, same package set/paths). Profile ID is identical ($PROFILE_ID); scap-security-guide does not ship a Rocky-specific profile name. STIG evidence from a Rocky build is FUNCTIONAL ONLY — see 40-fips.sh and README.md for why: Rocky carries no FIPS/STIG *certification*, only the same open-source remediation content. Real compliance evidence must come from a RHEL 9 build (see the operator's standing dev/ship convention)."
fi

build_tailoring_file() {
  local out="$1"
  cat > "$out" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<xccdf-1.2:Tailoring xmlns:xccdf-1.2="http://checklists.nist.gov/xccdf/1.2" id="xccdf_ironlog_tailoring_stig">
  <xccdf-1.2:benchmark href="$SSG_DS"/>
  <xccdf-1.2:version time="$(date -u +%Y-%m-%dT%H:%M:%SZ)">1</xccdf-1.2:version>
  <xccdf-1.2:Profile id="xccdf_ironlog_profile_stig_containers" extends="$PROFILE_ID">
    <xccdf-1.2:title>ironlog appliance STIG (container-compatible)</xccdf-1.2:title>
    <xccdf-1.2:description>
      Extends the stock RHEL 9 STIG profile, disabling rules that are
      documented as genuinely incompatible with running the ironlog podman
      quadlet workload. See scripts/ami/30-stig.sh header comment and
      scripts/ami/README.md for the rationale behind each exclusion.
    </xccdf-1.2:description>
    <xccdf-1.2:select idref="xccdf_org.ssgproject.content_rule_sysctl_net_ipv4_ip_forward" selected="false"/>
    <xccdf-1.2:select idref="xccdf_org.ssgproject.content_rule_sysctl_user_max_user_namespaces" selected="false"/>
  </xccdf-1.2:Profile>
</xccdf-1.2:Tailoring>
XML
}

TAILORING_FILE="$EVIDENCE_DIR/ironlog-tailoring.xml"
build_tailoring_file "$TAILORING_FILE"
TAILORED_PROFILE="xccdf_ironlog_profile_stig_containers"

log "running oscap remediation pass (profile=$TAILORED_PROFILE, tailoring=$TAILORING_FILE)"
set +e
oscap xccdf eval \
  --profile "$TAILORED_PROFILE" \
  --tailoring-file "$TAILORING_FILE" \
  --remediate \
  --results "$EVIDENCE_DIR/stig-remediate-results.xml" \
  --report "$EVIDENCE_DIR/stig-remediate-report.html" \
  "$SSG_DS"
remediate_rc=$?
set -e
# oscap exit codes: 0 = all pass, 2 = some rules failed (expected, common —
# not every rule is auto-remediable), 1 = a real tool error.
if [ "$remediate_rc" -eq 1 ]; then
  die "oscap remediation pass errored (exit 1) — see $EVIDENCE_DIR/stig-remediate-report.html"
fi
log "remediation pass done (oscap exit $remediate_rc; 2 = some rules non-remediable/failed, expected)"

# --- explicit fixups for tailored-out rules ---------------------------------
cat > /etc/sysctl.d/99-ironlog-podman.conf <<'EOF'
# Overrides SSG's STIG remediation of net.ipv4.ip_forward=0. Podman's bridge
# network (netavark) requires forwarding for inter-container and outbound
# NAT traffic. See scripts/ami/30-stig.sh POA&M item 1.
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-ironlog-podman.conf >/dev/null
log "net.ipv4.ip_forward=1 pinned via /etc/sysctl.d/99-ironlog-podman.conf (podman networking requirement)"

if systemctl is-active firewalld >/dev/null 2>&1; then
  log "firewalld active (per STIG remediation) — opening ironlog published ports"
  for p in 8080/tcp 3000/tcp 8081/tcp 8088/tcp 6000/tcp; do
    firewall-cmd --permanent --add-port="$p" >/dev/null
  done
  firewall-cmd --reload >/dev/null
  log "firewalld: opened 8080,3000,8081,8088,6000 (keycloak, grafana, hyperdx-auth, vector-hosts HEC+agents)"
else
  warn "firewalld not active after STIG remediation — expected if the stig profile in this SSG build doesn't include the firewalld rule, or the package wasn't installed. Ports were NOT explicitly opened; podman's own port publishing (iptables/nftables via CNI) is what's actually gating reachability in that case."
fi

log "running post-remediation evidence scan (non-remediating)"
set +e
oscap xccdf eval \
  --profile "$TAILORED_PROFILE" \
  --tailoring-file "$TAILORING_FILE" \
  --results "$EVIDENCE_DIR/stig-postremediate-results.xml" \
  --report "$EVIDENCE_DIR/stig-postremediate-report.html" \
  "$SSG_DS"
scan_rc=$?
set -e
[ "$scan_rc" -ne 1 ] || die "oscap post-remediation evidence scan errored (exit 1)"

cp "$SSG_DS" "$EVIDENCE_DIR/ssg-rhel9-ds.xml" 2>/dev/null || true
chmod -R 0640 "$EVIDENCE_DIR"/*.xml "$EVIDENCE_DIR"/*.html 2>/dev/null || true
chmod 0750 "$EVIDENCE_DIR"

log "STIG evidence written to $EVIDENCE_DIR (remediate-*, postremediate-*, ironlog-tailoring.xml, ssg-rhel9-ds.xml copy). NOT removed by 90-cleanup.sh."
log "STIG hardening pass complete (OS=$OS_ID, profile=$TAILORED_PROFILE)"
