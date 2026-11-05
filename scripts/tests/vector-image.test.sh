#!/usr/bin/env bash
# Build ironlog-vector and prove the images/README.md contract for it.
# Needs a docker CLI (override with DOCKER="wsl -e docker" style via DOCKER env).
set -uo pipefail

DOCKER="${DOCKER:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
CH_IMAGE="${CH_IMAGE:-docker.io/clickhouse/clickhouse-server:26.8.34.13}"
IMG="ironlog-vector:test-$$"
NET="ironlog-vtest-$$"
CHC="ironlog-vtest-ch-$$"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARB_USER="1000770000:0"
CH_ADMIN_PW="adminpw-test"
CH_VEC_PW="vecpw-test"
HEC_TOKEN="hec-test-token"
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
cleanup() {
  $DOCKER rm -f "$CHC" ironlog-vtest-hosts-$$ ironlog-vtest-aws-$$ >/dev/null 2>&1
  $DOCKER network rm "$NET" >/dev/null 2>&1
  $DOCKER rmi -f "$IMG" >/dev/null 2>&1
}
trap cleanup EXIT

wait_for() { # wait_for <seconds> <cmd...>
  local n=$1; shift
  for _ in $(seq "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
dummy_env=(-e SPLUNK_HEC_TOKEN=x -e CH_VECTOR_PASSWORD=x -e AWS_REGION=us-east-1
  -e SQS_URL_CLOUDTRAIL=https://sqs.us-east-1.amazonaws.com/1/a
  -e SQS_URL_GUARDDUTY=https://sqs.us-east-1.amazonaws.com/1/b
  -e SQS_URL_VPCFLOW=https://sqs.us-east-1.amazonaws.com/1/c
  -e SQS_URL_S3ACCESS=https://sqs.us-east-1.amazonaws.com/1/d)

echo "== 1. build ($PLATFORM)"
if $DOCKER build --platform "$PLATFORM" -f "$ROOT/images/vector/Dockerfile" -t "$IMG" "$ROOT" >/dev/null; then
  pass "image builds"
else
  fail "image build"; exit 1
fi

echo "== 2. image metadata"
user=$($DOCKER image inspect -f '{{.Config.User}}' "$IMG")
[ -n "$user" ] && [ "${user%%:*}" != "0" ] && [ "${user%%:*}" != "root" ] \
  && pass "non-root default user ($user)" || fail "default user is '$user'"
ienv=$($DOCKER image inspect -f '{{join .Config.Env "\n"}}' "$IMG")
grep -qx 'VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true' <<<"$ienv" \
  && pass "env interpolation flag baked" || fail "interpolation flag missing"

echo "== 3. vector test (both files), default user"
$DOCKER run --rm --platform "$PLATFORM" "${dummy_env[@]}" "$IMG" \
  test /etc/vector/vector.yaml /etc/vector/tests.yaml \
  && pass "vector test tests.yaml" || fail "vector test tests.yaml"
$DOCKER run --rm --platform "$PLATFORM" "${dummy_env[@]}" "$IMG" \
  test /etc/vector/hosts.yaml /etc/vector/tests-hosts.yaml \
  && pass "vector test tests-hosts.yaml" || fail "vector test tests-hosts.yaml"

echo "== 4. role selection errors"
for r in "" bogus; do
  out=$($DOCKER run --rm --platform "$PLATFORM" -e "IRONLOG_VECTOR_ROLE=$r" "$IMG" 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q "IRONLOG_VECTOR_ROLE must be" <<<"$out"; then
    pass "role='$r' exits $rc: $out"
  else
    fail "role='$r' rc=$rc out=$out"
  fi
done

echo "== 5. role=aws validates without AWS, as arbitrary uid"
out=$($DOCKER run --rm --platform "$PLATFORM" --user "$ARB_USER" "${dummy_env[@]}" \
  -e IRONLOG_VECTOR_ROLE=aws "$IMG" validate --no-environment /etc/vector/vector.yaml 2>&1); rc=$?
echo "$out" | tail -5
[ $rc -eq 0 ] && pass "aws config validates (--no-environment)" || fail "aws validate rc=$rc"

echo "== 6. real ClickHouse + role=hosts end-to-end, as --user $ARB_USER"
$DOCKER network create "$NET" >/dev/null
$DOCKER run -d --name "$CHC" --network "$NET" --platform "$PLATFORM" \
  -e CLICKHOUSE_USER=admin -e CLICKHOUSE_PASSWORD="$CH_ADMIN_PW" -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 "$CH_IMAGE" >/dev/null
chq() { $DOCKER exec "$CHC" clickhouse-client --user admin --password "$CH_ADMIN_PW" "$@"; }
if ! wait_for 90 chq --query "SELECT 1"; then fail "clickhouse did not start"; exit 1; fi
$DOCKER exec "$CHC" mkdir -p /tmp/ddl
$DOCKER cp "$ROOT/clickhouse/ddl/." "$CHC:/tmp/ddl/"
for f in $(ls "$ROOT"/clickhouse/ddl/*.sql | sort); do
  chq --queries-file "/tmp/ddl/$(basename "$f")" >/dev/null 2>"/tmp/ddl-err-$$" \
    || { fail "DDL $(basename "$f"): $(cat /tmp/ddl-err-$$)"; }
done
rm -f "/tmp/ddl-err-$$"
chq --query "CREATE USER IF NOT EXISTS svc_vector IDENTIFIED WITH sha256_password BY '$CH_VEC_PW' DEFAULT ROLE siem_ingest" \
  && chq --query "GRANT siem_ingest TO svc_vector" && pass "DDL + svc_vector applied" || fail "svc_vector setup"

$DOCKER run -d --name "ironlog-vtest-hosts-$$" --network "$NET" --platform "$PLATFORM" \
  --user "$ARB_USER" -e IRONLOG_VECTOR_ROLE=hosts -e IRONLOG_CLICKHOUSE_HOST="$CHC" \
  -e CH_VECTOR_PASSWORD="$CH_VEC_PW" -e SPLUNK_HEC_TOKEN="$HEC_TOKEN" \
  -p 127.0.0.1:18088:8088 "$IMG" >/dev/null
hc() { $DOCKER exec "ironlog-vtest-hosts-$$" /usr/local/bin/ironlog-healthcheck; }
if wait_for 60 hc; then pass "ironlog-healthcheck succeeds (GET /health 200)"
else fail "hosts healthcheck"; $DOCKER logs "ironlog-vtest-hosts-$$" 2>&1 | tail -20; fi
[ "$($DOCKER exec "ironlog-vtest-hosts-$$" id -u)" = "1000770000" ] && pass "running as uid 1000770000" || fail "uid"

marker="vector-image-test-$$"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Splunk $HEC_TOKEN" \
  -d "{\"event\":{\"cluster\":\"test\",\"namespace\":\"ns\",\"node\":\"n1\",\"container\":\"c\",\"pod\":\"p\",\"level\":\"info\",\"message\":\"$marker\"}}" \
  http://127.0.0.1:18088/services/collector/event)
[ "$code" = "200" ] && pass "HEC POST accepted (200)" || fail "HEC POST http=$code"
bad=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Splunk wrong" -d '{"event":"x"}' \
  http://127.0.0.1:18088/services/collector/event)
[ "$bad" = "401" ] && pass "bad HEC token rejected (401)" || fail "bad token http=$bad"
rows=0
# Disk buffer plus a 5 s batch: normally a few seconds, slower on a busy runner.
for _ in $(seq 90); do
  rows=$(chq --query "SELECT count() FROM siem.k8s_logs WHERE message = '$marker'")
  [ "$rows" = "1" ] && break; sleep 1
done
[ "$rows" = "1" ] && pass "row landed in siem.k8s_logs" || {
  fail "row count=$rows"; $DOCKER logs "ironlog-vtest-hosts-$$" 2>&1 | tail -20
  chq --query "SYSTEM FLUSH LOGS"
  chq --query "SELECT event_time, user, type, exception FROM system.query_log WHERE query_kind = 'Insert' ORDER BY event_time DESC LIMIT 10 FORMAT TSV"; }
chq --query "SELECT cluster, namespace, level, message FROM siem.k8s_logs WHERE message = '$marker' FORMAT TSV"

echo "== 7. role=aws runs and reports healthy, as --user $ARB_USER"
$DOCKER run -d --name "ironlog-vtest-aws-$$" --network "$NET" --platform "$PLATFORM" --user "$ARB_USER" \
  "${dummy_env[@]}" -e IRONLOG_VECTOR_ROLE=aws -e IRONLOG_CLICKHOUSE_HOST="$CHC" "$IMG" >/dev/null
if wait_for 60 $DOCKER exec "ironlog-vtest-aws-$$" /usr/local/bin/ironlog-healthcheck; then
  pass "aws role healthy (no real AWS; sources retry in background)"
else
  fail "aws role health"; $DOCKER logs "ironlog-vtest-aws-$$" 2>&1 | tail -20
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
