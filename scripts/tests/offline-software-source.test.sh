#!/usr/bin/env bash
# Shell-level guardrails for failures that must happen before DNF/Podman.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/scripts/ami/05-software-source.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/artifacts"
cat > "$tmp/os-release" <<'EOF'
ID=rocky
VERSION_ID=9.6
EOF
for command in dnf podman rpm install; do
  printf '#!/usr/bin/env bash\necho %s >> "$MOCK_LOG"\nexit 99\n' "$command" > "$tmp/bin/$command"
  chmod +x "$tmp/bin/$command"
done
run_fail() {
  : > "$tmp/calls"
  if PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls" IRONLOG_SOFTWARE_SOURCE=bundle IRONLOG_ARTIFACT_DIR="$1" IRONLOG_EXPECTED_OS="$2" IRONLOG_OS_RELEASE_FILE="$tmp/os-release" bash "$script" >/dev/null 2>&1; then
    echo "expected failure: $3" >&2; exit 1
  fi
  [ ! -s "$tmp/calls" ] || { echo "mutation happened before validation: $3" >&2; exit 1; }
}
run_fail "$tmp/no-artifacts" rocky9 missing-artifact
mkdir -p "$tmp/artifacts"; printf 'FORMAT_VERSION=1\nOS_ID=rocky9\nARCH=arm64\n' > "$tmp/artifacts/bundle.env"; printf '%064d  bundle.env\n' 0 > "$tmp/artifacts/SHA256SUMS"
run_fail "$tmp/artifacts" rocky9 bad-checksum
run_fail "$tmp/artifacts" rhel9 os-mismatch
printf 'IRONLOG_SOFTWARE_SOURCE=bundle\nIRONLOG_ARTIFACT_DIR=/unused\nIRONLOG_EXPECTED_OS=rocky9\n' > "$tmp/source.conf"
printf '#!/usr/bin/env bash\necho "$*" >> "$MOCK_LOG"\n' > "$tmp/bin/dnf"
chmod +x "$tmp/bin/dnf"
PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls" IRONLOG_BUILD_SOURCE_CONFIG="$tmp/source.conf" bash -c ". '$root/scripts/ami/lib-software-source.sh'; ironlog_dnf install -y podman"
grep -F -- '--disablerepo=* --enablerepo=ironlog-bundle --setopt=gpgcheck=1 --setopt=repo_gpgcheck=0 install -y podman' "$tmp/calls" >/dev/null
echo "offline software-source failure guards: PASS"
