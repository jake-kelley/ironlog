#!/bin/bash
# ironlog-clickhouse entrypoint. Server mode (no args, or args starting with
# "--"): validates credentials, generates the S3 tier config, starts
# ironlog-schema in the background (it waits for the server), then hands over
# to the upstream /entrypoint.sh. Any other command (e.g. ironlog-schema) runs
# as given.
set -euo pipefail

if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
  exec "$@"
fi

for v in CLICKHOUSE_USER CLICKHOUSE_PASSWORD CH_VECTOR_PASSWORD CH_GRAFANA_ANALYST_PASSWORD CH_GRAFANA_AUDITOR_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo "ironlog-clickhouse: $v is required" >&2
    exit 64
  fi
done
# Everything the server creates must be group-writable (g=u) for arbitrary UIDs.
umask 002
# Upstream creates the admin user (and removes 'default') from these.
export CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1

cfg=/etc/clickhouse-server/config.d/20-storage-s3.xml
rm -f "$cfg"
case "${IRONLOG_S3_TIER:-off}" in
  off) ;;
  on)
    if [ -z "${IRONLOG_S3_ENDPOINT:-}" ]; then
      echo "ironlog-clickhouse: IRONLOG_S3_TIER=on requires IRONLOG_S3_ENDPOINT" >&2
      exit 64
    fi
    if [ -n "${IRONLOG_S3_ACCESS_KEY_ID:-}" ] && [ -n "${IRONLOG_S3_SECRET_ACCESS_KEY:-}" ]; then
      creds='<access_key_id from_env="IRONLOG_S3_ACCESS_KEY_ID"/><secret_access_key from_env="IRONLOG_S3_SECRET_ACCESS_KEY"/>'
    elif [ -z "${IRONLOG_S3_ACCESS_KEY_ID:-}${IRONLOG_S3_SECRET_ACCESS_KEY:-}" ]; then
      creds='<use_environment_credentials>true</use_environment_credentials>'
    else
      echo "ironlog-clickhouse: set both or neither of IRONLOG_S3_ACCESS_KEY_ID and IRONLOG_S3_SECRET_ACCESS_KEY" >&2
      exit 64
    fi
    region=''
    [ -n "${IRONLOG_S3_REGION:-}" ] && region='<region from_env="IRONLOG_S3_REGION"/>'
    # Values are referenced with from_env, so secrets never touch the file.
    umask 002
    cat > "$cfg" <<XML
<clickhouse>
    <storage_configuration>
        <disks>
            <s3_cold>
                <type>s3</type>
                <endpoint from_env="IRONLOG_S3_ENDPOINT"/>
                ${creds}
                ${region}
                <metadata_path>/var/lib/clickhouse/disks/s3_cold/</metadata_path>
            </s3_cold>
        </disks>
        <policies>
            <hot_to_s3>
                <volumes>
                    <default><disk>default</disk></default>
                    <s3><disk>s3_cold</disk></s3>
                </volumes>
                <move_factor>0.1</move_factor>
            </hot_to_s3>
        </policies>
    </storage_configuration>
</clickhouse>
XML
    chmod 0664 "$cfg"
    ;;
  *)
    echo "ironlog-clickhouse: IRONLOG_S3_TIER must be 'on' or 'off' (got '${IRONLOG_S3_TIER}')" >&2
    exit 64
    ;;
esac

# Source-IP allowlist (IRONLOG_CLICKHOUSE_ALLOWED_HOSTS). The service accounts
# are restricted by ironlog-schema. The admin account is created by the upstream
# entrypoint with <networks><ip>::/0</ip> in users.d/default-user.xml; a later
# users.d file (merged in file name order, so the name must sort after default-user.xml) replaces that list with loopback +
# the allowlist. Written on every start, so clearing the variable removes it.
# shellcheck source=allowed-hosts.sh
. /usr/local/bin/ironlog-allowed-hosts
adm_cfg=/etc/clickhouse-server/users.d/zz-admin-networks.xml
rm -f "$adm_cfg"
parse_allowed_hosts || { echo "ironlog-clickhouse: IRONLOG_CLICKHOUSE_ALLOWED_HOSTS: $ALLOWED_ERR" >&2; exit 64; }
if [ "${#ALLOWED_HOSTS[@]}" -gt 0 ]; then
  [[ "$CLICKHOUSE_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "ironlog-clickhouse: CLICKHOUSE_USER must match [A-Za-z_][A-Za-z0-9_-]* when IRONLOG_CLICKHOUSE_ALLOWED_HOSTS is set" >&2; exit 64; }
  ips='<ip>::1</ip><ip>127.0.0.1</ip>'
  for h in "${ALLOWED_HOSTS[@]}"; do ips="${ips}<ip>${h}</ip>"; done
  echo "<clickhouse><users><${CLICKHOUSE_USER}><networks replace=\"replace\">${ips}</networks></${CLICKHOUSE_USER}></users></clickhouse>" > "$adm_cfg"
  chmod 0664 "$adm_cfg"
fi

# Schema + accounts on every start (upstream initdb runs only on an empty data dir).
(
  export IRONLOG_CLICKHOUSE_HOST=localhost IRONLOG_CLICKHOUSE_NATIVE_PORT=9000
  for attempt in 1 2 3 4 5; do
    if ironlog-schema; then exit 0; fi
    echo "ironlog-schema: attempt $attempt/5 failed" >&2
    sleep 10
  done
  echo "ironlog-schema: FATAL: giving up; the server is running WITHOUT a verified schema" >&2
) &

exec /entrypoint.sh "$@"
