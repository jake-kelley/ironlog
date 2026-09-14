#!/usr/bin/env bash
# Bootstrap HyperDX's native local account without bypassing its authentication.
#
# HyperDX 2.19.0 API contract, verified from upstream commit 9488421:
#   POST /register/password { email, password, confirmPassword }
#   POST /login/password    { email, password } -> 302 .../search
# The app's /api/* proxy forwards to the API server after removing /api.

set -euo pipefail

usage() {
  echo "usage: $0 <docker|podman> <hyperdx-container-name>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

runtime=$1
container=$2

case "$runtime" in
  docker|podman) ;;
  *) usage ;;
esac

command -v "$runtime" >/dev/null 2>&1 || {
  echo "HyperDX bootstrap failed: runtime '$runtime' is not installed." >&2
  exit 69
}

# Run inside target container: API port normally is not published, and keeping
# credentials in its environment avoids putting either secret in this process's
# arguments or output. Node is present because this is HyperDX's app runtime.
"$runtime" exec -i "$container" node - <<'NODE'
const http = require('http');

const required = [
  'HYPERDX_LOCAL_EMAIL',
  'HYPERDX_LOCAL_PASSWORD',
  'HYPERDX_APP_PORT',
  'HYPERDX_API_PORT',
];
for (const name of required) {
  if (!process.env[name]) {
    throw new Error(`required container environment variable ${name} is empty`);
  }
}

const email = process.env.HYPERDX_LOCAL_EMAIL;
const password = process.env.HYPERDX_LOCAL_PASSWORD;
const appPort = process.env.HYPERDX_APP_PORT;
const apiPort = process.env.HYPERDX_API_PORT;
const appOrigin = `http://127.0.0.1:${appPort}`;
const apiOrigin = `http://127.0.0.1:${apiPort}`;

function request(origin, path, { method = 'GET', body, cookie } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const url = new URL(path, origin);
    const req = http.request(url, {
      method,
      headers: {
        // The frontend may set a cookie domain from FRONTEND_URL. Supplying
        // localhost is sufficient for this in-container proxy check.
        Host: `localhost:${url.port}`,
        ...(payload ? {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
        } : {}),
        ...(cookie ? { Cookie: cookie } : {}),
      },
      timeout: 5000,
    }, res => {
      let responseBody = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { responseBody += chunk; });
      res.on('end', () => resolve({
        status: res.statusCode || 0,
        headers: res.headers,
        body: responseBody,
      }));
    });
    req.on('timeout', () => req.destroy(new Error('request timed out')));
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function cookies(headers) {
  const setCookie = headers['set-cookie'];
  if (!setCookie) return '';
  const values = Array.isArray(setCookie) ? setCookie : [setCookie];
  return values.map(value => value.split(';', 1)[0]).join('; ');
}

function isSearchRedirect(response) {
  if (response.status !== 302 || !response.headers.location) return false;
  try {
    return new URL(response.headers.location, appOrigin).pathname === '/search';
  } catch (_) {
    return false;
  }
}

async function waitForReadiness() {
  const attempts = 30;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const [apiHealth, proxyHealth] = await Promise.all([
        request(apiOrigin, '/health'),
        request(appOrigin, '/api/health'),
      ]);
      if (apiHealth.status === 200 && proxyHealth.status === 200) return;
    } catch (_) {
      // Service still starting. Do not print transient transport errors.
    }
    if (attempt < attempts) await new Promise(resolve => setTimeout(resolve, 2000));
  }
  throw new Error('HyperDX API and frontend /api proxy were not ready after 60 seconds');
}

async function main() {
  await waitForReadiness();

  // Both routes are behind isUserAuthenticated in HyperDX 2.19.0. Check this
  // before login so setup cannot accidentally validate an auth-bypass mode.
  const [anonymousSources, anonymousQuery] = await Promise.all([
    request(appOrigin, '/api/sources'),
    request(appOrigin, '/api/clickhouse-proxy', { method: 'POST' }),
  ]);
  if (anonymousSources.status !== 401 || anonymousQuery.status !== 401) {
    throw new Error('native authentication is not protecting HyperDX private routes');
  }

  const registration = await request(appOrigin, '/api/register/password', {
    method: 'POST',
    body: { email, password, confirmPassword: password },
  });
  if (registration.status !== 200 && registration.status !== 409) {
    throw new Error(`local account registration failed with HTTP ${registration.status}`);
  }

  // Always log in. A 409 means another account/team already exists; this only
  // proves configured credentials work and never resets or mutates that account.
  const login = await request(appOrigin, '/api/login/password', {
    method: 'POST',
    body: { email, password },
  });
  const sessionCookie = cookies(login.headers);
  if (!isSearchRedirect(login) || !sessionCookie) {
    throw new Error('local account login failed; existing accounts were not changed');
  }

  const [sourcesResponse, connectionsResponse] = await Promise.all([
    request(appOrigin, '/api/sources', { cookie: sessionCookie }),
    request(appOrigin, '/api/connections', { cookie: sessionCookie }),
  ]);
  if (sourcesResponse.status !== 200 || connectionsResponse.status !== 200) {
    throw new Error('authenticated check of HyperDX default setup failed');
  }

  let sources;
  let connections;
  try {
    sources = JSON.parse(sourcesResponse.body);
    connections = JSON.parse(connectionsResponse.body);
  } catch (_) {
    throw new Error('HyperDX default setup returned invalid JSON');
  }
  if (!Array.isArray(sources) || sources.length === 0 ||
      !Array.isArray(connections) || connections.length === 0) {
    throw new Error('DEFAULT_SOURCES or DEFAULT_CONNECTIONS was not created for local account');
  }

  console.log(registration.status === 200
    ? 'HyperDX local account created and verified.'
    : 'HyperDX existing local account verified.');
}

main().catch(error => {
  // Deliberately no response bodies, usernames, passwords, or cookies in logs.
  console.error(`HyperDX bootstrap failed: ${error.message}`);
  process.exitCode = 1;
});
NODE
