#!/bin/bash
# ironlog split mode, ClickHouse host: own nftables table that drops traffic to the
# published ClickHouse ports (8123, 9000) from every source not listed in
# IRONLOG_CLICKHOUSE_ALLOWED_HOSTS. Run by ironlog-firewall.service, which loads
# /etc/ironlog/ironlog.env (systemd EnvironmentFile semantics) into the environment.
#   ironlog-firewall.sh start | stop | print | watch
#   print = ruleset on stdout, no nft call
#   watch = re-create netavark's rules after every firewalld reload (see below)
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
for p in "$here/ironlog-allowed-hosts.sh" "$here/../../images/clickhouse/allowed-hosts.sh"; do
  [ -r "$p" ] && { . "$p"; found=1; break; }
done
[ -n "${found:-}" ] || { echo "ironlog-firewall: allowed-hosts parser not found next to $0" >&2; exit 1; }

ruleset() {
  local e v4=() v6=()
  for e in "${ALLOWED_HOSTS[@]}"; do
    if [[ "$e" == *:* ]]; then v6+=("$e"); else v4+=("$e"); fi
  done
  local IFS=,
  cat <<NFT
table inet ironlog
delete table inet ironlog
table inet ironlog {
  set clickhouse_src4 { type ipv4_addr; flags interval; ${v4[*]:+elements = { ${v4[*]} \}}
  }
  set clickhouse_src6 { type ipv6_addr; flags interval; ${v6[*]:+elements = { ${v6[*]} \}}
  }
  # priority -300 = before the raw table and before netavark's DNAT (dstnat, -100)
  chain prerouting {
    type filter hook prerouting priority -300; policy accept;
    iif "lo" accept
    iifname "podman*" accept
    fib daddr type != local accept
    tcp dport { 8123, 9000 } ip saddr @clickhouse_src4 accept
    tcp dport { 8123, 9000 } ip6 saddr @clickhouse_src6 accept
    tcp dport { 8123, 9000 } counter drop
  }
}
NFT
}

case "${1:-}" in
  watch)
    # `firewall-cmd --reload` flushes the iptables-nft tables (ip nat, ip filter)
    # that netavark fills with podman's DNAT and forward rules, so published ports
    # go dead until `podman network reload --all`. table inet ironlog survives the
    # reload; this loop runs the podman command on every firewalld Reloaded signal.
    busctl --system monitor --match       "type=signal,sender=org.fedoraproject.FirewallD1,member=Reloaded" |
    while read -r line; do
      [[ "$line" == *"Member=Reloaded"* ]] || continue
      echo "ironlog-firewall: firewalld reloaded; running podman network reload --all"
      # netavark prints 'iptables: No chain/target/match by that name' here although
      # the rules are restored; tolerate the exit status, not the result.
      podman network reload --all >/dev/null 2>&1 || true
    done
    exit 0 ;;
  stop)
    nft list table inet ironlog >/dev/null 2>&1 && nft delete table inet ironlog
    exit 0 ;;
  start|print) ;;
  *) echo "usage: $0 start|stop|print" >&2; exit 2 ;;
esac

parse_allowed_hosts || { echo "ironlog-firewall: IRONLOG_CLICKHOUSE_ALLOWED_HOSTS: $ALLOWED_ERR" >&2; exit 1; }
if [ "${#ALLOWED_HOSTS[@]}" -eq 0 ]; then
  echo "ironlog-firewall: IRONLOG_CLICKHOUSE_ALLOWED_HOSTS is empty in /etc/ironlog/ironlog.env; refusing to start (this unit is only for split mode, where it lists the Grafana/Vector hosts)" >&2
  exit 1
fi

if [ "$1" = print ]; then ruleset; else ruleset | nft -f -; fi
