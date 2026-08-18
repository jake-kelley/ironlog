#!/usr/bin/env bash
# secret-resolver.sh — resolves a single config value URI to a plaintext value.
#
# Supported schemes:
#   ssm://<parameter-path>        AWS SSM Parameter Store, WithDecryption=true
#   asm://<secret-id>[#json-key]  AWS Secrets Manager (whole secret, or one key
#                                 of a JSON-object secret)
#   file:///absolute/path         Read a file from local disk verbatim (for
#                                 air-gapped enclaves / operator-injected material)
#   generate:<bytes>              Generate <bytes> bytes of strong randomness
#                                 on first use and PERSIST it under
#                                 /etc/ironlog/generated/<VARNAME>.secret so it
#                                 survives reboots. Requires a variable name
#                                 (second arg) for the persistence key.
#   <anything else>               Used as a literal value, as-is. Covers plain
#                                 config (hostnames, usernames, URLs — including
#                                 values containing "://" that are not one of
#                                 the exact scheme prefixes above).
#
# Scheme matching is by exact, fixed prefix ("ssm://", "asm://", "file://",
# "generate:") — not a generic "word://" regex — specifically so that a
# literal value like "http://keycloak:8080" (KC_HOSTNAME's normal shape) is
# never misparsed as a scheme.
#
# This file is meant to be `source`d by ironlog-firstboot.sh, but is also
# directly executable for standalone testing:
#   ./secret-resolver.sh resolve 'ssm:///ironlog/ch_admin_password'
#   ./secret-resolver.sh resolve 'asm://ironlog/keycloak#admin_password'
#   ./secret-resolver.sh resolve 'generate:32' OAUTH2_PROXY_COOKIE_SECRET
#
# All AWS calls use `aws --region <region>`; region comes from (in order)
# SECRET_RESOLVER_AWS_REGION env var, then IMDSv2 placement/region, then
# falls back to us-east-1. IMDS access uses IMDSv2 (token-required) only —
# no IMDSv1 fallback, per STIG.

set -uo pipefail

IMDS_BASE="http://169.254.169.254/latest"
IMDS_TOKEN_TTL=21600
GENERATED_DIR="${IRONLOG_GENERATED_DIR:-/etc/ironlog/generated}"
_IMDS_TOKEN_CACHE=""

sr_log() {
	echo "[secret-resolver] $*" >&2
}

# ---- IMDSv2 --------------------------------------------------------------

sr_imds_token() {
	if [[ -n "$_IMDS_TOKEN_CACHE" ]]; then
		printf '%s' "$_IMDS_TOKEN_CACHE"
		return 0
	fi
	local tok
	tok="$(curl -s -f -m 5 -X PUT "$IMDS_BASE/api/token" \
		-H "X-aws-ec2-metadata-token-ttl-seconds: $IMDS_TOKEN_TTL")" || return 1
	[[ -n "$tok" ]] || return 1
	_IMDS_TOKEN_CACHE="$tok"
	printf '%s' "$tok"
}

# sr_imds_get <path-under-/latest/>
sr_imds_get() {
	local path="$1" tok
	tok="$(sr_imds_token)" || return 1
	curl -s -f -m 5 -H "X-aws-ec2-metadata-token: $tok" "$IMDS_BASE/$path"
}

# Fetches raw EC2 user-data (may be empty/absent — that's not an error here).
sr_fetch_userdata() {
	local tok
	tok="$(sr_imds_token)" || { sr_log "IMDSv2 token unavailable; no user-data (not running on EC2, or IMDS blocked)"; return 1; }
	curl -s -f -m 5 -H "X-aws-ec2-metadata-token: $tok" "$IMDS_BASE/user-data" 2>/dev/null
}

sr_region() {
	if [[ -n "${SECRET_RESOLVER_AWS_REGION:-}" ]]; then
		printf '%s' "$SECRET_RESOLVER_AWS_REGION"
		return 0
	fi
	local region
	region="$(sr_imds_get 'dynamic/instance-identity/document' 2>/dev/null | \
		{ command -v python3 >/dev/null 2>&1 && python3 -c 'import json,sys; print(json.load(sys.stdin).get("region",""))' 2>/dev/null || true; })"
	if [[ -z "$region" ]]; then
		region="$(sr_imds_get 'meta-data/placement/region' 2>/dev/null)"
	fi
	if [[ -z "$region" ]]; then
		sr_log "could not determine AWS region from IMDS; defaulting to us-east-1"
		region="us-east-1"
	fi
	printf '%s' "$region"
}

# ---- scheme resolvers -----------------------------------------------------

sr_resolve_ssm() {
	local param="$1" region
	command -v aws >/dev/null 2>&1 || { sr_log "aws CLI not found; cannot resolve ssm:// URIs"; return 1; }
	region="$(sr_region)"
	aws --region "$region" ssm get-parameter \
		--name "$param" --with-decryption \
		--query 'Parameter.Value' --output text
}

sr_resolve_asm() {
	local ref="$1" secret_id json_key region raw
	secret_id="${ref%%#*}"
	if [[ "$ref" == *"#"* ]]; then
		json_key="${ref#*#}"
	else
		json_key=""
	fi
	command -v aws >/dev/null 2>&1 || { sr_log "aws CLI not found; cannot resolve asm:// URIs"; return 1; }
	region="$(sr_region)"
	raw="$(aws --region "$region" secretsmanager get-secret-value \
		--secret-id "$secret_id" --query 'SecretString' --output text)" || return 1
	if [[ -z "$json_key" ]]; then
		printf '%s' "$raw"
		return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		printf '%s' "$raw" | python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]], end='')" "$json_key"
	elif command -v jq >/dev/null 2>&1; then
		printf '%s' "$raw" | jq -j --arg k "$json_key" '.[$k]'
	else
		sr_log "neither python3 nor jq available; cannot extract JSON key '$json_key' from asm:// secret"
		return 1
	fi
}

sr_resolve_file() {
	local uri="$1" path
	# strip the file:// prefix; keep the leading / of the absolute path
	path="${uri#file://}"
	[[ -n "$path" ]] || { sr_log "file:// URI has no path"; return 1; }
	[[ -r "$path" ]] || { sr_log "file '$path' does not exist or is not readable"; return 1; }
	# Strip a single trailing newline, matching how ssm/asm return values.
	printf '%s' "$(cat "$path")"
}

# sr_resolve_generate <bytes> <varname>
# Persisted at $GENERATED_DIR/<varname>.secret so a reboot (or a re-run of
# firstboot after the sentinel is cleared) does NOT regenerate it — critical
# for OAUTH2_PROXY_COOKIE_SECRET: a changed cookie secret invalidates every
# live session.
sr_resolve_generate() {
	local bytes="$1" varname="$2" out
	[[ "$bytes" =~ ^[0-9]+$ ]] || { sr_log "generate: scheme needs a numeric byte count, got '$bytes'"; return 1; }
	[[ -n "$varname" ]] || { sr_log "generate: scheme needs a variable name for persistence"; return 1; }
	out="$GENERATED_DIR/${varname}.secret"
	if [[ -s "$out" ]]; then
		cat "$out"
		return 0
	fi
	mkdir -p "$GENERATED_DIR"
	chmod 700 "$GENERATED_DIR"
	# openssl rand -hex N emits 2*N hex characters == N bytes when read back
	# as a raw ASCII string later (this is exactly what .env.example's own
	# guidance for OAUTH2_PROXY_COOKIE_SECRET assumes: "openssl rand -hex 16"
	# for a 32-byte secret). Halve the requested byte count accordingly.
	local half=$((bytes / 2))
	if [[ $((half * 2)) -ne $bytes ]]; then
		sr_log "generate:$bytes requests an odd byte count; openssl rand -hex needs an even split — rounding up"
		half=$(((bytes + 1) / 2))
	fi
	local val
	val="$(openssl rand -hex "$half")" || return 1
	printf '%s' "$val" > "$out"
	chmod 600 "$out"
	printf '%s' "$val"
}

# ---- dispatcher -------------------------------------------------------

# sr_resolve <uri> [varname]
# varname is only required for the generate: scheme (persistence key).
sr_resolve() {
	local uri="$1" varname="${2:-}"
	case "$uri" in
		ssm://*)
			sr_resolve_ssm "${uri#ssm://}"
			;;
		asm://*)
			sr_resolve_asm "${uri#asm://}"
			;;
		file://*)
			sr_resolve_file "$uri"
			;;
		generate:*)
			sr_resolve_generate "${uri#generate:}" "$varname"
			;;
		*)
			# literal — used as-is, including values that contain "://" but
			# don't match one of the exact scheme prefixes above (e.g. plain
			# http(s) URLs used for KC_HOSTNAME / KC_PUBLIC_URL / GRAFANA_ROOT_URL).
			printf '%s' "$uri"
			;;
	esac
}

# Allow standalone CLI use for testing: ./secret-resolver.sh resolve <uri> [varname]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	case "${1:-}" in
		resolve)
			sr_resolve "${2:?usage: secret-resolver.sh resolve <uri> [varname]}" "${3:-}"
			echo
			;;
		region)
			sr_region
			echo
			;;
		*)
			echo "usage: $0 resolve <uri> [varname]  |  $0 region" >&2
			exit 2
			;;
	esac
fi
