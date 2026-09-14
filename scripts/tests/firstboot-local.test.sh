#!/usr/bin/env bash
# Execute firstboot against isolated filesystem paths and mocked host services.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
mkdir -p "$root/.decurion"
tmpdir=$(mktemp -d "$root/.decurion/firstboot-test.XXXXXX")
cleanup() {
  local resolved
  resolved=$(cd "$tmpdir" && pwd -P)
  case "$resolved" in
    "$root"/.decurion/firstboot-test.*) rm -rf -- "$resolved" ;;
    *) echo 'refusing cleanup outside test workspace' >&2 ;;
  esac
}
trap cleanup EXIT
mkdir -p "$tmpdir/lib" "$tmpdir/bin"
sed -e 's|^ETC_DIR=/etc/ironlog$|ETC_DIR="$IRONLOG_TEST_ROOT/etc"|' \
    -e 's|^UNIT_DIR=/etc/systemd/system$|UNIT_DIR="$IRONLOG_TEST_ROOT/units"|' \
    -e 's|^DATA_ROOT=/var/lib/ironlog$|DATA_ROOT="$IRONLOG_TEST_ROOT/data"|' \
    "$root/scripts/firstboot/ironlog-firstboot.sh" > "$tmpdir/lib/firstboot.sh"
# Never touch real services, AWS metadata, data ownership or host mounts.
cat > "$tmpdir/lib/secret-resolver.sh" <<'SH'
sr_fetch_userdata() { cat "$IRONLOG_TEST_ROOT/config"; }
sr_region() { printf us-east-1; }
sr_resolve() {
  case "$1" in
    generate:*) printf test-session-signing-secret ;;
    file://empty) printf '' ;;
    file://multiline) printf 'secret\nINJECTED=bad' ;;
    *) printf '%s' "$1" ;;
  esac
}
SH
for cmd in chown logger findmnt; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmpdir/bin/$cmd"
done
cat > "$tmpdir/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IRONLOG_TEST_ROOT/jobs"
[[ -z "${FAIL_UNIT:-}" || "$*" != *"$FAIL_UNIT"* ]]
SH
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
fixture() {
  export IRONLOG_TEST_ROOT="$tmpdir/$1"
  mkdir -p "$IRONLOG_TEST_ROOT"
  cat > "$IRONLOG_TEST_ROOT/config" <<'CONF'
APPLIANCE_FQDN=siem.example.com
APPLIANCE_TLS=false
CH_ADMIN_PASSWORD=test-password
CH_VECTOR_PASSWORD=test-password
CH_GRAFANA_ANALYST_PASSWORD=test-password
CH_GRAFANA_AUDITOR_PASSWORD=test-password
CH_HYPERDX_PASSWORD=test-password
SPLUNK_HEC_TOKEN=test-token
HYPERDX_DB_PASSWORD=test-password
CONF
}
run() { bash "$tmpdir/lib/firstboot.sh" > "$IRONLOG_TEST_ROOT/output" 2>&1; }
fixture defaults
run
test -f "$IRONLOG_TEST_ROOT/etc/.firstboot-complete"
grep -Fx 'GRAFANA_ADMIN_USER="admin"' "$IRONLOG_TEST_ROOT/etc/ironlog.env"
grep -Fx 'HYPERDX_LOCAL_EMAIL="admin@ironlog.local"' "$IRONLOG_TEST_ROOT/etc/ironlog.env"
grep -Fx 'HYPERDX_SESSION_SECRET="test-session-signing-secret"' "$IRONLOG_TEST_ROOT/etc/ironlog.env"
grep -Fx 'start --no-block ironlog-bootstrap-hyperdx-local.service' "$IRONLOG_TEST_ROOT/jobs"
! grep -Ei 'keycloak|oauth2|postgres' "$IRONLOG_TEST_ROOT/jobs"
# A repeat boot does not queue jobs or replace the environment file.
before=$(cat "$IRONLOG_TEST_ROOT/jobs")
run
[[ $(cat "$IRONLOG_TEST_ROOT/jobs") == "$before" ]]
for mode in oidc ldap; do
  fixture "$mode"
  printf '\nAPPLIANCE_MODE=%s\n' "$mode" >> "$IRONLOG_TEST_ROOT/config"
  if run; then echo "unexpected success: $mode" >&2; exit 1; fi
  test ! -f "$IRONLOG_TEST_ROOT/etc/ironlog.env"
done
fixture failed-start
if FAIL_UNIT=ironlog-bootstrap-hyperdx-local.service run; then exit 1; fi
test ! -f "$IRONLOG_TEST_ROOT/etc/.firstboot-complete"
for value in empty multiline; do
  fixture "$value"
  printf '\nHYPERDX_LOCAL_PASSWORD=file://%s\n' "$value" >> "$IRONLOG_TEST_ROOT/config"
  if run; then echo "unexpected success: $value" >&2; exit 1; fi
  test ! -f "$IRONLOG_TEST_ROOT/etc/ironlog.env"
  test ! -f "$IRONLOG_TEST_ROOT/etc/.firstboot-complete"
done
fixture quoted
printf '\nHYPERDX_LOCAL_PASSWORD=Space "quote" \\ dollar$\n' >> "$IRONLOG_TEST_ROOT/config"
run
grep -Fx 'HYPERDX_LOCAL_PASSWORD="Space \"quote\" \\ dollar$"' "$IRONLOG_TEST_ROOT/etc/ironlog.env"
echo 'firstboot-local tests passed'
