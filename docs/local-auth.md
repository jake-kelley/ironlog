---
type: Guide
title: Local app authentication
description: Native Grafana and HyperDX logins, development credentials, and the boundary for deferred external identity integration.
tags: [authentication, deployment, grafana, hyperdx]
timestamp: 2026-09-14T00:00:00Z
---

# Local app authentication

Ironlog currently uses each app's native username/password authentication.
Keycloak integration is paused. Ironlog does not deploy Keycloak, its
Postgres database, or oauth2-proxy. Future identity integration will use an
existing environment-managed Keycloak; it is not enabled by this change.

## Fresh development installs

| App | URL | Username | Password |
|---|---|---|---|
| Grafana | http://localhost:3000 | `admin` | `IronlogDev123!` |
| HyperDX | http://localhost:8081 | `admin@ironlog.local` | `IronlogDev123!` |

On an appliance, replace `localhost` with `APPLIANCE_FQDN`. These shared
development credentials are intentional defaults, not production secrets.
Both apps still authenticate users; anonymous query access is not enabled.
There is no Keycloak redirect, hosts-file prerequisite, SSO, or enforced MFA.

Run `./bootstrap.sh` from the repo in a Bash shell with Docker available.
An optional email argument selects the initial HyperDX user's email.
Bootstrap generates random database/service credentials, starts the stack,
and calls `scripts/bootstrap-hyperdx-local.sh docker siem-hyperdx` to create
and verify the HyperDX account. Grafana creates its administrator from its
initial configuration. HyperDX's first team seeds the configured ClickHouse
connection and source definitions.

To choose other credentials in Compose, copy `.env.example` to `.env`,
set its backend secrets and `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`,
`HYPERDX_LOCAL_EMAIL`, and `HYPERDX_LOCAL_PASSWORD`, then use
`docker compose up -d` and the HyperDX helper instead of `bootstrap.sh`.
Set `HYPERDX_SESSION_SECRET` to a random value (`openssl rand -hex 32`);
it signs native sessions and is independent of the generic login password.
For an appliance, set overrides in its input config;
`APPLIANCE_MODE=local` is the supported default. `oidc` and `ldap` are
deferred and rejected rather than silently producing a different auth mode.

## Existing deployments

Preserve Grafana, MongoDB, ClickHouse and Vector data. Do not use
`docker compose down -v` to change authentication. Bootstrap refuses to
overwrite an existing `.env`; update that file with the local auth variables
from `.env.example` instead.

Before recreating the Compose stack, stop the old `siem-hyperdx-auth`,
`siem-keycloak` and `siem-keycloak-db` containers if present. The old proxy
owns port 8081. Preserve their volumes until you decide their data is no
longer needed. Recreate Grafana and HyperDX using the updated Compose file,
then run the HyperDX bootstrap helper with the configured existing account.

Default Grafana admin settings only initialize a fresh Grafana database.
They do not reset the password of an existing administrator. Use that
administrator's current local credentials. The HyperDX helper verifies an
existing matching local account; it must not reset users or destroy teams
when supplied credentials do not match. Such failures need account recovery
or configuration correction, not deletion of MongoDB data.

AMI changes apply to new builds. Reusing an existing data volume retains
app accounts, so configure their actual credentials. Upgrading an already
running appliance requires installing the new units and scripts; changing
`APPLIANCE_MODE` alone on an old image does not implement local auth.

## Authorization and audit boundaries

ClickHouse's write-only ingest and read-only UI service accounts are
unchanged. App accounts remain separate from database service accounts.
Queries are archived under shared service usernames, not individual app
users. Grafana's shared datasources do not enforce separate human analyst
and auditor access. Generic shared app logins also do not provide individual
accountability. Local mode does not satisfy an enforced-MFA requirement.

## Future external identity integration

When resumed, configure Ironlog as a client of an existing Keycloak.
Client registration, claim/role mapping, TLS, redirects, and HyperDX's SSO
boundary must be implemented and tested together. Never add an on-box
Keycloak/Postgres deployment to satisfy that integration.
