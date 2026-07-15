#!/bin/bash
# Runs once on first container start (official image executes /docker-entrypoint-initdb.d).
# 1) Applies all DDL in /ddl in filename order.
# 2) Creates service accounts with passwords from the environment.
set -euo pipefail

ch() { clickhouse-client --user "${CLICKHOUSE_USER}" --password "${CLICKHOUSE_PASSWORD}" "$@"; }

for f in /ddl/*.sql; do
  echo "Applying ${f}"
  ch --queries-file "${f}"
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
