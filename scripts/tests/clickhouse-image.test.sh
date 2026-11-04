#!/usr/bin/env bash
# Build ironlog-clickhouse and prove the images/README.md contract for it.
# Needs a docker CLI and an S3-compatible store image for the tier test.
# Run inside the docker host shell (e.g. `wsl -e bash scripts/tests/clickhouse-image.test.sh`).
set -uo pipefail

DOCKER="${DOCKER:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
# docker.io/minio/minio no longer exists on Docker Hub (2026-11-04), so the
# pinned S3-compatible store is SeaweedFS.
S3_IMAGE="${S3_IMAGE:-docker.io/chrislusf/seaweedfs:4.52}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SFX="$$"
IMG="ironlog-clickhouse:test-$SFX"
NET="ironlog-chtest-$SFX"
ARB_USER="1000770000:0"
ADMIN_PW="adminpw'test"   # includes a quote on purpose (no shell/SQL breakage)
VEC_PW="vecpw'test"
ENVS=(-e CLICKHOUSE_USER=admin -e "CLICKHOUSE_PASSWORD=$ADMIN_PW" -e "CH_VECTOR_PASSWORD=$VEC_PW"
  -e CH_GRAFANA_ANALYST_PASSWORD=anapw -e CH_GRAFANA_AUDITOR_PASSWORD=audpw)
VERIFIED="SIEM schema, TTLs and service accounts verified"
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
cleanup() {
  for c in $($DOCKER ps -aq --filter "label=ironlog-chtest=$SFX"); do $DOCKER rm -f "$c" >/dev/null 2>&1; done
  for v in $($DOCKER volume ls -q --filter "label=ironlog-chtest=$SFX"); do $DOCKER volume rm -f "$v" >/dev/null 2>&1; done
  $DOCKER network rm "$NET" >/dev/null 2>&1
  $DOCKER rmi -f "$IMG" >/dev/null 2>&1
}
trap cleanup EXIT

LBL=(--label "ironlog-chtest=$SFX")
vol() { $DOCKER volume create "${LBL[@]}" "ironlog-chtest-$1-$SFX" >/dev/null; echo "ironlog-chtest-$1-$SFX"; }
# start <name> <volume> [docker args...]
start() { local n=$1 v=$2; shift 2
  $DOCKER run -d --name "$n-$SFX" "${LBL[@]}" --network "$NET" --platform "$PLATFORM" -v "$v:/var/lib/clickhouse" "$@" "$IMG" >/dev/null; }
logs_count() { $DOCKER logs "$1-$SFX" 2>&1 | grep -c "$VERIFIED"; }
# wait_verified <name> <count> [seconds]: the in-container startup run finished N times
wait_verified() { local n=$1 want=$2 s=${3:-150}
  for _ in $(seq "$s"); do [ "$(logs_count "$n")" -ge "$want" ] && return 0; sleep 1; done; return 1; }
admin() { local n=$1; shift; $DOCKER exec "$n-$SFX" bash -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"' _ "$@"; }
insert_probe() { # insert_probe <name> <marker>: as svc_vector
  $DOCKER exec -e "VP=$VEC_PW" "$1-$SFX" bash -c \
    'clickhouse-client --user svc_vector --password "$VP" --query "INSERT INTO siem.k8s_logs (event_time, cluster, namespace, node, container, pod, level, message) VALUES (now(), '"'c'"', '"'n'"', '"'n1'"', '"'c'"', '"'p'"', '"'info'"', '"'$2'"')"'; }

echo "== 1. build ($PLATFORM)"
if $DOCKER build --platform "$PLATFORM" -f "$ROOT/images/clickhouse/Dockerfile" -t "$IMG" "$ROOT" >/dev/null; then
  pass "image builds"
else
  fail "image build"; exit 1
fi
$DOCKER network create "$NET" >/dev/null

echo "== 2. image metadata and refusal paths"
user=$($DOCKER image inspect -f '{{.Config.User}}' "$IMG")
[ -n "$user" ] && [ "${user%%:*}" != "0" ] && [ "${user%%:*}" != "root" ] \
  && pass "non-root default user ($user)" || fail "default user is '$user'"
out=$($DOCKER run --rm "$IMG" 2>&1); rc=$?
[ $rc -eq 64 ] && grep -q "CLICKHOUSE_USER is required" <<<"$out" && pass "no credentials -> exit 64: $out" || fail "no credentials rc=$rc out=$out"
out=$($DOCKER run --rm "${ENVS[@]}" -e IRONLOG_S3_TIER=on "$IMG" 2>&1); rc=$?
[ $rc -eq 64 ] && grep -q "requires IRONLOG_S3_ENDPOINT" <<<"$out" && pass "tier on without endpoint -> exit 64" || fail "tier on w/o endpoint rc=$rc out=$out"

echo "== 3. (a) default user, empty volume"
V1=$(vol a)
start a "$V1" "${ENVS[@]}"
if wait_verified a 1; then pass "startup ironlog-schema verified (empty volume)"; else
  fail "startup ironlog-schema did not verify"; $DOCKER logs "a-$SFX" 2>&1 | grep -E "ironlog-|Exception" | tail -20; fi
$DOCKER exec "a-$SFX" ironlog-schema >/dev/null 2>&1 && pass "second ironlog-schema run exits 0 (idempotent)" || fail "re-run"
[ "$(admin a --query "SELECT count() FROM system.users WHERE name IN ('svc_vector','svc_grafana_analyst','svc_grafana_auditor')")" = 3 ] \
  && pass "3 service accounts exist" || fail "accounts"
[ "$($DOCKER exec "a-$SFX" id -u)" = "10001" ] && pass "runs as uid 10001" || fail "uid"
for _ in $(seq 60); do [ "$($DOCKER inspect -f '{{.State.Health.Status}}' "a-$SFX")" = healthy ] && break; sleep 1; done
[ "$($DOCKER inspect -f '{{.State.Health.Status}}' "a-$SFX")" = healthy ] && pass "HEALTHCHECK healthy" || fail "health"
insert_probe a probe-a && pass "svc_vector INSERT into siem.k8s_logs" || fail "svc_vector insert"
n=$(admin a --query "SELECT count() FROM siem.k8s_logs WHERE message = 'probe-a'")
[ "$n" = 1 ] && pass "row visible to admin" || fail "row count $n"
if $DOCKER exec -e "VP=$VEC_PW" "a-$SFX" bash -c 'clickhouse-client --user svc_vector --password "$VP" --query "SELECT 1 FROM siem.k8s_logs LIMIT 1"' >/dev/null 2>&1; then
  fail "svc_vector can SELECT (should be INSERT-only)"; else pass "svc_vector cannot SELECT"; fi
ip=$($DOCKER inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "a-$SFX")
if $DOCKER exec "a-$SFX" clickhouse-client --host "$ip" --user default --query "SELECT 1" >/dev/null 2>&1; then
  fail "built-in default user reachable over the network"; else pass "built-in default user not usable over the network"; fi
[ "$($DOCKER exec "a-$SFX" bash -c 'ls /etc/clickhouse-server/config.d/20-storage-s3.xml 2>/dev/null; echo $?' | tail -1)" != 0 ] \
  && [ "$(admin a --query "SELECT count() FROM system.storage_policies WHERE policy_name = 'hot_to_s3'")" = 0 ] \
  && pass "tier off: no S3 config, no hot_to_s3 policy" || fail "tier off still has S3 config"
echo "-- TTL (tier off):"
admin a --query "SELECT name, extract(engine_full, ' TTL (.*?)( SETTINGS|\$)') AS ttl, storage_policy FROM system.tables WHERE database = 'siem' AND engine LIKE '%MergeTree' ORDER BY name FORMAT TSV"
admin a --query "SELECT 'raw column TTL:', count() FROM system.columns WHERE database = 'siem' AND name = 'raw' AND ttl_expression != ''" | tr '\t' ' '

echo "== 4. (b) restart with the same volume"
$DOCKER restart "a-$SFX" >/dev/null
if wait_verified a 2; then pass "ironlog-schema ran and verified again after restart"; else
  fail "no verified line after restart"; $DOCKER logs "a-$SFX" 2>&1 | grep -E "ironlog-" | tail -10; fi
n=$(admin a --query "SELECT count() FROM siem.k8s_logs WHERE message = 'probe-a'")
[ "$n" = 1 ] && pass "data survived restart" || fail "data after restart: $n"
$DOCKER rm -f "a-$SFX" >/dev/null

echo "== 5. (c) --user $ARB_USER: empty volume, then reused volume"
V2=$(vol c)
start c "$V2" --user "$ARB_USER" "${ENVS[@]}"
if wait_verified c 1; then pass "arbitrary uid: verified on empty volume"; else
  fail "arbitrary uid empty volume"; $DOCKER logs "c-$SFX" 2>&1 | tail -20; fi
[ "$($DOCKER exec "c-$SFX" id -u)" = 1000770000 ] && pass "running as uid 1000770000" || fail "uid"
insert_probe c probe-c && pass "svc_vector INSERT as arbitrary uid" || fail "insert as arbitrary uid"
$DOCKER restart "c-$SFX" >/dev/null
wait_verified c 2 && pass "arbitrary uid: verified again on reused volume" || { fail "arbitrary uid reused volume"; $DOCKER logs "c-$SFX" 2>&1 | tail -20; }
[ "$(admin c --query "SELECT count() FROM siem.k8s_logs WHERE message = 'probe-c'")" = 1 ] && pass "data survived (arbitrary uid)" || fail "data (arbitrary uid)"
$DOCKER rm -f "c-$SFX" >/dev/null
# volume written by the default user (uid 10001), reused by a random uid with gid 0
start a2 "$V1" --user "$ARB_USER" "${ENVS[@]}"
wait_verified a2 1 && [ "$(admin a2 --query "SELECT count() FROM siem.k8s_logs WHERE message = 'probe-a'")" = 1 ]   && pass "volume written by uid 10001 is reusable by $ARB_USER" || { fail "uid 10001 volume reused by arbitrary uid"; $DOCKER logs "a2-$SFX" 2>&1 | tail -15; }
$DOCKER rm -f "a2-$SFX" >/dev/null

echo "== 6. (e) remote one-shot from a second container"
V3=$(vol e)
start e "$V3" "${ENVS[@]}"
# server up; its own startup run is not awaited here -- the one-shot must work on its own
shot() { $DOCKER run --rm --network "$NET" --platform "$PLATFORM" "${ENVS[@]}" -e "IRONLOG_CLICKHOUSE_HOST=e-$SFX" "$@" "$IMG" ironlog-schema; }
out=$(shot 2>&1); rc=$?
tail -2 <<<"$out"
[ $rc -eq 0 ] && pass "remote one-shot exits 0 and verifies" || fail "remote one-shot rc=$rc"
out=$(shot --user "$ARB_USER" 2>&1); rc=$?
[ $rc -eq 0 ] && pass "remote one-shot as $ARB_USER exits 0" || { fail "one-shot arbitrary uid rc=$rc"; echo "$out" | tail -5; }
out=$($DOCKER run --rm --network "$NET" "${ENVS[@]}" -e CLICKHOUSE_PASSWORD=wrong -e "IRONLOG_CLICKHOUSE_HOST=e-$SFX" -e IRONLOG_SCHEMA_WAIT_SECONDS=3 "$IMG" ironlog-schema 2>&1); rc=$?
[ $rc -ne 0 ] && pass "wrong admin password -> exit $rc" || fail "wrong password exited 0"
admin e --query "DROP TABLE siem.vpc_flow" >/dev/null
out=$($DOCKER run --rm --network "$NET" "${ENVS[@]}" -e "IRONLOG_CLICKHOUSE_HOST=e-$SFX" "$IMG" \
  bash -c 'mkdir /tmp/d && cp /ddl/020_hosts.sql /tmp/d/ && IRONLOG_DDL_DIR=/tmp/d ironlog-schema' 2>&1); rc=$?
tail -2 <<<"$out"
[ $rc -ne 0 ] && grep -q "schema verification failed" <<<"$out" && pass "missing table -> verification fails (exit $rc)" || fail "missing table not detected rc=$rc"
shot >/dev/null 2>&1 && pass "full run repairs the dropped table" || fail "repair"
$DOCKER rm -f "e-$SFX" >/dev/null

echo "== 7. (d) tier on against $S3_IMAGE, existing tier-off volume switched over"
S3C="s3-$SFX"
$DOCKER run -d --name "$S3C" "${LBL[@]}" --network "$NET" --platform "$PLATFORM" -p 127.0.0.1:18333:8333 "$S3_IMAGE" \
  server -s3 -dir=/data -s3.port=8333 -ip.bind=0.0.0.0 >/dev/null
for _ in $(seq 60); do curl -s -o /dev/null -X PUT http://127.0.0.1:18333/ironlog && break; sleep 1; done
curl -s -o /dev/null -w 'bucket create http=%{http_code}\n' -X PUT http://127.0.0.1:18333/ironlog
V4=$(vol d)
start d "$V4" "${ENVS[@]}"           # tier OFF first: tables exist with the default policy and hold data
wait_verified d 1 || fail "tier-off start before switch"
insert_probe d probe-d-old >/dev/null
$DOCKER rm -f "d-$SFX" >/dev/null
S3ENV=(-e IRONLOG_S3_TIER=on -e "IRONLOG_S3_ENDPOINT=http://$S3C:8333/ironlog/ch/" -e IRONLOG_S3_ACCESS_KEY_ID=testkey
  -e IRONLOG_S3_SECRET_ACCESS_KEY=testsecret-sentinel -e IRONLOG_S3_REGION=us-east-1 -e IRONLOG_HOT_DAYS=7 -e IRONLOG_RETENTION_DAYS=100)
start d "$V4" "${ENVS[@]}" "${S3ENV[@]}"
if wait_verified d 1; then pass "tier on: ironlog-schema verified on existing tier-off volume"; else
  fail "tier on verify"; $DOCKER logs "d-$SFX" 2>&1 | grep -E "ironlog-|Exception" | tail -20; fi
$DOCKER logs "d-$SFX" 2>&1 | grep -E "storage_policy ->|TTL ->" | head -3
! $DOCKER logs "d-$SFX" 2>&1 | grep -q "testsecret-sentinel" && pass "secret not in container logs" || fail "secret in logs"
! $DOCKER exec "d-$SFX" grep -q "testsecret-sentinel" /etc/clickhouse-server/config.d/20-storage-s3.xml \
  && pass "secret not written into generated config" || fail "secret in generated config"
echo "-- generated config:"; $DOCKER exec "d-$SFX" cat /etc/clickhouse-server/config.d/20-storage-s3.xml | grep -E "endpoint|key|region|creden"
$DOCKER exec "d-$SFX" stat -c '%a %u:%g' /etc/clickhouse-server/config.d/20-storage-s3.xml
admin d --query "SELECT policy_name, volume_name, disks FROM system.storage_policies WHERE policy_name = 'hot_to_s3' FORMAT TSV"
[ "$(admin d --query "SELECT count() FROM system.storage_policies WHERE policy_name = 'hot_to_s3' AND volume_name = 's3'")" = 1 ] \
  && pass "storage policy hot_to_s3 with volume s3 present" || fail "policy"
admin d --query "SELECT name, extract(engine_full, ' TTL (.*?)( SETTINGS|\$)') AS ttl, storage_policy FROM system.tables WHERE database = 'siem' AND engine LIKE '%MergeTree' ORDER BY name FORMAT TSV"
[ "$(admin d --query "SELECT count() FROM system.tables WHERE database = 'siem' AND engine LIKE '%MergeTree' AND storage_policy = 'hot_to_s3' AND engine_full LIKE '%toIntervalDay(7) TO VOLUME ''s3''%toIntervalDay(100)%'")" = 7 ] \
  && pass "all 7 tables: hot_to_s3 + 'TTL 7d TO VOLUME s3, 100d DELETE'" || fail "table TTL/policy"
[ "$(admin d --query "SELECT count() FROM siem.k8s_logs WHERE message = 'probe-d-old'")" = 1 ] && pass "pre-switch row still readable" || fail "pre-switch row lost"
insert_probe d probe-d-new >/dev/null
part=$(admin d --query "SELECT partition_id FROM system.parts WHERE database = 'siem' AND table = 'k8s_logs' AND active AND disk_name = 'default' LIMIT 1")
admin d --query "ALTER TABLE siem.k8s_logs MOVE PARTITION ID '$part' TO VOLUME 's3'" && pass "MOVE PARTITION ... TO VOLUME 's3' accepted" || fail "move partition"
for _ in $(seq 30); do [ "$(admin d --query "SELECT count() FROM system.parts WHERE database = 'siem' AND table = 'k8s_logs' AND active AND disk_name = 's3_cold'")" -ge 1 ] && break; sleep 1; done
admin d --query "SELECT disk_name, count() AS parts, sum(rows) AS rows FROM system.parts WHERE database = 'siem' AND table = 'k8s_logs' AND active GROUP BY disk_name FORMAT TSV"
[ "$(admin d --query "SELECT count() FROM system.parts WHERE database = 'siem' AND table = 'k8s_logs' AND active AND disk_name = 's3_cold'")" -ge 1 ] \
  && pass "a part lives on disk s3_cold" || fail "no part on s3_cold"
[ "$(admin d --query "SELECT count() FROM siem.k8s_logs WHERE message LIKE 'probe-d-%'")" = 2 ] && pass "rows readable from the S3 disk" || fail "rows after move"
objs=$(curl -s "http://127.0.0.1:18333/ironlog?list-type=2&prefix=ch/" | grep -o "<Key>" | wc -l)
[ "$objs" -ge 1 ] && pass "objects present in the bucket ($objs keys)" || fail "no objects in bucket"
$DOCKER restart "d-$SFX" >/dev/null
wait_verified d 2 && pass "tier on: verified again after restart" || fail "tier on restart"
[ "$(admin d --query "SELECT count() FROM siem.k8s_logs WHERE message LIKE 'probe-d-%'")" = 2 ] && pass "rows readable after restart" || fail "rows after restart"
$DOCKER rm -f "d-$SFX" >/dev/null
# no static keys -> environment credentials
start d2 "$(vol d2)" "${ENVS[@]}" -e IRONLOG_S3_TIER=on -e "IRONLOG_S3_ENDPOINT=http://$S3C:8333/ironlog/env/"
sleep 8
$DOCKER exec "d2-$SFX" grep -q "<use_environment_credentials>true" /etc/clickhouse-server/config.d/20-storage-s3.xml \
  && ! $DOCKER exec "d2-$SFX" grep -q "access_key_id\|<region" /etc/clickhouse-server/config.d/20-storage-s3.xml \
  && pass "no static keys -> use_environment_credentials, no key/region elements" || fail "env-credential config"
$DOCKER rm -f "d2-$SFX" >/dev/null

echo "== 8. IRONLOG_CLICKHOUSE_ALLOWED_HOSTS"
out=$($DOCKER run --rm "${ENVS[@]}" -e "IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=10.0.0.1,evil'; DROP" "$IMG" 2>&1); rc=$?
[ $rc -eq 64 ] && grep -q "ALLOWED_HOSTS: invalid entry" <<<"$out" && pass "invalid allowlist entry -> server container exit 64" || fail "invalid allowlist (server) rc=$rc out=$out"
out=$($DOCKER run --rm "${ENVS[@]}" -e "IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=10.0.0.1/33" "$IMG" ironlog-schema 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "ALLOWED_HOSTS" <<<"$out" && pass "invalid allowlist entry -> ironlog-schema exits $rc before touching the server" || fail "invalid allowlist (schema) rc=$rc out=$out"
V5=$(vol h)
start h "$V5" "${ENVS[@]}" -e IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=127.0.0.1
wait_verified h 1 || { fail "allowlist start did not verify"; $DOCKER logs "h-$SFX" 2>&1 | tail -15; }
hip=$($DOCKER inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "h-$SFX")
peer() { $DOCKER run --rm --network "$NET" --platform "$PLATFORM" --entrypoint clickhouse-client "$IMG" --host "$hip" "$@" --query "SELECT 1" 2>&1; }
out=$(peer --user svc_grafana_analyst --password anapw); [ "$out" != 1 ] && grep -q "IP address is not allowed" <<<"$out" && pass "svc_grafana_analyst refused from another container" || fail "analyst from peer: $out"
out=$(peer --user svc_vector --password "$VEC_PW"); [ "$out" != 1 ] && grep -q "IP address is not allowed" <<<"$out" && pass "svc_vector refused from another container" || fail "vector from peer: $out"
out=$(peer --user admin --password "$ADMIN_PW"); [ "$out" != 1 ] && grep -q "IP address is not allowed" <<<"$out" && pass "admin refused from another container" || fail "admin from peer: $out"
[ "$(admin h --query "SELECT count() FROM system.users WHERE name LIKE 'svc_%' AND NOT has(host_ip, '::/0')")" = 3 ] && pass "3 service accounts restricted (host_ip has no ::/0)" || fail "host_ip restriction"
# allowlist the peer's network, re-run the one-shot from it: schema must reconcile to it
sub="${hip%.*}.0/24"
$DOCKER exec -e "IRONLOG_CLICKHOUSE_ALLOWED_HOSTS=$sub" "h-$SFX" ironlog-schema >/dev/null 2>&1
out=$(peer --user svc_grafana_analyst --password anapw); [ "$out" = 1 ] && pass "allowlisting the peer subnet and re-running ironlog-schema lets it in" || fail "analyst after widening: $out"
$DOCKER exec "h-$SFX" ironlog-schema >/dev/null 2>&1
out=$(peer --user svc_grafana_analyst --password anapw); [ "$out" = 1 ] && pass "clearing the variable (HOST ANY) restores access" || fail "analyst after clearing: $out"
$DOCKER rm -f "h-$SFX" >/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
