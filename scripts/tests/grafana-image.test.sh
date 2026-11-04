#!/usr/bin/env bash
# Builds images/grafana/Dockerfile (linux/amd64) and checks the contract in
# images/README.md. No ClickHouse is needed: datasources are only provisioned.
# Runtime: DOCKER=docker (default). On a Windows host: run this script inside WSL.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
docker_bin=${DOCKER:-docker}
image=ironlog-grafana:test
pg_image=postgres:16.4-alpine
pin=$(tr -d '[:space:]' < "$root/scripts/ami/grafana-clickhouse-plugin.version")
tag=igt$$
admin_user=admin
admin_pass=test-admin-pass
export_env=(-e GF_SECURITY_ADMIN_USER=$admin_user -e GF_SECURITY_ADMIN_PASSWORD=$admin_pass
  -e CH_GRAFANA_ANALYST_PASSWORD=analyst-pw -e CH_GRAFANA_AUDITOR_PASSWORD=auditor-pw)

containers=() volumes=() networks=()
cleanup() {
  for c in "${containers[@]:-}"; do [ -n "$c" ] && "$docker_bin" rm -f "$c" >/dev/null 2>&1 || true; done
  for v in "${volumes[@]:-}"; do [ -n "$v" ] && "$docker_bin" volume rm -f "$v" >/dev/null 2>&1 || true; done
  for n in "${networks[@]:-}"; do [ -n "$n" ] && "$docker_bin" network rm "$n" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

ip_of() { "$docker_bin" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

wait_healthy() { # container
  local c=$1 ip i
  ip=$(ip_of "$c")
  for i in $(seq 1 60); do
    if curl -fsS -m 10 "http://$ip:3000/api/health" 2>/dev/null | grep -q '"database": *"ok"'; then return 0; fi
    [ "$("$docker_bin" inspect -f '{{.State.Running}}' "$c")" = true ] || { "$docker_bin" logs "$c" 2>&1 | tail -30 >&2; fail "$c exited"; }
    sleep 2
  done
  "$docker_bin" logs "$c" 2>&1 | tail -30 >&2
  fail "$c not healthy in 120s"
}

api() { # container path
  curl -fsS -m 10 -u "$admin_user:$admin_pass" "http://$(ip_of "$1"):3000$2"
}

start() { # name args...
  local name=$tag-$1; shift
  containers+=("$name")
  "$docker_bin" run -d --name "$name" "${export_env[@]}" "$@" "$image" >/dev/null
  echo "$name"
}

check_provisioned() { # container expected_host
  local c=$1 host=$2 list
  list=$(api "$c" /api/datasources)
  for uid in siem-analyst siem-audit; do
    echo "$list" | grep -q "\"uid\": *\"$uid\"" || fail "$c: datasource $uid not provisioned"
    api "$c" "/api/datasources/uid/$uid" | tr -d ' \n' | grep -q "\"host\":\"$host\"" \
      || fail "$c: datasource $uid host != $host"
  done
}

check_plugin() { # container
  local ver
  ver=$(api "$1" /api/plugins/grafana-clickhouse-datasource/settings | tr -d ' \n' | sed -nE 's/.*"info":\{.*"version":"([^"]+)".*/\1/p')
  [ "$ver" = "$pin" ] || fail "$1: plugin version '$ver' != pin '$pin'"
  api "$1" /api/health >/dev/null
}

check_logs_clean() { # container
  if "$docker_bin" logs "$1" 2>&1 | grep -Ei 'plugin.*(install|download)|preinstall|read-only file system|failed to (install|download)' | grep -vi 'preinstall.*disabled'; then
    fail "$1: plugin install attempt or error in logs"
  fi
}

echo "== build (linux/amd64)"
"$docker_bin" build --platform linux/amd64 -f "$root/images/grafana/Dockerfile" -t "$image" "$root"

echo "== (a) default"
c=$(start a)
wait_healthy "$c"
check_provisioned "$c" clickhouse
check_plugin "$c"
check_logs_clean "$c"
api "$c" /api/health | grep -q '"database": *"ok"' || fail "health"
"$docker_bin" exec "$c" sh -c 'test "$GF_PATHS_PLUGINS" = /usr/share/ironlog/grafana-plugins && test ! -e /var/lib/grafana/plugins/grafana-clickhouse-datasource' \
  || fail "plugin not baked outside /var/lib/grafana"
[ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://$(ip_of "$c"):3000/api/datasources")" = 401 ] || fail "anonymous access not rejected"
"$docker_bin" exec "$c" sh -c 'p=$(grep -h "port:" /etc/grafana/provisioning/datasources/clickhouse.yml | sort -u); echo "$p"' | grep -q 'IRONLOG_CLICKHOUSE_NATIVE_PORT' || fail "port not templated"
api "$c" /api/datasources/uid/siem-analyst | tr -d ' \n' | grep -q '"port":9000' || fail "default port != 9000"
pass "(a) default: health ok, 2 datasources (host clickhouse, port 9000), plugin $pin, no install attempts, anon rejected"
"$docker_bin" rm -f "$c" >/dev/null

echo "== (b) --user 1000770000:0 on empty then reused volume"
vol=$tag-data; volumes+=("$vol"); "$docker_bin" volume create "$vol" >/dev/null
b1=$(start b1 --user 1000770000:0 -v "$vol:/var/lib/grafana")
wait_healthy "$b1"; check_provisioned "$b1" clickhouse; check_plugin "$b1"; check_logs_clean "$b1"
"$docker_bin" exec "$b1" id | grep -q 'uid=1000770000' || fail "not running as arbitrary uid"
"$docker_bin" exec "$b1" test -f /var/lib/grafana/grafana.db || fail "grafana.db not on volume"
"$docker_bin" rm -f "$b1" >/dev/null
# reused volume, same UID (Grafana writes files 0640: a different UID cannot reuse them)
for uid in 1000770000; do
  b2=$(start "b2-$uid" --user "$uid:0" -v "$vol:/var/lib/grafana")
  wait_healthy "$b2"; check_provisioned "$b2" clickhouse; check_plugin "$b2"; check_logs_clean "$b2"
  "$docker_bin" rm -f "$b2" >/dev/null
done
pass "(b) uid 1000770000:0 healthy on empty volume, reused volume (same uid)"

echo "== (c) IRONLOG_CLICKHOUSE_HOST/PORT override"
c=$(start c -e IRONLOG_CLICKHOUSE_HOST=somehost -e IRONLOG_CLICKHOUSE_NATIVE_PORT=9440)
wait_healthy "$c"; check_provisioned "$c" somehost
api "$c" /api/datasources/uid/siem-audit | tr -d ' \n' | grep -q '"port":9440' || fail "port override not reflected"
pass "(c) host=somehost port=9440 reflected in both datasources"
"$docker_bin" rm -f "$c" >/dev/null

echo "== (d) shared postgres database, two Grafana containers"
net=$tag-net; networks+=("$net"); "$docker_bin" network create "$net" >/dev/null
pg=$tag-pg; containers+=("$pg")
"$docker_bin" run -d --name "$pg" --network "$net" -e POSTGRES_PASSWORD=pgpw -e POSTGRES_USER=grafana -e POSTGRES_DB=grafana "$pg_image" >/dev/null
for i in $(seq 1 30); do "$docker_bin" exec "$pg" pg_isready -U grafana -d grafana >/dev/null 2>&1 && break; sleep 1; done
"$docker_bin" exec "$pg" pg_isready -U grafana -d grafana >/dev/null || fail "postgres not ready"
dbenv=(--network "$net" -e GF_DATABASE_TYPE=postgres -e GF_DATABASE_HOST=$pg:5432 -e GF_DATABASE_NAME=grafana
  -e GF_DATABASE_USER=grafana -e GF_DATABASE_PASSWORD=pgpw -e GF_DATABASE_SSL_MODE=disable)
d1=$(start d1 "${dbenv[@]}")
wait_healthy "$d1"
d2=$(start d2 "${dbenv[@]}")
wait_healthy "$d2"
for d in "$d1" "$d2"; do check_provisioned "$d" clickhouse; check_plugin "$d"; check_logs_clean "$d"
  "$docker_bin" exec "$d" test ! -e /var/lib/grafana/grafana.db || fail "$d used sqlite"; done
# shared state: create a folder via d1, read it via d2
curl -fsS -m 10 -u "$admin_user:$admin_pass" -H 'Content-Type: application/json' -d '{"title":"shared-check"}' "http://$(ip_of "$d1"):3000/api/folders" >/dev/null
api "$d2" /api/folders | grep -q shared-check || fail "d2 does not see d1's folder: database not shared"
"$docker_bin" exec "$pg" psql -U grafana -d grafana -tAc 'select count(*) from dashboard' | grep -Eq '^[0-9]+$' || fail "no grafana tables in postgres"
pass "(d) two Grafana containers healthy on one postgres ($pg_image), state shared, no sqlite file"

echo "ALL PASS"
