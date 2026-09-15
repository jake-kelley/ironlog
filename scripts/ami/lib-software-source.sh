#!/usr/bin/env bash
# Shared DNF policy. This file is staged beside provisioners, never from a bundle.
ironlog_source_config="${IRONLOG_BUILD_SOURCE_CONFIG:-/etc/ironlog/build-source.conf}"
[ -r "$ironlog_source_config" ] || { echo "[ironlog-source] FATAL: missing $ironlog_source_config" >&2; return 1 2>/dev/null || exit 1; }
. "$ironlog_source_config"
ironlog_dnf() {
  if [ "${IRONLOG_SOFTWARE_SOURCE:?}" = bundle ]; then
    dnf --disablerepo='*' --enablerepo=ironlog-bundle --setopt=gpgcheck=1 --setopt=repo_gpgcheck=0 "$@"
  else
    dnf "$@"
  fi
}
