#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bash_bin=$(command -v bash)
mkdir -p "$root/.decurion"
tmpdir=$(mktemp -d "$root/.decurion/runtime-bootstrap-test.XXXXXX")

cleanup() {
  local resolved
  resolved=$(cd "$tmpdir" && pwd -P)
  case "$resolved" in
    "$root"/.decurion/runtime-bootstrap-test.*) rm -rf -- "$resolved" ;;
    *) echo 'refusing cleanup outside test workspace' >&2 ;;
  esac
}
trap cleanup EXIT

mockbin="$tmpdir/bin"
mkdir -p "$mockbin"
for runtime in podman docker; do
  cat > "$mockbin/$runtime" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "$MOCK_RUNTIME_LOG"
printf ' <%s>' "$@" >> "$MOCK_RUNTIME_LOG"
printf '\n' >> "$MOCK_RUNTIME_LOG"
if [[ ${1:-} == compose && ${2:-} == version ]]; then
  exit 0
fi
if [[ "$*" == *svc_grafana_analyst* && "$*" == *audit.query_archive* ]]; then
  exit 1
fi
exit 0
SH
  chmod +x "$mockbin/$runtime"
done

assert_contains() {
  local needle=$1 file=$2
  grep -F -- "$needle" "$file" >/dev/null || {
    echo "missing expected text: $needle" >&2
    exit 1
  }
}

run_bootstrap() {
  local runtime=$1 workdir="$2" log="$3"
  mkdir -p "$workdir"
  ln -s "$root/bootstrap.sh" "$workdir/bootstrap.sh"
  ln -s "$root/scripts" "$workdir/scripts"
  if ! (
    cd "$workdir"
    if [[ -n "$runtime" ]]; then
      PATH="$mockbin:$PATH" MOCK_RUNTIME_LOG="$log" \
        IRONLOG_CONTAINER_RUNTIME="$runtime" bash ./bootstrap.sh runtime-test@ironlog.local
    else
      PATH="$mockbin:$PATH" MOCK_RUNTIME_LOG="$log" \
        env -u IRONLOG_CONTAINER_RUNTIME bash ./bootstrap.sh runtime-test@ironlog.local
    fi
  ) >"$workdir/bootstrap.out" 2>&1; then
    cat "$workdir/bootstrap.out" >&2
    exit 1
  fi
}

podman_work="$tmpdir/podman"
podman_log="$tmpdir/podman.log"
run_bootstrap '' "$podman_work" "$podman_log"
assert_contains 'IRONLOG_CONTAINER_RUNTIME=podman' "$podman_work/.env"
assert_contains 'podman <compose> <up> <-d>' "$podman_log"
assert_contains 'podman <exec> <-i> <siem-hyperdx> <node> <->' "$podman_log"
assert_contains 'podman <exec> <siem-clickhouse>' "$podman_log"

docker_work="$tmpdir/docker"
docker_log="$tmpdir/docker.log"
run_bootstrap docker "$docker_work" "$docker_log"
assert_contains 'IRONLOG_CONTAINER_RUNTIME=docker' "$docker_work/.env"
assert_contains 'docker <compose> <up> <-d>' "$docker_log"
assert_contains 'docker <exec> <-i> <siem-hyperdx> <node> <->' "$docker_log"

compose_work="$tmpdir/compose"
mkdir -p "$compose_work"
printf 'IRONLOG_CONTAINER_RUNTIME=podman\n' > "$compose_work/.env"
compose_log="$tmpdir/compose.log"
(
  cd "$compose_work"
  PATH="$mockbin:$PATH" MOCK_RUNTIME_LOG="$compose_log" "$root/scripts/compose.sh" ps --format json
) >/dev/null
assert_contains 'podman <compose> <ps> <--format> <json>' "$compose_log"
(
  cd "$compose_work"
  PATH="$mockbin:$PATH" MOCK_RUNTIME_LOG="$compose_log" IRONLOG_CONTAINER_RUNTIME=docker \
    "$root/scripts/compose.sh" config --quiet
) >/dev/null
assert_contains 'docker <compose> <config> <--quiet>' "$compose_log"

missing_work="$tmpdir/missing"
mkdir -p "$missing_work"
ln -s "$root/bootstrap.sh" "$missing_work/bootstrap.sh"
ln -s "$root/scripts" "$missing_work/scripts"
if (
  cd "$missing_work"
  PATH="$tmpdir/empty" IRONLOG_CONTAINER_RUNTIME=podman "$bash_bin" ./bootstrap.sh
) >/dev/null 2>&1; then
  echo 'bootstrap unexpectedly succeeded without Podman' >&2
  exit 1
fi
[[ ! -e "$missing_work/.env" ]] || {
  echo 'bootstrap wrote .env before runtime preflight' >&2
  exit 1
}

echo 'runtime bootstrap tests: PASS'
