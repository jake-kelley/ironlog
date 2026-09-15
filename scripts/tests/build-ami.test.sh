#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
wrapper="$root/scripts/build-ami.sh"
mkdir -p "$root/.decurion"
tmpdir=$(mktemp -d "$root/.decurion/build-ami-test.XXXXXX")
packer_bin=$(command -v packer || command -v packer.exe || true)

[[ -n "$packer_bin" ]] || {
  echo 'packer or packer.exe is required to validate Packer templates' >&2
  exit 69
}

packer_dir="$root/packer"
artifact_dir="$tmpdir/artifacts"
if [[ "$packer_bin" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
  packer_dir=$(wslpath -w "$packer_dir")
  artifact_dir=$(wslpath -w "$artifact_dir")
fi

cleanup() {
  local resolved
  resolved=$(cd "$tmpdir" && pwd -P)
  case "$resolved" in
    "$root"/.decurion/build-ami-test.*) rm -rf -- "$resolved" ;;
    *) echo 'refusing cleanup outside test workspace' >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/artifacts"
printf 'fixture\n' > "$tmpdir/artifacts/manifest.txt"

cat > "$tmpdir/bin/packer" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PACKER_ARGS_FILE"
SH
chmod +x "$tmpdir/bin/packer"

PACKER_ARGS_FILE="$tmpdir/rhel.args" PATH="$tmpdir/bin:$PATH" "$wrapper" --var software_source=internet
grep -Fx 'build' "$tmpdir/rhel.args"
grep -Fx -- '-only=ironlog.amazon-ebs.rhel9' "$tmpdir/rhel.args"
grep -Fx 'software_source=internet' "$tmpdir/rhel.args"
grep -Fx "$root/packer" "$tmpdir/rhel.args"

PACKER_ARGS_FILE="$tmpdir/rocky.args" PATH="$tmpdir/bin:$PATH" "$wrapper" --os rocky9 -- --var software_source=bundle
grep -Fx -- '-only=ironlog.amazon-ebs.rocky9' "$tmpdir/rocky.args"
grep -Fx -- '--var' "$tmpdir/rocky.args"
grep -Fx 'software_source=bundle' "$tmpdir/rocky.args"

if PATH="$tmpdir/bin:$PATH" "$wrapper" --os almalinux9 > "$tmpdir/bad-os.out" 2>&1; then
  echo 'expected invalid --os to fail' >&2
  exit 1
fi
grep -Fx 'invalid --os value: almalinux9 (expected rhel9 or rocky9)' "$tmpdir/bad-os.out"

"$packer_bin" validate -var 'software_source=internet' "$packer_dir"
"$packer_bin" validate -var 'software_source=bundle' -var "artifact_bundle_dir=$artifact_dir" -var 'source_ami_id=ami-0123456789abcdef0' "$packer_dir"

if "$packer_bin" validate -var 'software_source=bundle' "$packer_dir" > "$tmpdir/missing-bundle.out" 2>&1; then
  echo 'expected bundle mode without artifact_bundle_dir to fail' >&2
  exit 1
fi
grep -F 'Call to function "regex" failed' "$tmpdir/missing-bundle.out"

echo 'build-ami tests passed'
