#!/bin/bash
# ironlog-vector entrypoint: pick the baked config from IRONLOG_VECTOR_ROLE.
set -euo pipefail

# Subcommands (validate, test, ...) pass through untouched.
if [ "$#" -gt 0 ]; then
  exec vector "$@"
fi

case "${IRONLOG_VECTOR_ROLE:-}" in
  hosts) cfg=/etc/vector/hosts.yaml ;;
  aws)   cfg=/etc/vector/vector.yaml ;;
  *)
    echo "ironlog-vector: IRONLOG_VECTOR_ROLE must be 'hosts' or 'aws' (got '${IRONLOG_VECTOR_ROLE:-}')" >&2
    exit 64
    ;;
esac

exec vector --config "$cfg"
