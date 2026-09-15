#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-ami.sh [--os rhel9|rocky9] [packer build options] [--]

Builds one ironlog AMI. Default OS is rhel9 (shipping image).

Options:
  --os OS       Select rhel9 or rocky9. Default: rhel9.
  -h, --help    Show this help.

All other options are forwarded to `packer build`, including -var and
-var-file. This wrapper does not run `packer init`, so bundle builds do not
download plugins; install required Packer plugins before invoking it.

Examples:
  scripts/build-ami.sh --var-file=packer/rhel9-private-bundle.pkrvars.hcl
  scripts/build-ami.sh --os rocky9 --var-file=packer/rocky9-dev.pkrvars.hcl
EOF
}

os=rhel9
forward=()
while (($#)); do
  case "$1" in
    --os)
      (($# >= 2)) || { echo '--os requires rhel9 or rocky9' >&2; exit 64; }
      os=$2
      shift 2
      ;;
    --os=*)
      os=${1#--os=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      forward+=("$@")
      break
      ;;
    *)
      forward+=("$1")
      shift
      ;;
  esac
done

case "$os" in
  rhel9|rocky9) ;;
  *) echo "invalid --os value: $os (expected rhel9 or rocky9)" >&2; exit 64 ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec packer build -only="ironlog.amazon-ebs.$os" "${forward[@]}" "$root/packer"
