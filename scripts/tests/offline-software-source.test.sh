#!/usr/bin/env bash
# Offline source tests: validation must precede mutations; valid bundle stays local.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source_script="$root/scripts/ami/05-software-source.sh"
images_script="$root/scripts/ami/20-container-images.sh"
mkdir -p "$root/.decurion"
tmp="$(mktemp -d "$root/.decurion/offline-source-test.XXXXXX")"
cleanup() {
  local resolved
  resolved=$(cd "$tmp" && pwd -P)
  case "$resolved" in
    "$root"/.decurion/offline-source-test.*) rm -rf -- "$resolved" ;;
    *) echo 'refusing cleanup outside test workspace' >&2 ;;
  esac
}
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/etc/pki/rpm-gpg" "$tmp/etc/dnf"
cat > "$tmp/os-release" <<'EOF'
ID=rocky
VERSION_ID=9.6
EOF
printf 'original-dnf-config\n' > "$tmp/etc/dnf/dnf.conf"
printf 'vendor-key\n' > "$tmp/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial"
cat > "$tmp/bin/dnf" <<'EOF'
#!/usr/bin/env bash
echo "dnf $*" >> "$MOCK_LOG"
EOF
cat > "$tmp/bin/rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "$MOCK_LOG"
EOF
cat > "$tmp/bin/install" <<'EOF'
#!/usr/bin/env bash
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in -o|-g|-m) shift 2;; -d) shift;; *) args+=("$1"); shift;; esac
done
mkdir -p "${args[@]}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/chown"
printf '#!/usr/bin/env bash\necho "ELF 64-bit LSB executable, ARM aarch64"\n' > "$tmp/bin/file"
cat > "$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$MOCK_LOG"
case "${1:-}" in
  load) [ "${PODMAN_LOAD_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  image) case "${2:-}" in inspect) printf '%s\n' "${PODMAN_ARCH:-arm64}";; exists) exit 0;; esac ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "aarch64\\n"\n' > "$tmp/bin/uname"
chmod +x "$tmp/bin/dnf" "$tmp/bin/rpm" "$tmp/bin/install" "$tmp/bin/chown" "$tmp/bin/file" "$tmp/bin/podman" "$tmp/bin/uname"
make_bundle() {
  local bundle="$1" image archive
  mkdir -p "$bundle/rpm-repo/repodata" "$bundle/keys" "$bundle/images" "$bundle/grafana-plugins/grafana-clickhouse-datasource"
  printf 'FORMAT_VERSION=1\nOS_ID=rocky9\nARCH=arm64\n' > "$bundle/bundle.env"
  printf '<repomd/>\n' > "$bundle/rpm-repo/repodata/repomd.xml"
  printf 'rpm\n' > "$bundle/rpm-repo/libstdc++-1.0+bundle.aarch64.rpm"
  printf 'vendor-key\n' > "$bundle/keys/vendor.asc"
  printf '{"id":"grafana-clickhouse-datasource","executable":"plugin"}\n' > "$bundle/grafana-plugins/grafana-clickhouse-datasource/plugin.json"
  printf '#!/bin/sh\n' > "$bundle/grafana-plugins/grafana-clickhouse-datasource/plugin"; chmod +x "$bundle/grafana-plugins/grafana-clickhouse-datasource/plugin"
  : > "$bundle/images.tsv"
  for image in docker.io/clickhouse/clickhouse-server:24.8 docker.io/grafana/grafana-oss:11.4.0 docker.hyperdx.io/hyperdx/hyperdx:2.19.0 docker.io/library/mongo:7.0 docker.io/timberio/vector:0.57.0-debian; do
    archive="images/${image//[\/:]/_}.tar"; printf '%s\n' "$image" > "$bundle/$archive"; printf '%s\t%s\n' "$image" "$archive" >> "$bundle/images.tsv"
  done
  (cd "$bundle" && find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum > SHA256SUMS)
}
base_env=(PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls" IRONLOG_SOFTWARE_SOURCE=bundle IRONLOG_EXPECTED_OS=rocky9 IRONLOG_OS_RELEASE_FILE="$tmp/os-release" IRONLOG_SYSTEM_ETC_DIR="$tmp/etc" IRONLOG_IRONLOG_ETC_DIR="$tmp/ironlog")
run_source() { env "${base_env[@]}" IRONLOG_ARTIFACT_DIR="$1" bash "$source_script"; }
run_fail() {
  : > "$tmp/calls"
  if run_source "$1" >/dev/null 2>&1; then echo "expected failure: $2" >&2; exit 1; fi
  [ ! -s "$tmp/calls" ] || { echo "mutation happened before validation: $2" >&2; exit 1; }
}
run_fail "$tmp/missing" missing-artifact
mkdir -p "$tmp/bad"; printf 'FORMAT_VERSION=1\nOS_ID=rocky9\nARCH=arm64\n' > "$tmp/bad/bundle.env"; printf '%064d  bundle.env\n' 0 > "$tmp/bad/SHA256SUMS"
run_fail "$tmp/bad" bad-checksum
make_bundle "$tmp/special"
if mkfifo "$tmp/special/not-a-file" 2>/dev/null; then
  run_fail "$tmp/special" special-file
else
  echo 'FIFO fixture unavailable on this host; special-file case requires Linux'
fi
make_bundle "$tmp/bundle"
: > "$tmp/calls"
run_source "$tmp/bundle"
grep -Fx 'original-dnf-config' "$tmp/ironlog/dnf.conf.pre-bundle" >/dev/null
grep -Fx "reposdir=$tmp/ironlog/dnf.repos.d" "$tmp/etc/dnf/dnf.conf" >/dev/null
grep -Fx 'plugins=0' "$tmp/etc/dnf/dnf.conf" >/dev/null
grep -Fx 'gpgcheck=1' "$tmp/etc/dnf/dnf.conf" >/dev/null
grep -Fx 'repo_gpgcheck=0' "$tmp/etc/dnf/dnf.conf" >/dev/null
[ "$(find "$tmp/ironlog/dnf.repos.d" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
grep -F -- '--disablerepo=* --enablerepo=ironlog-bundle --setopt=plugins=0 --setopt=gpgcheck=1 --setopt=repo_gpgcheck=0 install -y lvm2 parted util-linux gdisk' "$tmp/calls" >/dev/null
grep -F 'rpm --import' "$tmp/calls" >/dev/null
env "${base_env[@]}" IRONLOG_ARTIFACT_DIR="$tmp/bundle" IRONLOG_BUILD_SOURCE_CONFIG="$tmp/ironlog/build-source.conf" IRONLOG_GRAFANA_PLUGIN_DIR="$tmp/plugin-stage" IRONLOG_QUADLET_DIR="$root/quadlets" bash "$images_script"
[ -f "$tmp/plugin-stage/grafana-clickhouse-datasource/plugin.json" ]
[ -x "$tmp/plugin-stage/grafana-clickhouse-datasource/plugin" ]
[ "$(grep -c '^podman load --input ' "$tmp/calls")" -eq 5 ]
! grep -F 'podman pull ' "$tmp/calls" >/dev/null
if env "${base_env[@]}" PODMAN_ARCH=amd64 IRONLOG_ARTIFACT_DIR="$tmp/bundle" IRONLOG_BUILD_SOURCE_CONFIG="$tmp/ironlog/build-source.conf" IRONLOG_GRAFANA_PLUGIN_DIR="$tmp/plugin-stage-bad" IRONLOG_QUADLET_DIR="$tmp/no-quadlets" bash "$images_script" >/dev/null 2>&1; then
  echo 'expected wrong-architecture image failure' >&2; exit 1
fi
if env "${base_env[@]}" PODMAN_LOAD_FAIL=1 IRONLOG_ARTIFACT_DIR="$tmp/bundle" IRONLOG_BUILD_SOURCE_CONFIG="$tmp/ironlog/build-source.conf" IRONLOG_GRAFANA_PLUGIN_DIR="$tmp/plugin-stage-load-fail" IRONLOG_QUADLET_DIR="$tmp/no-quadlets" bash "$images_script" >/dev/null 2>&1; then
  echo 'expected image-load failure' >&2; exit 1
fi
# Same provisioning entry point accepts RHEL 9, but not a Rocky bundle on RHEL.
printf 'ID=rhel\nVERSION_ID=9.6\n' > "$tmp/os-release"
: > "$tmp/calls"
if env "${base_env[@]}" IRONLOG_EXPECTED_OS=rhel9 IRONLOG_ARTIFACT_DIR="$tmp/bundle" bash "$source_script" >/dev/null 2>&1; then
  echo 'expected RHEL/Rocky bundle mismatch failure' >&2; exit 1
fi
[ ! -s "$tmp/calls" ] || { echo 'OS mismatch mutated package state' >&2; exit 1; }
printf 'FORMAT_VERSION=1\nOS_ID=rhel9\nARCH=arm64\n' > "$tmp/bundle/bundle.env"
(cd "$tmp/bundle" && find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum > SHA256SUMS)
env "${base_env[@]}" IRONLOG_EXPECTED_OS=rhel9 IRONLOG_ARTIFACT_DIR="$tmp/bundle" bash "$source_script"
grep -Fx 'original-dnf-config' "$tmp/ironlog/dnf.conf.pre-bundle" >/dev/null
echo "offline software-source integration: PASS"
