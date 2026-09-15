#!/usr/bin/env bash
# Validate offline bundle before any DNF or Podman mutation, then select DNF source.
set -euo pipefail
log() { echo "[ironlog-source] $*"; }
die() { echo "[ironlog-source] FATAL: $*" >&2; exit 1; }
source_mode="${IRONLOG_SOFTWARE_SOURCE:-internet}"
artifact_dir="${IRONLOG_ARTIFACT_DIR:-/opt/ironlog-artifacts}"
expected_os="${IRONLOG_EXPECTED_OS:-}"
[ "$source_mode" = internet ] || [ "$source_mode" = bundle ] || die "IRONLOG_SOFTWARE_SOURCE must be internet or bundle"
[ "$expected_os" = rhel9 ] || [ "$expected_os" = rocky9 ] || die "IRONLOG_EXPECTED_OS must be rhel9 or rocky9"
. "${IRONLOG_OS_RELEASE_FILE:-/etc/os-release}"
actual_os="${ID}${VERSION_ID%%.*}"
[ "$actual_os" = "$expected_os" ] || die "host OS is $ID $VERSION_ID, expected $expected_os"
host_arch="$(uname -m)"
[ "$host_arch" = aarch64 ] || [ "$host_arch" = arm64 ] || die "host architecture is $host_arch, expected aarch64/arm64"
validate_relative() { case "$1" in ''|/*|*'//'*) return 1;; esac; local p; IFS=/ read -r -a p <<<"$1"; for x in "${p[@]}"; do [ -n "$x" ] && [ "$x" != . ] && [ "$x" != .. ] || return 1; done; }
validate_bundle() {
  [ -d "$artifact_dir" ] && [ ! -L "$artifact_dir" ] || die "artifact directory missing or symlink: $artifact_dir"
  local env="$artifact_dir/bundle.env" sums="$artifact_dir/SHA256SUMS"
  [ -f "$env" ] && [ ! -L "$env" ] || die "bundle.env missing or not regular"
  [ -f "$sums" ] && [ ! -L "$sums" ] || die "SHA256SUMS missing or not regular"
  [ "$(cat "$env")" = "$(printf 'FORMAT_VERSION=1\nOS_ID=%s\nARCH=arm64' "$expected_os")" ] && [ "$(wc -l < "$env" | tr -d ' ')" = 3 ] || die "bundle.env is not exact required three-line format"
  ! find "$artifact_dir" -type l -print -quit | grep -q . || die "bundle contains symlink"
  local line path; declare -A listed=()
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[0-9a-fA-F]{64}\ [\ \*]([^[:space:]].*)$ ]] || die "invalid SHA256SUMS entry: $line"
    path="${BASH_REMATCH[1]}"; validate_relative "$path" || die "unsafe SHA256SUMS path: $path"
    [ "$path" != SHA256SUMS ] || die "SHA256SUMS must not checksum itself"
    [ -z "${listed[$path]+x}" ] || die "duplicate SHA256SUMS path: $path"
    [ -f "$artifact_dir/$path" ] && [ ! -L "$artifact_dir/$path" ] || die "checksum entry not regular: $path"; listed["$path"]=1
  done < "$sums"
  [ "${#listed[@]}" -gt 0 ] || die "SHA256SUMS has no entries"
  while IFS= read -r -d '' path; do path="${path#$artifact_dir/}"; [ "$path" = SHA256SUMS ] || [ -n "${listed[$path]+x}" ] || die "regular file absent from SHA256SUMS: $path"; done < <(find "$artifact_dir" -type f -print0)
  (cd "$artifact_dir" && sha256sum -c --strict SHA256SUMS) >/dev/null || die "SHA256SUMS verification failed"
  [ -f "$artifact_dir/rpm-repo/repodata/repomd.xml" ] || die "rpm-repo metadata missing"
  find "$artifact_dir/rpm-repo" -type f -name '*.rpm' -print -quit | grep -q . || die "rpm-repo contains no RPMs"
  find "$artifact_dir/keys" -maxdepth 1 -type f -name '*.asc' -print -quit | grep -q . || die "approved vendor RPM key missing"
  [ -f "$artifact_dir/images.tsv" ] || die "images.tsv missing"
  local image_ref image_path image_line_count=0; declare -A bundle_images=()
  while IFS=$'\t' read -r image_ref image_path extra || [ -n "${image_ref:-}" ]; do
    [ -n "${image_ref:-}" ] && [ -n "${image_path:-}" ] && [ -z "${extra:-}" ] || die "images.tsv must contain reference<TAB>archive path"
    [[ "$image_ref" == */* ]] && [[ "$image_ref" != *' '* ]] || die "images.tsv image is not fully qualified: $image_ref"
    case "$image_path" in images/*) ;; *) die "images.tsv archive must be under images/: $image_path";; esac
    validate_relative "$image_path" || die "unsafe image archive path: $image_path"
    [ -f "$artifact_dir/$image_path" ] && [ ! -L "$artifact_dir/$image_path" ] || die "image archive missing: $image_path"
    [ -z "${bundle_images[$image_ref]+x}" ] || die "duplicate image reference: $image_ref"
    bundle_images["$image_ref"]=1; image_line_count=$((image_line_count + 1))
  done < "$artifact_dir/images.tsv"
  [ "$image_line_count" -eq 5 ] || die "images.tsv must contain exactly five image archives"
  for image_ref in docker.io/clickhouse/clickhouse-server:24.8 docker.io/grafana/grafana-oss:11.4.0 docker.hyperdx.io/hyperdx/hyperdx:2.19.0 docker.io/library/mongo:7.0 docker.io/timberio/vector:0.57.0-debian; do
    [ -n "${bundle_images[$image_ref]+x}" ] || die "images.tsv missing required image: $image_ref"
  done
  [ -f "$artifact_dir/grafana-plugins/grafana-clickhouse-datasource/plugin.json" ] || die "Grafana ClickHouse plugin.json missing"
  find "$artifact_dir/grafana-plugins/grafana-clickhouse-datasource" -type f ! -name plugin.json -print -quit | grep -q . || die "Grafana plugin has no unpacked files"
}
if [ "$source_mode" = bundle ]; then
  validate_bundle
  for key in "$artifact_dir"/keys/*.asc; do
    approved=0; for vendor_key in /etc/pki/rpm-gpg/*; do [ -f "$vendor_key" ] && cmp -s "$key" "$vendor_key" && approved=1 && break; done
    [ "$approved" = 1 ] || die "bundle RPM key $(basename "$key") is not an approved installed vendor key"
  done
fi
install -d -m 0700 -o root -g root /etc/ironlog
if [ "$source_mode" = bundle ]; then
  printf '[ironlog-bundle]\nname=ironlog verified offline bundle\nbaseurl=file://%s/rpm-repo\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=0\n' "$artifact_dir" > /etc/yum.repos.d/ironlog-bundle.repo
  for key in "$artifact_dir"/keys/*.asc; do rpm --import "$key"; done
fi
{ printf 'IRONLOG_SOFTWARE_SOURCE=%q\n' "$source_mode"; printf 'IRONLOG_ARTIFACT_DIR=%q\n' "$artifact_dir"; printf 'IRONLOG_EXPECTED_OS=%q\n' "$expected_os"; } > /etc/ironlog/build-source.conf
chmod 0600 /etc/ironlog/build-source.conf
. "$(dirname "$0")/lib-software-source.sh"
ironlog_dnf install -y lvm2 parted util-linux gdisk
log "software source configured: $source_mode (OS=$actual_os arch=$host_arch)"
