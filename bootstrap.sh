#!/usr/bin/env bash
# One-command local-auth bootstrap. Run from repo root on Podman or Docker host:
#   ./bootstrap.sh [hyperdx-admin-email]
# Does: .env generation -> compose up -> ClickHouse RBAC verification ->
# HyperDX native-account bootstrap. Refuses to
# overwrite an existing .env.
set -euo pipefail

ADMIN_EMAIL="${1:-admin@ironlog.local}"
gen() { openssl rand -base64 24 | tr -d '/+=' ; }

# shellcheck source=scripts/container-runtime.sh
source "scripts/container-runtime.sh"
RUNTIME=$(ironlog_container_runtime)
ironlog_require_runtime "$RUNTIME"

# --- 1. Secrets ---------------------------------------------------------------
if [[ -f .env ]]; then
  echo ".env already exists — refusing to overwrite. Delete it to re-bootstrap."
  exit 1
fi
CH_ANALYST_PW="$(gen)"
CH_AUDITOR_PW="$(gen)"
CH_HYPERDX_PW="$(gen)"
cat > .env <<EOF
IRONLOG_CONTAINER_RUNTIME=${RUNTIME}
CH_ADMIN_USER=siem_admin
CH_ADMIN_PASSWORD=$(gen)
CH_VECTOR_PASSWORD=$(gen)
CH_GRAFANA_ANALYST_PASSWORD=${CH_ANALYST_PW}
CH_GRAFANA_AUDITOR_PASSWORD=${CH_AUDITOR_PW}
CH_HYPERDX_PASSWORD=${CH_HYPERDX_PW}
GRAFANA_ROOT_URL=http://localhost:3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=IronlogDev123!
HYPERDX_PUBLIC_URL=http://localhost:8081
HYPERDX_LOCAL_EMAIL=${ADMIN_EMAIL}
HYPERDX_LOCAL_PASSWORD=IronlogDev123!
HYPERDX_DB_PASSWORD=$(gen)
HYPERDX_SESSION_SECRET=$(openssl rand -hex 32)
SPLUNK_HEC_TOKEN=$(gen)
EOF
chmod 600 .env
echo "[1/5] .env generated (chmod 600)."

# --- 3. Stack up ----------------------------------------------------------------
echo "[2/5] Starting stack..."
scripts/compose.sh up -d

echo "[3/5] Waiting for ClickHouse RBAC..."
for i in $(seq 1 60); do
  if "$RUNTIME" exec siem-clickhouse clickhouse-client --user svc_hyperdx \
       --password "${CH_HYPERDX_PW}" --query "SELECT 1 FROM siem.cloudtrail LIMIT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 5
  [[ $i -eq 60 ]] && { echo "ClickHouse RBAC did not become ready"; exit 1; }
done

echo "[4/5] Creating or verifying HyperDX local account..."
HYPERDX_BOOTSTRAP_HELPER="scripts/bootstrap-hyperdx-local.sh"
[[ -f "${HYPERDX_BOOTSTRAP_HELPER}" ]] || { echo "Missing ${HYPERDX_BOOTSTRAP_HELPER}"; exit 1; }
bash "${HYPERDX_BOOTSTRAP_HELPER}" "$RUNTIME" siem-hyperdx

# --- 5. Verify RBAC + audit trail wiring -------------------------------------------
echo "[5/5] Verifying ClickHouse RBAC..."
verify() {
  local description="$1"
  shift
  "$@" >/dev/null 2>&1 || { echo "FAIL ${description}"; exit 1; }
  echo "PASS ${description}"
}
verify "analyst can read siem.*" "$RUNTIME" exec siem-clickhouse clickhouse-client --user svc_grafana_analyst \
  --password "${CH_ANALYST_PW}" --query "SELECT count() FROM siem.cloudtrail"
if "$RUNTIME" exec siem-clickhouse clickhouse-client --user svc_grafana_analyst \
  --password "${CH_ANALYST_PW}" --query "SELECT count() FROM audit.query_archive" >/dev/null 2>&1; then
  echo "FAIL analyst can read audit.*"
  exit 1
fi
echo "PASS analyst denied on audit.*"
verify "auditor can read audit.*" "$RUNTIME" exec siem-clickhouse clickhouse-client --user svc_grafana_auditor \
  --password "${CH_AUDITOR_PW}" --query "SELECT count() FROM audit.query_archive"
verify "HyperDX can read siem.*" "$RUNTIME" exec siem-clickhouse clickhouse-client --user svc_hyperdx \
  --password "${CH_HYPERDX_PW}" --query "SELECT count() FROM siem.cloudtrail"

cat <<DONE

Bootstrap complete.
  Grafana:  http://localhost:3000
  Login:    admin / IronlogDev123!
  HyperDX:  http://localhost:8081
  Login:    ${ADMIN_EMAIL} / IronlogDev123!

Next: run through the Phase 1 exit criteria in README.md, then Phase 2.
DONE
