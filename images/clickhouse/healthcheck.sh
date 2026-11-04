#!/bin/bash
# Exit 0 when the server answers SELECT 1 with the admin credentials.
exec clickhouse-client --user "${CLICKHOUSE_USER:-default}" --password "${CLICKHOUSE_PASSWORD:-}" --query "SELECT 1" >/dev/null
