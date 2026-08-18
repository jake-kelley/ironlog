#!/bin/bash
# ironlog-apply-schema.sh — reconcile the ClickHouse SIEM schema and service
# accounts on EVERY boot, and FAIL LOUDLY if the result is not what we expect.
#
# WHY THIS EXISTS (do not remove it as redundant with initdb):
# The clickhouse-server image runs /docker-entrypoint-initdb.d/* exactly once,
# and only when /var/lib/clickhouse/metadata is empty. On a launched appliance
# that data dir is a bind mount on the persistent data volume, so ANY failed or
# partial first boot leaves a non-empty metadata dir -- and from then on the
# entrypoint sets DATABASE_ALREADY_EXISTS and skips initdb forever. Measured on
# a real c7g.large 2026-08-18: a first boot with an unexpanded $CH_ADMIN_USER
# poisoned the data dir, and every subsequent (correct) start came up with NO
# siem database, NO audit database and NO service accounts while reporting
# `healthy` -- because the container healthcheck is `SELECT 1`, which answers
# perfectly well against a server with no schema at all. Grafana, HyperDX and
# Vector all started successfully against an empty database and ingested
# nothing, silently.
#
# This script closes that hole. It re-runs the SAME initdb script inside the
# container (every statement in clickhouse/ddl/*.sql is CREATE ... IF NOT
# EXISTS, and ClickHouse GRANT is a no-op when already granted, so applying it
# repeatedly is safe), then VERIFIES the outcome and exits non-zero if the
# schema or the service accounts are incomplete. ironlog-schema.service is a
# Requires= dependency of every unit that talks to ClickHouse, so a failure
# here stops them starting instead of letting them come up against nothing.
#
# It deliberately execs the container's own /docker-entrypoint-initdb.d/99-init.sh
# rather than reimplementing it: that keeps ONE copy of the user-creation SQL,
# and the container already holds CLICKHOUSE_USER/CLICKHOUSE_PASSWORD and the
# CH_*_PASSWORD values in its environment, so no secret is read, copied or
# logged by this script at all.
set -euo pipefail

LOG_TAG="ironlog-schema"
CONTAINER="ironlog-clickhouse"
INITDB="/docker-entrypoint-initdb.d/99-init.sh"

log() { echo "[$LOG_TAG] $*"; }
die() { echo "[$LOG_TAG] FATAL: $*" >&2; exit 1; }

# Run a query as the admin user, expanding the credentials INSIDE the
# container so they never appear in this script's argv or in the journal.
ch_query() {
	podman exec "$CONTAINER" bash -c \
		'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$0"' \
		"$1"
}

podman container exists "$CONTAINER" \
	|| die "container $CONTAINER does not exist -- ironlog-clickhouse.service should have created it before this unit ran"

log "applying $INITDB inside $CONTAINER (idempotent: all DDL is CREATE ... IF NOT EXISTS)"
if ! podman exec "$CONTAINER" bash "$INITDB"; then
	die "$INITDB failed inside $CONTAINER -- see the output above for the failing statement. The appliance has an incomplete SIEM schema and will not ingest; do NOT treat a green boot as working."
fi

# --- verification: the whole point of this unit ---------------------------
# Checked explicitly rather than trusting the exit code above, because the
# failure mode we are guarding against (initdb skipped entirely) produces no
# error at all.
EXPECTED_TABLES="'cloudtrail','guardduty','k8s_logs','linux_syslog','s3_access','vpc_flow','windows_events'"
EXPECTED_TABLE_COUNT=7
EXPECTED_USERS="'svc_vector','svc_grafana_analyst','svc_grafana_auditor','svc_hyperdx'"
EXPECTED_USER_COUNT=4

table_count="$(ch_query "SELECT count() FROM system.tables WHERE database = 'siem' AND name IN ($EXPECTED_TABLES)" | tr -d '[:space:]')"
audit_count="$(ch_query "SELECT count() FROM system.tables WHERE database = 'audit' AND name = 'query_archive'" | tr -d '[:space:]')"
user_count="$(ch_query "SELECT count() FROM system.users WHERE name IN ($EXPECTED_USERS)" | tr -d '[:space:]')"

log "verification: siem tables=$table_count/$EXPECTED_TABLE_COUNT audit.query_archive=$audit_count/1 service accounts=$user_count/$EXPECTED_USER_COUNT"

if [ "$table_count" != "$EXPECTED_TABLE_COUNT" ] || [ "$audit_count" != "1" ] || [ "$user_count" != "$EXPECTED_USER_COUNT" ]; then
	echo "[$LOG_TAG] The SIEM schema is missing or incomplete after applying $INITDB." >&2
	echo "[$LOG_TAG] Most likely cause: the ClickHouse data volume was initialised by an earlier FAILED boot," >&2
	echo "[$LOG_TAG] so the image entrypoint now skips initdb permanently (DATABASE_ALREADY_EXISTS)." >&2
	echo "[$LOG_TAG] If /var/lib/ironlog/clickhouse holds no events you care about, reset it with:" >&2
	echo "[$LOG_TAG]   systemctl stop ironlog-vector-hosts ironlog-hyperdx ironlog-grafana ironlog-clickhouse" >&2
	echo "[$LOG_TAG]   find /var/lib/ironlog/clickhouse -mindepth 1 -delete" >&2
	echo "[$LOG_TAG]   systemctl start ironlog-clickhouse ironlog-schema" >&2
	echo "[$LOG_TAG] That command DESTROYS all stored events -- confirm the volume is disposable first." >&2
	die "schema verification failed"
fi

log "SIEM schema and service accounts verified"
