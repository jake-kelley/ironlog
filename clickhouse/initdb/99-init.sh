#!/bin/bash
# Runs once on first container start (official image executes /docker-entrypoint-initdb.d).
# 1) Applies all DDL in /ddl in filename order.
# 2) Creates service accounts with passwords from the environment.
set -euo pipefail

ch() { clickhouse-client --user "${CLICKHOUSE_USER}" --password "${CLICKHOUSE_PASSWORD}" "$@"; }

# Tables that already exist WITHOUT the text index (upgrade from the tokenbf_v1
# schema). ddl/025_migrate_text_index.sql adds the index to them; only new parts
# get it, so MATERIALIZE it once for the old parts after the DDL has run. Computed
# BEFORE the DDL so a converged install (and a fresh one) yields an empty list
# and no mutation is queued on later boots.
NEEDS_MATERIALIZE="$(ch --query "SELECT name FROM system.tables WHERE database = 'siem' AND name IN ('windows_events','linux_syslog','k8s_logs') AND name NOT IN (SELECT \`table\` FROM system.data_skipping_indices WHERE database = 'siem' AND name = 'idx_msg_text')")"

for f in /ddl/*.sql; do
  echo "Applying ${f}"
  ch --queries-file "${f}"
done

for t in ${NEEDS_MATERIALIZE}; do
  echo "Materializing siem.${t}.idx_msg_text for existing parts"
  ch --query "ALTER TABLE siem.${t} MATERIALIZE INDEX idx_msg_text SETTINGS mutations_sync = 2"
done

# Retire the superseded tokenbf_v1 index, only where the text index exists.
OLD_IDX_TABLES="$(ch --query "SELECT \`table\` FROM system.data_skipping_indices WHERE database = 'siem' AND name = 'idx_msg' AND \`table\` IN (SELECT \`table\` FROM system.data_skipping_indices WHERE database = 'siem' AND name = 'idx_msg_text')")"
for t in ${OLD_IDX_TABLES}; do
  echo "Dropping superseded tokenbf_v1 index siem.${t}.idx_msg"
  ch --query "ALTER TABLE siem.${t} DROP INDEX idx_msg"
done

ch --query "CREATE USER IF NOT EXISTS svc_vector IDENTIFIED WITH sha256_password BY '${CH_VECTOR_PASSWORD}' DEFAULT ROLE siem_ingest"
ch --query "GRANT siem_ingest TO svc_vector"

ch --query "CREATE USER IF NOT EXISTS svc_grafana_analyst IDENTIFIED WITH sha256_password BY '${CH_GRAFANA_ANALYST_PASSWORD}' DEFAULT ROLE siem_analyst SETTINGS PROFILE 'siem_reader'"
ch --query "GRANT siem_analyst TO svc_grafana_analyst"

ch --query "CREATE USER IF NOT EXISTS svc_grafana_auditor IDENTIFIED WITH sha256_password BY '${CH_GRAFANA_AUDITOR_PASSWORD}' DEFAULT ROLE siem_auditor SETTINGS PROFILE 'siem_reader'"
ch --query "GRANT siem_auditor TO svc_grafana_auditor"

ch --query "CREATE USER IF NOT EXISTS svc_hyperdx IDENTIFIED WITH sha256_password BY '${CH_HYPERDX_PASSWORD}' DEFAULT ROLE siem_analyst SETTINGS PROFILE 'siem_reader'"
ch --query "GRANT siem_analyst TO svc_hyperdx"

echo "SIEM schema and RBAC bootstrap complete."
