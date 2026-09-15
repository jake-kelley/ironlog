#!/usr/bin/env bash
# scripts/ami/20-container-images.sh — pre-pull all appliance images, arm64,
# so the appliance boots air-gapped with no registry reachable.
#
# Runs after quadlets/config are staged (packer/build.pkr.hcl step 6).
# Idempotent: skips any image already present with the right arch.
set -euo pipefail
. "$(dirname "$0")/lib-software-source.sh"

LOG_TAG="ironlog-images"
log() { echo "[$LOG_TAG] $*"; }
die() { echo "[$LOG_TAG] FATAL: $*" >&2; exit 1; }

# Authoritative image list. packer/build.pkr.hcl also carries a copy in
# `local.container_images` purely for documentation/manifest purposes and
# passes it through as IRONLOG_CONTAINER_IMAGES — if that env var is set we
# use it (keeps a single source of truth honored either direction); if not
# (e.g. running this script by hand for a rebuild), the hardcoded list below
# is authoritative.
# FULLY QUALIFIED, always. RHEL/Rocky ship podman with
# short-name-mode = "enforcing" in /etc/containers/registries.conf, so a
# Docker Hub short name cannot be resolved without a TTY to prompt at:
#   "Error: short-name resolution enforced but cannot prompt without a TTY"
# The quay.io/ and docker.hyperdx.io/ entries always worked precisely
# because they were already qualified. These strings must also match the
# Image= lines in quadlets/ verbatim -- see the cross-check below.
DEFAULT_IMAGES="docker.io/clickhouse/clickhouse-server:24.8 docker.io/grafana/grafana-oss:11.4.0 docker.hyperdx.io/hyperdx/hyperdx:2.19.0 docker.io/library/mongo:7.0 docker.io/timberio/vector:0.57.0-debian"
IMAGES="${IRONLOG_CONTAINER_IMAGES:-$DEFAULT_IMAGES}"
ARCH="${IRONLOG_PULL_ARCH:-arm64}"

command -v podman >/dev/null || die "podman not installed — run scripts/ami/10-baseline.sh first"

install_plugin() {
  local plugin_dir="${IRONLOG_GRAFANA_PLUGIN_DIR:-/opt/ironlog/grafana-plugins}" plugin_json executable
  rm -rf "$plugin_dir"
  install -d -m 0755 -o 472 -g 472 "$plugin_dir"
  if [ "$IRONLOG_SOFTWARE_SOURCE" = bundle ]; then
    cp -a "$IRONLOG_ARTIFACT_DIR/grafana-plugins/." "$plugin_dir/"
  else
    # Grafana 11.4.0 image ENTRYPOINT is /run.sh, which starts server after
    # processing arguments. Invoke binary directly so this is CLI, not server.
    podman run --rm --pull=never --entrypoint /usr/share/grafana/bin/grafana -v "$plugin_dir:/var/lib/grafana/plugins:Z" docker.io/grafana/grafana-oss:11.4.0 cli --pluginsDir /var/lib/grafana/plugins plugins install grafana-clickhouse-datasource
  fi
  chown -R root:root "$plugin_dir"
  plugin_json="$plugin_dir/grafana-clickhouse-datasource/plugin.json"
  [ -f "$plugin_json" ] || die "Grafana ClickHouse plugin.json absent after install"
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"grafana-clickhouse-datasource"' "$plugin_json" || die "Grafana plugin ID is not grafana-clickhouse-datasource"
  executable="$(sed -nE 's/.*"executable"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$plugin_json" | head -n1)"
  if [ -n "$executable" ]; then
    executable="$plugin_dir/grafana-clickhouse-datasource/$executable"
    [ -x "$executable" ] || executable="${executable}_linux_arm64"
    [ -x "$executable" ] || die "Grafana plugin executable missing or not executable for linux/arm64"
    if command -v file >/dev/null && ! file "$executable" | grep -Eqi 'aarch64|arm64'; then die "Grafana plugin executable is not linux/arm64: $executable"; fi
  fi
  chmod -R a+rX "$plugin_dir"
  log "Grafana ClickHouse plugin baked at $plugin_dir"
}

# docker.hyperdx.io/hyperdx/hyperdx is a thin proxy in front of Docker Hub:
# it 307-redirects to auth.docker.io with scope repository:hyperdx/hyperdx:pull,
# then serves the actual blob from Docker Hub's registry. Verified working in
# an earlier session (this comment records that, not a fresh check here).
# FALLBACK for a disconnected/mirrored build environment where
# docker.hyperdx.io itself isn't reachable but a Docker Hub mirror is: pull
# docker.io/hyperdxio/hyperdx:2.19.0 directly instead (the underlying image
# docker.hyperdx.io proxies to) and retag it locally as
# docker.hyperdx.io/hyperdx/hyperdx:2.19.0 before this script runs, since
# quadlets/ironlog-hyperdx.container references the docker.hyperdx.io name
# literally.

fail=0
if [ "$IRONLOG_SOFTWARE_SOURCE" = bundle ]; then
  declare -A image_archives=()
  while IFS=$'\t' read -r ref archive; do image_archives["$ref"]="$archive"; done < "$IRONLOG_ARTIFACT_DIR/images.tsv"
fi
for img in $IMAGES; do
  if [ "$IRONLOG_SOFTWARE_SOURCE" = bundle ]; then
    archive="${image_archives[$img]:-}"
    [ -n "$archive" ] || die "bundle images.tsv missing required image: $img"
    log "loading $img from $archive"
    podman load --input "$IRONLOG_ARTIFACT_DIR/$archive" >/dev/null || die "podman load failed for $archive"
  else
    log "pulling $img (--arch $ARCH)"
    if ! podman pull --arch "$ARCH" "$img"; then
      echo "[$LOG_TAG] FATAL: pull failed for $img" >&2
      fail=1
      continue
    fi
  fi

  got_arch="$(podman image inspect "$img" --format '{{.Architecture}}' 2>/dev/null || true)"
  if [ "$got_arch" != "$ARCH" ]; then
    echo "[$LOG_TAG] FATAL: $img pulled as architecture '$got_arch', expected '$ARCH' — a silently-wrong-arch image boots then crash-loops on the Graviton appliance. Not proceeding." >&2
    fail=1
    continue
  fi
  log "$img OK (arch=$got_arch)"
done

[ "$fail" -eq 0 ] || die "one or more images failed to load/pull or verify as $ARCH — see FATAL lines above"

# Cross-check against what the appliance will ACTUALLY ask for at boot. The
# pull list and the quadlets are separate files that must agree; when they
# drift, nothing fails here -- it fails later, on a disconnected network, with
# podman unable to resolve an image it was never given. Assert the invariant
# while a registry is still reachable to fix it.
QUADLET_DIR="${IRONLOG_QUADLET_DIR:-/etc/containers/systemd}"
if [ -d "$QUADLET_DIR" ]; then
  missing=0
  for want in $(grep -h '^Image=' "$QUADLET_DIR"/*.container 2>/dev/null | cut -d= -f2- | sort -u || true); do
    if ! podman image exists "$want"; then
      echo "[$LOG_TAG] FATAL: quadlet references $want but it is not in the local image store — the appliance would fail to start it with no registry reachable" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "quadlet Image= references not satisfied by the pre-pull list (see FATAL lines above)"
  log "cross-check OK: every Image= in $QUADLET_DIR/*.container is present in the local image store"
else
  log "WARNING: $QUADLET_DIR does not exist — skipping quadlet/pull-list cross-check (quadlets should have been installed by build.pkr.hcl step 5)"
fi

install_plugin
log "all $(echo "$IMAGES" | wc -w) images loaded/pulled and verified as $ARCH"
podman images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
