#!/bin/bash
# Sourced by ironlog-entrypoint and ironlog-schema. Strict parser for
# IRONLOG_CLICKHOUSE_ALLOWED_HOSTS: comma-separated IPv4/IPv6 addresses or CIDRs.
# parse_allowed_hosts fills ALLOWED_HOSTS (empty array = no restriction) and
# returns 1 with the reason in ALLOWED_ERR on the first invalid entry. Only
# [0-9a-fA-F:./] can survive validation, so entries are safe inside SQL and XML.

_ah_ipv4() { # dotted quad, each octet 0-255, no leading zeros
  local o
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$o" -le 255 ] || return 1
  done
}

_ah_ipv6() { # hex groups, at most one '::', optional trailing dotted quad
  local a=$1 g n=0
  [[ "$a" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  [[ "$a" == *:::* ]] && return 1
  local dc=${a//[^:]/}
  [[ "$a" == *::*::* ]] && return 1
  case "$a" in :[!:]*|*[!:]:) return 1 ;; esac
  [ "${#dc}" -ge 2 ] || return 1
  local -a groups
  IFS=: read -r -a groups <<<"${a//::/:}"
  for g in "${groups[@]}"; do
    [ -z "$g" ] && continue
    if [[ "$g" == *.* ]]; then
      [ "$g" = "${groups[-1]}" ] && _ah_ipv4 "$g" || return 1
      n=$((n + 2))
    else
      [[ "$g" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
      n=$((n + 1))
    fi
  done
  if [[ "$a" == *::* ]]; then [ "$n" -le 7 ] || return 1; else [ "$n" -eq 8 ] || return 1; fi
}

parse_allowed_hosts() {
  ALLOWED_HOSTS=(); ALLOWED_ERR=""
  local raw="${IRONLOG_CLICKHOUSE_ALLOWED_HOSTS:-}" e addr len max
  raw="${raw//[[:space:]]/}"
  [ -z "$raw" ] && return 0
  local -a entries
  IFS=, read -r -a entries <<<"${raw},"
  for e in "${entries[@]}"; do
    addr=${e%%/*}; len=""
    [[ "$e" == */* ]] && len=${e#*/}
    if [ -z "$e" ] || [ "$e" != "${e//[^0-9a-fA-F:.\/]/}" ] || [[ "$len" == */* ]]; then
      ALLOWED_ERR="invalid entry '${e:0:64}' (want IPv4/IPv6 address or CIDR)"; return 1
    fi
    if _ah_ipv4 "$addr"; then max=32
    elif _ah_ipv6 "$addr"; then max=128
    else ALLOWED_ERR="invalid entry '${e:0:64}' (want IPv4/IPv6 address or CIDR)"; return 1; fi
    if [[ "$e" == */* ]]; then
      [[ "$len" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$len" -le "$max" ] \
        || { ALLOWED_ERR="invalid prefix length in '${e:0:64}'"; return 1; }
    fi
    ALLOWED_HOSTS+=("$e")
  done
}
