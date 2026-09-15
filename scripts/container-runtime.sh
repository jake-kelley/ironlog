#!/usr/bin/env bash
# Shared runtime selection and readiness checks for local Compose commands.

ironlog_container_runtime() {
  local configured=''

  if [[ -n "${IRONLOG_CONTAINER_RUNTIME:-}" ]]; then
    configured=$IRONLOG_CONTAINER_RUNTIME
  elif [[ -f .env ]]; then
    configured=$(sed -n 's/^IRONLOG_CONTAINER_RUNTIME=\(podman\|docker\)$/\1/p' .env | tail -n 1)
  fi

  printf '%s\n' "${configured:-podman}"
}

ironlog_require_runtime() {
  local runtime=$1

  case "$runtime" in
    docker|podman) ;;
    *)
      echo "Unsupported IRONLOG_CONTAINER_RUNTIME '$runtime'; use podman or docker." >&2
      return 64
      ;;
  esac

  if ! command -v "$runtime" >/dev/null 2>&1; then
    echo "Container runtime '$runtime' is not installed." >&2
    return 69
  fi

  if ! "$runtime" compose version >/dev/null 2>&1; then
    echo "Container runtime '$runtime' has no working Compose provider." >&2
    return 69
  fi
}
