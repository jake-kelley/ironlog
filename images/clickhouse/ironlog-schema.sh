#!/bin/bash
# ironlog-schema: idempotent schema, accounts, tier/retention TTLs, then VERIFY.
# Runs against localhost on every server start and, as a one-shot, against
# IRONLOG_CLICKHOUSE_HOST. Exits non-zero if databases, tables or accounts are
# missing (same check as scripts/firstboot/ironlog-apply-schema.sh).
# Contract: images/README.md. Admin credentials: CLICKHOUSE_USER/CLICKHOUSE_PASSWORD.
set -euo pipefail

TAG="ironlog-schema"
DDL_DIR="${IRONLOG_DDL_DIR:-/ddl}"
export CLICKHOUSE_HOST="${IRONLOG_CLICKHOUSE_HOST:-localhost}"
export CLICKHOUSE_PORT="${IRONLOG_CLICKHOUSE_NATIVE_PORT:-9000}"
export CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
export CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
TIER="${IRONLOG_S3_TIER:-off}"
HOT_DAYS="${IRONLOG_HOT_DAYS:-30}"
if [ "$TIER" = "on" ]; then RETENTION_DAYS="${IRONLOG_RETENTION_DAYS:-400}"; else RETENTION_DAYS="${IRONLOG_RETENTION_DAYS:-30}"; fi
WAIT_SECONDS="${IRONLOG_SCHEMA_WAIT_SECONDS:-120}"
POLICY="hot_to_s3"

log() { echo "[$TAG] $*"; }
die() { echo "[$TAG] FATAL: $*" >&2; exit 1; }

case "$TIER" in on|off) ;; *) die "IRONLOG_S3_TIER must be 'on' or 'off' (got '$TIER')" ;; esac
[[ "$HOT_DAYS" =~ ^[1-9][0-9]*$ ]] || die "IRONLOG_HOT_DAYS must be a positive integer (got '$HOT_DAYS')"
[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || die "IRONLOG_RETENTION_DAYS must be a positive integer (got '$RETENTION_DAYS')"
if [ "$TIER" = "on" ] && [ "$RETENTION_DAYS" -le "$HOT_DAYS" ]; then
  die "IRONLOG_RETENTION_DAYS ($RETENTION_DAYS) must exceed IRONLOG_HOT_DAYS ($HOT_DAYS) when the S3 tier is on"
fi
for v in CH_VECTOR_PASSWORD CH_GRAFANA_ANALYST_PASSWORD CH_GRAFANA_AUDITOR_PASSWORD; do
  [ -n "${!v:-}" ] || die "$v is required"
done

ch() { clickhouse-client "$@"; }
q() { ch --query "$1"; }
# SQL string-literal escape for passwords.
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\'/\\\'}"; }
# Table TTL as ClickHouse prints it in system.tables.engine_full.
TTL_RE=" TTL (.*?)( SETTINGS|\$)"
ttl_of() { ch --format TSVRaw --query "SELECT extract(engine_full, '$TTL_RE') FROM system.tables WHERE database = 'siem' AND name = '$1'"; }

log "waiting up to ${WAIT_SECONDS}s for ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT} as ${CLICKHOUSE_USER}"
ok=""; err=""
for _ in $(seq "$WAIT_SECONDS"); do
  if err=$(ch --query "SELECT 1" 2>&1 >/dev/null); then ok=1; break; fi
  sleep 1
done
[ -n "$ok" ] || die "server not reachable with the admin credentials: ${err:-unknown}"

# Tables that have no text index yet (upgrade from tokenbf_v1): compute BEFORE
# the DDL, MATERIALIZE after (logic from clickhouse/initdb/99-init.sh).
NEEDS_MATERIALIZE="$(q "SELECT name FROM system.tables WHERE database = 'siem' AND name IN ('windows_events','linux_syslog','k8s_logs') AND name NOT IN (SELECT \`table\` FROM system.data_skipping_indices WHERE database = 'siem' AND name = 'idx_msg_text')")"

for f in "$DDL_DIR"/*.sql; do
  log "applying $f"
  ch --queries-file "$f"
done

for t in $NEEDS_MATERIALIZE; do
  log "materializing siem.${t}.idx_msg_text for existing parts"
  q "ALTER TABLE siem.${t} MATERIALIZE INDEX idx_msg_text SETTINGS mutations_sync = 2"
done

OLD_IDX_TABLES="$(q "SELECT \`table\` FROM system.data_skipping_indices WHERE database = 'siem' AND name = 'idx_msg' AND \`table\` IN (SELECT \`table\` FROM system.data_skipping_indices WHERE database = 'siem' AND name = 'idx_msg_text')")"
for t in $OLD_IDX_TABLES; do
  log "dropping superseded tokenbf_v1 index siem.${t}.idx_msg"
  q "ALTER TABLE siem.${t} DROP INDEX idx_msg"
done

# Service accounts. SQL goes over stdin so passwords never appear in argv.
ch --multiquery <<SQL
CREATE USER IF NOT EXISTS svc_vector IDENTIFIED WITH sha256_password BY '$(esc "$CH_VECTOR_PASSWORD")' DEFAULT ROLE siem_ingest;
GRANT siem_ingest TO svc_vector;
CREATE USER IF NOT EXISTS svc_grafana_analyst IDENTIFIED WITH sha256_password BY '$(esc "$CH_GRAFANA_ANALYST_PASSWORD")' DEFAULT ROLE siem_analyst SETTINGS PROFILE 'siem_reader';
GRANT siem_analyst TO svc_grafana_analyst;
CREATE USER IF NOT EXISTS svc_grafana_auditor IDENTIFIED WITH sha256_password BY '$(esc "$CH_GRAFANA_AUDITOR_PASSWORD")' DEFAULT ROLE siem_auditor SETTINGS PROFILE 'siem_reader';
GRANT siem_auditor TO svc_grafana_auditor;
SQL

# Tier + retention for the siem.* MergeTree tables. audit.* keeps its own TTL
# (ddl/030_audit.sql, 2 years): see images/clickhouse/README.md.
# ALTER ... MODIFY TTL re-materializes TTL on existing parts, so it only runs
# when the table's current TTL differs from the wanted one.
if [ "$TIER" = "on" ]; then
  want_ttl="event_time + toIntervalDay(${HOT_DAYS}) TO VOLUME 's3', event_time + toIntervalDay(${RETENTION_DAYS})"
  sql_ttl="event_time + INTERVAL ${HOT_DAYS} DAY TO VOLUME 's3', event_time + INTERVAL ${RETENTION_DAYS} DAY DELETE"
  [ "$(q "SELECT count() FROM system.storage_policies WHERE policy_name = '${POLICY}' AND volume_name = 's3'")" -ge 1 ] \
    || die "storage policy ${POLICY} is not loaded: the server was started without IRONLOG_S3_TIER=on"
else
  want_ttl="event_time + toIntervalDay(${RETENTION_DAYS})"
  sql_ttl="event_time + INTERVAL ${RETENTION_DAYS} DAY DELETE"
fi

siem_tables="$(q "SELECT name FROM system.tables WHERE database = 'siem' AND engine LIKE '%MergeTree' ORDER BY name")"
for t in $siem_tables; do
  if [ "$TIER" = "on" ] && [ "$(q "SELECT storage_policy FROM system.tables WHERE database = 'siem' AND name = '$t'")" != "$POLICY" ]; then
    # Accepted because ${POLICY} contains every volume ('default') and disk of
    # the 'default' policy the tables were created with.
    log "siem.${t}: storage_policy -> ${POLICY}"
    q "ALTER TABLE siem.${t} MODIFY SETTING storage_policy = '${POLICY}'"
  fi
  if [ "$(ttl_of "$t")" != "$want_ttl" ]; then
    log "siem.${t}: TTL -> ${sql_ttl}"
    q "ALTER TABLE siem.${t} MODIFY TTL ${sql_ttl}"
  fi
done

# --- verification -----------------------------------------------------------
EXPECTED_TABLES="'cloudtrail','guardduty','k8s_logs','linux_syslog','s3_access','vpc_flow','windows_events'"
table_count="$(q "SELECT count() FROM system.tables WHERE database = 'siem' AND name IN ($EXPECTED_TABLES)")"
audit_count="$(q "SELECT count() FROM system.tables WHERE database = 'audit' AND name = 'query_archive'")"
user_count="$(q "SELECT count() FROM system.users WHERE name IN ('svc_vector','svc_grafana_analyst','svc_grafana_auditor')")"
bad_ttl=0
for t in $(q "SELECT name FROM system.tables WHERE database = 'siem' AND engine LIKE '%MergeTree'"); do
  [ "$(ttl_of "$t")" = "$want_ttl" ] || bad_ttl=$((bad_ttl + 1))
done
if [ "$TIER" = "on" ]; then want_policy="$POLICY"; else want_policy="default"; fi
bad_policy="$(q "SELECT count() FROM system.tables WHERE database = 'siem' AND engine LIKE '%MergeTree' AND storage_policy != '$want_policy'")"
log "verification: siem tables=${table_count}/7 audit.query_archive=${audit_count}/1 service accounts=${user_count}/3 tables with wrong TTL=${bad_ttl} wrong storage policy=${bad_policy} (tier=${TIER})"
if [ "$table_count" != 7 ] || [ "$audit_count" != 1 ] || [ "$user_count" != 3 ] || [ "$bad_ttl" != 0 ] || [ "$bad_policy" != 0 ]; then
  if [ "$TIER" = "off" ] && [ "$bad_policy" != 0 ]; then
    echo "[$TAG] Tables use a non-default storage policy but IRONLOG_S3_TIER is off; the S3 tier cannot be removed from existing tables here." >&2
  fi
  die "schema verification failed"
fi
log "SIEM schema, TTLs and service accounts verified"
