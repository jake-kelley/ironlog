#!/usr/bin/env bash
# One-command Phase 1 bootstrap. Run from the repo root on your Docker host:
#   ./bootstrap.sh you@example.com
# Does: .env generation -> compose up -> Keycloak client-secret rotation ->
# first admin user creation -> RBAC verification. Idempotent-ish: refuses to
# overwrite an existing .env.
set -euo pipefail

ADMIN_EMAIL="${1:?usage: ./bootstrap.sh <your-email-for-first-admin-user>}"
gen() { openssl rand -base64 24 | tr -d '/+=' ; }

# --- 1. Secrets ---------------------------------------------------------------
if [[ -f .env ]]; then
  echo ".env already exists — refusing to overwrite. Delete it to re-bootstrap."
  exit 1
fi
GRAFANA_OAUTH_SECRET="$(gen)"
HYPERDX_OAUTH_SECRET="$(gen)"
CH_ANALYST_PW="$(gen)"
CH_AUDITOR_PW="$(gen)"
CH_HYPERDX_PW="$(gen)"
KC_ADMIN_PW="$(gen)"
FIRST_USER_TEMP_PW="$(gen)"
cat > .env <<EOF
CH_ADMIN_USER=siem_admin
CH_ADMIN_PASSWORD=$(gen)
CH_VECTOR_PASSWORD=$(gen)
CH_GRAFANA_ANALYST_PASSWORD=${CH_ANALYST_PW}
CH_GRAFANA_AUDITOR_PASSWORD=${CH_AUDITOR_PW}
CH_HYPERDX_PASSWORD=${CH_HYPERDX_PW}
KC_DB_PASSWORD=$(gen)
KC_ADMIN_USER=kcadmin
KC_ADMIN_PASSWORD=${KC_ADMIN_PW}
KC_HOSTNAME=http://keycloak:8080
KC_PUBLIC_URL=http://keycloak:8080
GRAFANA_ROOT_URL=http://localhost:3000
GRAFANA_ADMIN_USER=breakglass_admin
GRAFANA_ADMIN_PASSWORD=$(gen)
GRAFANA_OAUTH_SECRET=${GRAFANA_OAUTH_SECRET}
HYPERDX_OAUTH_SECRET=${HYPERDX_OAUTH_SECRET}
HYPERDX_DB_PASSWORD=$(gen)
OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -hex 16)
SPLUNK_HEC_TOKEN=$(gen)
EOF
chmod 600 .env
echo "[1/5] .env generated (chmod 600)."

# --- 2. Hostname sanity ---------------------------------------------------------
if ! grep -qE '(^|\s)keycloak(\s|$)' /etc/hosts; then
  echo "NOTE: add this line to /etc/hosts on the machine running your BROWSER"
  echo "      (and this host, if different):    127.0.0.1 keycloak"
fi

# --- 3. Stack up ----------------------------------------------------------------
echo "[2/5] Starting stack..."
docker compose up -d

echo "[3/5] Waiting for Keycloak..."
for i in $(seq 1 60); do
  if docker exec siem-keycloak /opt/keycloak/bin/kcadm.sh config credentials \
       --server http://localhost:8080 --realm master \
       --user kcadmin --password "${KC_ADMIN_PW}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
  [[ $i -eq 60 ]] && { echo "Keycloak did not become ready"; exit 1; }
done

kc() { docker exec siem-keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# --- 4. Rotate grafana client secret + create first admin user --------------------
CLIENT_UID="$(kc get clients -r siem -q clientId=grafana --fields id --format csv --noquotes | head -1)"
kc update "clients/${CLIENT_UID}" -r siem -s "secret=${GRAFANA_OAUTH_SECRET}"
HDX_CLIENT_UID="$(kc get clients -r siem -q clientId=hyperdx --fields id --format csv --noquotes | head -1)"
kc update "clients/${HDX_CLIENT_UID}" -r siem -s "secret=${HYPERDX_OAUTH_SECRET}"
echo "[4/5] Grafana + HyperDX client secrets rotated to the values in .env."

kc create users -r siem \
  -s "username=${ADMIN_EMAIL}" -s "email=${ADMIN_EMAIL}" \
  -s enabled=true -s emailVerified=true \
  -s 'requiredActions=["CONFIGURE_TOTP","UPDATE_PASSWORD"]' >/dev/null 2>&1 || true
kc set-password -r siem --username "${ADMIN_EMAIL}" --new-password "${FIRST_USER_TEMP_PW}" --temporary
kc add-roles -r siem --uusername "${ADMIN_EMAIL}" --rolename siem_admin

docker compose up -d grafana --force-recreate >/dev/null

# --- 5. Verify RBAC + audit trail wiring -------------------------------------------
echo "[5/5] Verifying..."
set +e
docker exec siem-clickhouse clickhouse-client --user svc_grafana_analyst \
  --password "${CH_ANALYST_PW}" --query "SELECT count() FROM siem.cloudtrail" >/dev/null 2>&1 \
  && echo "  PASS analyst can read siem.*" || echo "  FAIL analyst read siem.*"
docker exec siem-clickhouse clickhouse-client --user svc_grafana_analyst \
  --password "${CH_ANALYST_PW}" --query "SELECT count() FROM audit.query_archive" >/dev/null 2>&1 \
  && echo "  FAIL analyst can read audit.* (should be denied)" || echo "  PASS analyst denied on audit.*"
docker exec siem-clickhouse clickhouse-client --user svc_grafana_auditor \
  --password "${CH_AUDITOR_PW}" --query "SELECT count() FROM audit.query_archive" >/dev/null 2>&1 \
  && echo "  PASS auditor can read audit.*" || echo "  FAIL auditor read audit.*"
docker exec siem-clickhouse clickhouse-client --user svc_hyperdx \
  --password "${CH_HYPERDX_PW}" --query "SELECT count() FROM siem.cloudtrail" >/dev/null 2>&1 \
  && echo "  PASS hyperdx can read siem.*" || echo "  FAIL hyperdx read siem.*"
set -e

cat <<DONE

Bootstrap complete.
  Grafana:  http://localhost:3000  (redirects to Keycloak SSO)
  Login:    ${ADMIN_EMAIL} / ${FIRST_USER_TEMP_PW}
            (you will be forced to set a new password and enroll TOTP MFA)
  Keycloak: http://keycloak:8080  admin console: kcadmin / see .env

Next: run through the Phase 1 exit criteria in README.md, then Phase 2.
DONE
