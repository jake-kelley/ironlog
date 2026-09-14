#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$root/scripts/bootstrap-hyperdx-local.sh"
mkdir -p "$root/.decurion"
tmpdir=$(mktemp -d "$root/.decurion/auth-test.XXXXXX")
server_pid=''
node_bin=$(command -v node || command -v node.exe || true)

[[ -n "$node_bin" ]] || {
  echo 'node is required to run bootstrap-hyperdx-local tests' >&2
  exit 69
}

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  # Resolve and constrain the temporary directory before recursive cleanup.
  local resolved
  resolved=$(cd "$tmpdir" && pwd -P)
  case "$resolved" in
    "$root"/.decurion/auth-test.*) rm -rf -- "$resolved" ;;
    *) echo 'refusing cleanup outside test workspace' >&2 ;;
  esac
}
trap cleanup EXIT

api_port=$((20000 + RANDOM % 10000))
app_port=$((api_port + 1))
export HYPERDX_TEST_STATE="$tmpdir/state"
export HYPERDX_TEST_APP_PORT="$app_port"
export HYPERDX_TEST_API_PORT="$api_port"
export HYPERDX_TEST_NODE="$node_bin"

"$node_bin" - <<'NODE' &
const http = require('http');
const fs = require('fs');
const state = process.env.HYPERDX_TEST_STATE;
const appPort = Number(process.env.HYPERDX_TEST_APP_PORT);
const apiPort = Number(process.env.HYPERDX_TEST_API_PORT);
let healthRequests = 0;

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  res.end(JSON.stringify(body));
}

const api = http.createServer((req, res) => {
  if (req.url === '/health') return send(res, 200, { data: 'OK' });
  send(res, 404, {});
});
const app = http.createServer((req, res) => {
  if (req.url === '/api/health') {
    healthRequests += 1;
    return send(res, healthRequests < 3 ? 503 : 200, { data: 'OK' });
  }
  const authenticated = (req.headers.cookie || '').includes('sid=ok');
  if (fs.existsSync(state) && fs.readFileSync(state, 'utf8') === 'bypass') {
    return send(res, 200, []);
  }
  if (req.url === '/api/sources' && req.method === 'GET') {
    return authenticated ? send(res, 200, [{ name: 'SIEM' }]) : send(res, 401, {});
  }
  if (req.url === '/api/connections' && req.method === 'GET') {
    return authenticated ? send(res, 200, [{ name: 'SIEM ClickHouse' }]) : send(res, 401, {});
  }
  if (req.url === '/api/clickhouse-proxy' && req.method === 'POST') {
    return authenticated ? send(res, 400, {}) : send(res, 401, {});
  }
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const data = JSON.parse(body || '{}');
    if (req.url === '/api/register/password') {
      if (fs.existsSync(state)) return send(res, 409, { error: 'teamAlreadyExists' });
      if (data.email !== 'admin@ironlog.local' || data.password !== 'IronlogDev123!' || data.confirmPassword !== data.password) return send(res, 400, {});
      fs.writeFileSync(state, 'registered');
      return send(res, 200, { status: 'success' }, { 'Set-Cookie': 'sid=ok; Path=/' });
    }
    if (req.url === '/api/login/password') {
      if (!fs.existsSync(state) || data.email !== 'admin@ironlog.local' || data.password !== 'IronlogDev123!') return send(res, 302, {}, { Location: '/login?err=authFail' });
      if (fs.readFileSync(state, 'utf8') === 'https' && req.headers['x-forwarded-proto'] !== 'https') return send(res, 302, {}, { Location: '/search' });
      return send(res, 302, {}, { Location: '/search', 'Set-Cookie': 'sid=ok; Path=/' });
    }
    send(res, 404, {});
  });
});
api.listen(apiPort, '127.0.0.1');
app.listen(appPort, '127.0.0.1');
NODE
server_pid=$!

for _ in {1..20}; do
  if "$node_bin" -e "require('net').connect($app_port, '127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"; then break; fi
  sleep 0.1
done

mock_runtime="$tmpdir/docker"
cat > "$mock_runtime" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec && "$2" == -i && "$3" == mock-hyperdx && "$4" == node && "$5" == - ]] || exit 99
exec env HYPERDX_LOCAL_EMAIL=admin@ironlog.local HYPERDX_LOCAL_PASSWORD="${HYPERDX_TEST_PASSWORD:-IronlogDev123!}" HYPERDX_APP_PORT="$HYPERDX_TEST_APP_PORT" HYPERDX_API_PORT="$HYPERDX_TEST_API_PORT" FRONTEND_URL="${HYPERDX_TEST_FRONTEND:-http://localhost:$HYPERDX_TEST_APP_PORT}" "$HYPERDX_TEST_NODE" -
SH
chmod +x "$mock_runtime"

PATH="$tmpdir:$PATH" bash "$helper" docker mock-hyperdx > "$tmpdir/first.out"
grep -Fx 'HyperDX local account created and verified.' "$tmpdir/first.out"

PATH="$tmpdir:$PATH" bash "$helper" docker mock-hyperdx > "$tmpdir/repeat.out"
grep -Fx 'HyperDX existing local account verified.' "$tmpdir/repeat.out"

if HYPERDX_TEST_PASSWORD='Incorrect123!' PATH="$tmpdir:$PATH" bash "$helper" docker mock-hyperdx > "$tmpdir/wrong-password.out" 2>&1; then
  echo 'expected wrong existing password to fail' >&2
  exit 1
fi
grep -F 'existing accounts were not changed' "$tmpdir/wrong-password.out"
[[ $(cat "$tmpdir/state") == registered ]]

printf https > "$tmpdir/state"
HYPERDX_TEST_FRONTEND=https://siem.example.com PATH="$tmpdir:$PATH" bash "$helper" docker mock-hyperdx > "$tmpdir/https.out"
grep -Fx 'HyperDX existing local account verified.' "$tmpdir/https.out"

printf bypass > "$tmpdir/state"
if PATH="$tmpdir:$PATH" bash "$helper" docker mock-hyperdx > "$tmpdir/bypass.out" 2>&1; then
  echo 'expected auth bypass to fail' >&2
  exit 1
fi
grep -F 'native authentication is not protecting' "$tmpdir/bypass.out"

bad_runtime="$tmpdir/podman"
cat > "$bad_runtime" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec && "$2" == -i && "$3" == mock-hyperdx && "$4" == node && "$5" == - ]] || exit 99
exec env HYPERDX_APP_PORT="$HYPERDX_TEST_APP_PORT" HYPERDX_API_PORT="$HYPERDX_TEST_API_PORT" "$HYPERDX_TEST_NODE" -
SH
chmod +x "$bad_runtime"

if PATH="$tmpdir:$PATH" bash "$helper" podman mock-hyperdx > "$tmpdir/failure.out" 2>&1; then
  echo 'expected missing-environment test to fail' >&2
  exit 1
fi
grep -F 'required container environment variable HYPERDX_LOCAL_EMAIL is empty' "$tmpdir/failure.out"

echo 'bootstrap-hyperdx-local tests passed'
