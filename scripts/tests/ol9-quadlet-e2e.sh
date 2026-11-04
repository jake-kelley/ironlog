#!/bin/bash
# ol9-quadlet-e2e.sh: live test of the three ironlog images under podman +
# systemd Quadlets. Runs ON the target host (Oracle Linux 9, SELinux enforcing,
# passwordless sudo) from an extracted repo. Exits non-zero on any failure.
#
#   ./scripts/tests/ol9-quadlet-e2e.sh              # build, install, test
#   IRONLOG_E2E_SKIP_BUILD=1 ./scripts/tests/ol9-quadlet-e2e.sh
#
# Steps: 2 build, 3 arbitrary-UID, 4 install+start, 5 end-to-end, 6 security,
# 7 durability WITHOUT reboot (restart every unit; reboot by hand, see
# quadlets/README.md). Leaves the stack running. Reuses /etc/ironlog/ironlog.env
# if present (never overwritten); otherwise generates random passwords there
# (mode 600). Secrets are never printed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 2
START_TIME="$(date +%H:%M:%S)"
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
step() { echo; echo "== $*"; }
# wait_for SECONDS DESCRIPTION CMD...
wait_for() {
  local t="$1" d="$2"; shift 2
  local i
  for ((i = 0; i < t; i += 2)); do
    if "$@" >/dev/null 2>&1; then pass "$d (${i}s)"; return 0; fi
    sleep 2
  done
  fail "$d (timeout ${t}s)"; return 1
}

ENVFILE=/etc/ironlog/ironlog.env
UNITS_DIR=/etc/containers/systemd
UNITS=(ironlog-clickhouse ironlog-schema ironlog-grafana ironlog-vector-hosts)
CONTAINERS=(ironlog-clickhouse ironlog-grafana ironlog-vector-hosts)
img() { sed -n 's/^Image=//p' "quadlets/$1.container" | head -1; }
CH_IMG="$(img ironlog-clickhouse)"; GF_IMG="$(img ironlog-grafana)"; VEC_IMG="$(img ironlog-vector-hosts)"
for v in CH_IMG GF_IMG VEC_IMG; do [ -n "${!v}" ] || { echo "cannot read Image= from quadlets" >&2; exit 2; }; done

step "preflight"
check "OL9 + SELinux enforcing" bash -c '[ "$(getenforce)" = Enforcing ] && grep -q "release 9" /etc/oracle-release'
check "sudo without password" sudo -n true
command -v podman >/dev/null || { fail "podman missing"; exit 1; }
echo "podman $(podman --version | awk '{print $3}'), $(cat /etc/oracle-release)"

# ---------------------------------------------------------------- step 2
step "2. build images (context = repo root)"
if [ -n "${IRONLOG_E2E_SKIP_BUILD:-}" ]; then
  echo "skipped (IRONLOG_E2E_SKIP_BUILD)"
else
  sudo podman build -q -f images/clickhouse/Dockerfile -t "$CH_IMG"  . >/dev/null 2>&1 && pass "build clickhouse" || fail "build clickhouse"
  sudo podman build -q -f images/grafana/Dockerfile    -t "$GF_IMG"  . >/dev/null 2>&1 && pass "build grafana"    || fail "build grafana"
  sudo podman build -q -f images/vector/Dockerfile     -t "$VEC_IMG" . >/dev/null 2>&1 && pass "build vector"     || fail "build vector"
fi
for i in "$CH_IMG" "$GF_IMG" "$VEC_IMG"; do
  sudo podman image exists "$i" && echo "$(sudo podman image inspect --format '{{.Id}}' "$i" | cut -c1-12)  $(sudo podman image inspect --format '{{.Size}}' "$i" | awk '{printf "%.0f MB", $1/1e6}')  $i" || fail "image missing: $i"
done

# ---------------------------------------------------------------- step 3
step "3. arbitrary UID (--user 1000770000:0, env + fresh named volume only)"
T3="e2e-t3-$$"
cleanup_t3() { sudo podman rm -f "${T3}-ch" "${T3}-gf" "${T3}-vh" "${T3}-va" >/dev/null 2>&1; sudo podman volume rm -f "${T3}-ch" "${T3}-gf" "${T3}-vh" "${T3}-va" >/dev/null 2>&1; }
trap cleanup_t3 EXIT
UID_ARG=1000770000:0
P1=pw$RANDOM$RANDOM; P2=pw$RANDOM$RANDOM; P3=pw$RANDOM$RANDOM; P4=pw$RANDOM$RANDOM
sudo podman run -d --name "${T3}-ch" --user $UID_ARG -v "${T3}-ch:/var/lib/clickhouse" \
  -e CLICKHOUSE_USER=siem_admin -e CLICKHOUSE_PASSWORD=$P1 -e CH_VECTOR_PASSWORD=$P2 \
  -e CH_GRAFANA_ANALYST_PASSWORD=$P3 -e CH_GRAFANA_AUDITOR_PASSWORD=$P4 "$CH_IMG" >/dev/null
wait_for 120 "clickhouse healthy as uid 1000770000 (ironlog-healthcheck)" sudo podman exec "${T3}-ch" /usr/local/bin/ironlog-healthcheck
wait_for 120 "clickhouse schema verified as uid 1000770000" bash -c "sudo podman logs ${T3}-ch 2>&1 | grep -q 'SIEM schema, TTLs and service accounts verified'"
sudo podman run -d --name "${T3}-gf" --user $UID_ARG -v "${T3}-gf:/var/lib/grafana" \
  -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=$P1 \
  -e CH_GRAFANA_ANALYST_PASSWORD=$P3 -e CH_GRAFANA_AUDITOR_PASSWORD=$P4 "$GF_IMG" >/dev/null
wait_for 120 "grafana healthy as uid 1000770000 (GET /api/health)" sudo podman exec "${T3}-gf" wget -q -O /dev/null http://127.0.0.1:3000/api/health
sudo podman run -d --name "${T3}-vh" --user $UID_ARG -v "${T3}-vh:/var/lib/vector" \
  -e IRONLOG_VECTOR_ROLE=hosts -e CH_VECTOR_PASSWORD=$P2 -e SPLUNK_HEC_TOKEN=tok$P1 "$VEC_IMG" >/dev/null
wait_for 60 "vector role hosts healthy as uid 1000770000 (GET /health)" sudo podman exec "${T3}-vh" /usr/local/bin/ironlog-healthcheck
sudo podman run -d --name "${T3}-va" --user $UID_ARG -v "${T3}-va:/var/lib/vector" \
  -e IRONLOG_VECTOR_ROLE=aws -e CH_VECTOR_PASSWORD=$P2 -e AWS_REGION=us-east-1 \
  -e SQS_URL_CLOUDTRAIL=https://sqs.us-east-1.amazonaws.com/1/a -e SQS_URL_GUARDDUTY=https://sqs.us-east-1.amazonaws.com/1/b \
  -e SQS_URL_VPCFLOW=https://sqs.us-east-1.amazonaws.com/1/c -e SQS_URL_S3ACCESS=https://sqs.us-east-1.amazonaws.com/1/d "$VEC_IMG" >/dev/null
wait_for 60 "vector role aws healthy as uid 1000770000" sudo podman exec "${T3}-va" /usr/local/bin/ironlog-healthcheck
cleanup_t3

# ---------------------------------------------------------------- step 4
step "4. install quadlets and start the stack"
sudo install -d -m 0750 /etc/ironlog
if sudo test -f "$ENVFILE"; then
  echo "reusing existing $ENVFILE"
else
  gen() { openssl rand -base64 24 | tr -d '/+=\n'; }
  sudo bash -c "umask 077; cat > $ENVFILE" <<ENV
CH_ADMIN_USER=siem_admin
CH_ADMIN_PASSWORD=$(gen)
CH_VECTOR_PASSWORD=$(gen)
CH_GRAFANA_ANALYST_PASSWORD=$(gen)
CH_GRAFANA_AUDITOR_PASSWORD=$(gen)
GRAFANA_ROOT_URL=http://localhost:3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$(gen)
SPLUNK_HEC_TOKEN=$(gen)
ENV
fi
sudo chmod 600 "$ENVFILE"
check "$ENVFILE is mode 600 root" bash -c "[ \"\$(sudo stat -c '%a %U' $ENVFILE)\" = '600 root' ]"
sudo install -d -m 2770 -o 10001 -g 0 /var/lib/ironlog/clickhouse /var/lib/ironlog/vector-hosts-buffer /var/lib/ironlog/vector-buffer
sudo install -d -m 0750 -o 472 -g 0 /var/lib/ironlog/grafana
sudo cp quadlets/ironlog.network quadlets/*.container "$UNITS_DIR/"
check "quadlet generator dry-run (sudo, no errors)" bash -c 'out=$(sudo /usr/libexec/podman/quadlet -dryrun 2>&1) && ! echo "$out" | grep -qiE "error|warning|unsupported"'
sudo systemctl daemon-reload
sudo systemctl start "${UNITS[@]/%/.service}" || fail "systemctl start"
for u in "${UNITS[@]}"; do check "$u.service active" systemctl is-active --quiet "$u.service"; done
check "ironlog-schema oneshot succeeded (Result=success, exited)" bash -c '[ "$(systemctl show ironlog-schema -p Result --value)" = success ] && [ "$(systemctl show ironlog-schema -p SubState --value)" = exited ]'
check "ironlog-vector.service not enabled/active (ships disabled)" bash -c '! systemctl is-active --quiet ironlog-vector.service'
all_healthy() { local c; for c in "${CONTAINERS[@]}"; do [ "$(sudo podman inspect --format '{{.State.Health.Status}}' "$c")" = healthy ] || return 1; done; }
wait_for 180 "all containers healthy" all_healthy
sudo podman ps --format '  {{.Names}}  {{.Status}}  {{.Ports}}'

# ---------------------------------------------------------------- step 5
step "5. end-to-end: HEC -> ClickHouse -> Grafana"
set -a; . <(sudo cat "$ENVFILE"); set +a
chq() { # chq USER PASSWORD_VAR QUERY ; the password stays in the environment, not argv
  local u="$1" pv="$2"; shift 2
  CLICKHOUSE_PASSWORD="${!pv}" sudo --preserve-env=CLICKHOUSE_PASSWORD podman exec -e CLICKHOUSE_PASSWORD ironlog-clickhouse clickhouse-client --user "$u" --query "$1"
}
MARK="e2e-$(date +%s)-$$"
hec() { curl -s -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: Splunk %s"\n' "$1") \
  -d "{\"event\":{\"cluster\":\"e2e\",\"namespace\":\"ns\",\"node\":\"n1\",\"container\":\"c\",\"pod\":\"p\",\"level\":\"info\",\"message\":\"$MARK $2\"}}" \
  http://127.0.0.1:8088/services/collector/event; }
for n in 1 2 3; do [ "$(hec "$SPLUNK_HEC_TOKEN" $n)" = 200 ] && pass "HEC POST $n -> 200" || fail "HEC POST $n"; done
[ "$(hec wrong-token x)" = 401 ] && pass "HEC bad token -> 401" || fail "HEC bad token not 401"
rows_admin() { [ "$(chq "$CH_ADMIN_USER" CH_ADMIN_PASSWORD "SELECT count() FROM siem.k8s_logs WHERE message LIKE '$MARK %'")" = 3 ]; }
wait_for 90 "3 rows in siem.k8s_logs (admin)" rows_admin
rows_analyst() { [ "$(chq svc_grafana_analyst CH_GRAFANA_ANALYST_PASSWORD "SELECT count() FROM siem.k8s_logs WHERE message LIKE '$MARK %'")" = 3 ]; }
check "svc_grafana_analyst reads the 3 rows" rows_analyst
if chq svc_grafana_analyst CH_GRAFANA_ANALYST_PASSWORD "INSERT INTO siem.k8s_logs (event_time) VALUES (now())" >/dev/null 2>&1; then fail "analyst INSERT succeeded"; else pass "svc_grafana_analyst INSERT denied"; fi
check "svc_grafana_auditor reads audit.query_archive" chq svc_grafana_auditor CH_GRAFANA_AUDITOR_PASSWORD "SELECT count() FROM audit.query_archive"
gf() { curl -s -K <(printf 'user = "%s:%s"\n' "$GRAFANA_ADMIN_USER" "$GRAFANA_ADMIN_PASSWORD") "http://127.0.0.1:3000$1"; }
check "Grafana /api/health database ok" bash -c "curl -s http://127.0.0.1:3000/api/health | grep -q '\"database\": \"ok\"'"
for u in siem-analyst siem-audit; do
  gf "/api/datasources/uid/$u/health" | grep -q '"status":"OK"' && pass "datasource $u health OK (admin login works)" || fail "datasource $u health"
done
dash="$(gf '/api/search?type=dash-db')"
for d in nist-80053-weekly aws-security-overview log-search pipeline-health; do
  echo "$dash" | grep -q "\"uid\":\"$d\"" && pass "dashboard $d provisioned" || fail "dashboard $d missing"
done
vt_env=(-e SPLUNK_HEC_TOKEN=x -e CH_VECTOR_PASSWORD=x -e AWS_REGION=x -e SQS_URL_CLOUDTRAIL=x -e SQS_URL_GUARDDUTY=x -e SQS_URL_VPCFLOW=x -e SQS_URL_S3ACCESS=x)
sudo podman run --rm "${vt_env[@]}" "$VEC_IMG" test /etc/vector/hosts.yaml /etc/vector/tests-hosts.yaml >/tmp/e2e-vt-hosts.$$ 2>&1 && pass "vector test hosts.yaml + tests-hosts.yaml" || { fail "vector test hosts"; tail -5 /tmp/e2e-vt-hosts.$$ >&2; }
sudo podman run --rm "${vt_env[@]}" "$VEC_IMG" test /etc/vector/vector.yaml /etc/vector/tests.yaml >/tmp/e2e-vt-aws.$$ 2>&1 && pass "vector test vector.yaml + tests.yaml" || { fail "vector test aws"; tail -5 /tmp/e2e-vt-aws.$$ >&2; }
rm -f /tmp/e2e-vt-*.$$

# ---------------------------------------------------------------- step 6
step "6. security properties"
BIND="${IRONLOG_CLICKHOUSE_BIND:-127.0.0.1}"
# Rootful podman publishes through netfilter DNAT, so there is no listening
# socket for ss to show; ask podman which host address it bound.
bound() { sudo podman port "$1" "$2/tcp" | sort -u | tr '
' ' ' | sed 's/ $//'; }
for p in 8123 9000; do
  [ "$(bound ironlog-clickhouse $p)" = "$BIND:$p" ] && pass "ClickHouse :$p published on $BIND only" || fail "ClickHouse :$p bound to '$(bound ironlog-clickhouse $p)', expected $BIND:$p"
done
[ "$(bound ironlog-grafana 3000)" = "0.0.0.0:3000" ] && pass "Grafana :3000 published on all interfaces (documented)" || fail "Grafana :3000 bound to '$(bound ironlog-grafana 3000)'"
for p in 8088 6000; do
  [ "$(bound ironlog-vector-hosts $p)" = "0.0.0.0:$p" ] && pass "Vector :$p published on all interfaces (documented)" || fail "Vector :$p bound to '$(bound ironlog-vector-hosts $p)'"
done
for c in "${CONTAINERS[@]}"; do
  u="$(sudo podman exec "$c" id -u)"
  [ "$u" != 0 ] && pass "$c runs as uid $u (not root)" || fail "$c runs as root"
  nonroot="$(sudo podman top "$c" user | tail -n +2 | grep -cvE '^(root|0)\b')"
  total="$(sudo podman top "$c" user | tail -n +2 | wc -l)"
  [ "$nonroot" = "$total" ] && pass "$c: all $total processes non-root" || fail "$c has root processes"
done
check "no --privileged / added caps" bash -c 'for c in ironlog-clickhouse ironlog-grafana ironlog-vector-hosts; do [ "$(sudo podman inspect --format "{{.HostConfig.Privileged}} {{len .HostConfig.CapAdd}}" $c)" = "false 0" ] || exit 1; done'
check "SELinux still enforcing" bash -c '[ "$(getenforce)" = Enforcing ]'
# --input-logs: without it ausearch reads a piped stdin (ssh) and hangs.
check "auditd running (AVC search is meaningful)" systemctl is-active --quiet auditd
avc="$(sudo timeout 60 ausearch --input-logs -m avc,user_avc,selinux_err -ts "$START_TIME" </dev/null 2>&1)"
if echo "$avc" | grep -q '<no matches>'; then pass "no AVC denials since $START_TIME"; else fail "AVC denials since $START_TIME"; echo "$avc" | tail -20 >&2; fi

# ---------------------------------------------------------------- step 7
step "7. durability without reboot: restart each unit once"
count_rows() { chq "$CH_ADMIN_USER" CH_ADMIN_PASSWORD "SELECT count() FROM siem.k8s_logs WHERE message LIKE '$MARK %'"; }
tables_before="$(chq "$CH_ADMIN_USER" CH_ADMIN_PASSWORD "SELECT count() FROM system.tables WHERE database IN ('siem','audit')")"
RESTART_FROM="$(date '+%Y-%m-%d %H:%M:%S')"
for u in ironlog-clickhouse ironlog-schema ironlog-grafana ironlog-vector-hosts; do
  sudo systemctl restart "$u.service" && pass "systemctl restart $u" || fail "restart $u"
  wait_for 180 "$u active again" systemctl is-active --quiet "$u.service"
  wait_for 180 "all containers healthy after restarting $u" all_healthy
done
check "ironlog-schema re-ran: verified line after restart" bash -c "sudo journalctl -u ironlog-schema --since '$RESTART_FROM' --no-pager | grep -q 'SIEM schema, TTLs and service accounts verified'"
[ "$(count_rows)" = 3 ] && pass "earlier 3 rows still present, no duplicates" || fail "row count after restarts is $(count_rows), expected 3"
[ "$(chq "$CH_ADMIN_USER" CH_ADMIN_PASSWORD "SELECT count() FROM system.tables WHERE database IN ('siem','audit')")" = "$tables_before" ] && pass "table count unchanged ($tables_before)" || fail "table count changed"
[ "$(chq "$CH_ADMIN_USER" CH_ADMIN_PASSWORD "SELECT count() FROM system.users WHERE name LIKE 'svc_%'")" = 3 ] && pass "exactly 3 service accounts" || fail "service account count"
[ "$(hec "$SPLUNK_HEC_TOKEN" 4)" = 200 ] && pass "HEC still accepts events after restarts" || fail "HEC after restarts"
rows4() { [ "$(count_rows)" = 4 ]; }
wait_for 90 "post-restart event landed (4 rows)" rows4

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: ALL PASSED"; else echo "RESULT: $FAILS FAILED" >&2; fi
echo "Stack left running. Reboot test is manual: sudo reboot; then re-run with IRONLOG_E2E_SKIP_BUILD=1 or follow quadlets/README.md."
exit $(( FAILS > 0 ))
