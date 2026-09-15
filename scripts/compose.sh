#!/usr/bin/env bash
# Run Compose with local runtime selected by IRONLOG_CONTAINER_RUNTIME or .env.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=container-runtime.sh
source "$script_dir/container-runtime.sh"

runtime=$(ironlog_container_runtime)
ironlog_require_runtime "$runtime"
exec "$runtime" compose "$@"
