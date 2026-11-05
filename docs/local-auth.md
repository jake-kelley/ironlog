---
type: Guide
title: Local app authentication
description: Native Grafana login, development credentials, and the boundary for deferred external identity integration.
tags: [authentication, deployment, grafana]
timestamp: 2026-09-14T00:00:00Z
---

# Local app authentication

Ironlog currently uses Grafana's native username/password authentication; Grafana is the only UI.
Keycloak integration is paused. Ironlog does not deploy Keycloak, its
Postgres database, or oauth2-proxy. Future identity integration will use an
existing environment-managed Keycloak; it is not enabled by this change.

## Fresh development installs

| App | URL | Username | Password |
|---|---|---|---|
| Grafana | http://localhost:3000 | `admin` | `IronlogDev123!` |

On an appliance, replace `localhost` with `APPLIANCE_FQDN`. These shared
development credentials are intentional defaults, not production secrets.
Grafana still authenticates users; anonymous query access is not enabled.
There is no Keycloak redirect, hosts-file prerequisite, SSO, or enforced MFA.

From the repository root, run `./bootstrap.sh` in a Bash shell. Podman is the
default runtime. For Docker, use `IRONLOG_CONTAINER_RUNTIME=docker ./bootstrap.sh`.
Bootstrap first verifies that selected runtime, its Compose
provider, and its service or machine are ready; only then does it write `.env`.
The selected runtime is persisted as `IRONLOG_CONTAINER_RUNTIME` in `.env`.
Existing Docker installs should set `IRONLOG_CONTAINER_RUNTIME=docker` there
before using `scripts/compose.sh`.
Bootstrap generates random database/service credentials and starts the
stack. Grafana creates its administrator from its initial configuration and
provisions its ClickHouse datasources and dashboards from `grafana/provisioning`.

To choose other credentials in Compose, copy `.env.example` to `.env`,
set its backend secrets and `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD`,
then run `scripts/compose.sh up -d` from the repository root.
For an appliance, set overrides in its input config;
`APPLIANCE_MODE=local` is the supported default. `oidc` and `ldap` are
deferred and rejected rather than silently producing a different auth mode.

## Existing deployments

Preserve Grafana, ClickHouse and Vector data. Do not use
`scripts/compose.sh down -v` to change authentication. Bootstrap refuses to
overwrite an existing `.env`; update that file with the local auth variables
from `.env.example` instead.

Switching from Docker to Podman does not automatically migrate existing Docker
volumes. Keep `IRONLOG_CONTAINER_RUNTIME=docker` to continue using those
volumes, or plan and perform a separate data migration before changing runtime.

Default Grafana admin settings only initialize a fresh Grafana database.
They do not reset the password of an existing administrator. Use that
administrator's current local credentials. A mismatch needs account recovery
or configuration correction, not deletion of the Grafana data volume.

AMI changes apply to new builds. Reusing an existing data volume retains
app accounts, so configure their actual credentials. Upgrading an already
running appliance requires installing the new units and scripts; changing
`APPLIANCE_MODE` alone on an old image does not implement local auth.

## Authorization and audit boundaries

ClickHouse's write-only ingest (`svc_vector`) and read-only Grafana accounts
(`svc_grafana_analyst`, `svc_grafana_auditor`) are unchanged. The Grafana login is separate from database service accounts.
Queries are archived under shared service usernames, not individual app
users. Grafana's shared datasources do not enforce separate human analyst
and auditor access. Generic shared app logins also do not provide individual
accountability. Local mode does not satisfy an enforced-MFA requirement.

## Future external identity integration

When resumed, configure Ironlog as a client of an existing Keycloak.
Client registration, claim/role mapping, TLS, redirects, and Grafana's SSO
boundary must be implemented and tested together. Never add an on-box
Keycloak/Postgres deployment to satisfy that integration.
