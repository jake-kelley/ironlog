---
type: Architecture
title: Ironlog architecture
description: Color-coded Drawbridge diagrams of Ironlog architecture, ingestion, and user access with query auditing.
tags: [architecture, deployment, ingestion]
---

# Ironlog architecture

![Ironlog architecture](images/ironlog-architecture/ironlog-architecture.svg)

[Editable Drawbridge/draw.io](images/ironlog-architecture/ironlog-architecture.drawio) ·
[PNG](images/ironlog-architecture/ironlog-architecture.png) ·
[SVG](images/ironlog-architecture/ironlog-architecture.svg) ·
[DOT source](images/ironlog-architecture/ironlog-architecture.dot)

Rebuilt through [Drawbridge MCP](https://drawbridge.fortiknight.com/docs/mcp/)
on 2026-11-03 against current repository configuration (base commit `bfe4892`).
Drawbridge creates the editable documents, applies presentation edits, routes
connectors, and exports the SVG and PNG images. Four aligned lanes separate
sources, ingestion, data, and applications. Purple means event sources or
people, teal means ingestion, blue means data, and amber means applications;
colors describe roles, not license findings or operational health.

Connections show logical relationships. They do not assert physical cabling,
link speeds, encrypted transport, a running deployment, or high availability.
Optional AWS ingestion is not a dependency for on-prem host/Kubernetes logs.

## Ingestion paths

![Ironlog ingestion paths](images/ironlog-ingestion/ironlog-ingestion.svg)

[Editable Drawbridge/draw.io](images/ironlog-ingestion/ironlog-ingestion.drawio) ·
[PNG](images/ironlog-ingestion/ironlog-ingestion.png) ·
[DOT source](images/ironlog-ingestion/ironlog-ingestion.dot)

The ingestion view separates Windows, Linux, Kubernetes and optional AWS
sources. Ports label protocols at the collectors; disk buffers and VRL
normalization are collector functions. The database identity `svc_vector`
has INSERT permissions without analyst read access.

## User access and query auditing

![Ironlog user access and query auditing](images/ironlog-access-audit/ironlog-access-audit.svg)

[Editable Drawbridge/draw.io](images/ironlog-access-audit/ironlog-access-audit.drawio) ·
[PNG](images/ironlog-access-audit/ironlog-access-audit.png) ·
[DOT source](images/ironlog-access-audit/ironlog-access-audit.dot)

The audit-evidence lane is a logical view of `audit.query_archive` inside
ClickHouse, not another server. The incremental materialized view captures
finished queries and processing errors from `system.query_log`; it does not
provide immutable external storage or individual browser-user attribution.
MongoDB stores HyperDX application state, not SIEM events.

## Implementation details

- Windows and Linux Vector agents send to native port 6000. Kubernetes
  shippers send token-authenticated HEC events on 8088. The optional AWS
  collector reads S3 objects referenced by SQS notifications: CloudTrail,
  GuardDuty, VPC Flow and S3 access logs.
- Both collectors insert through `svc_vector`. ClickHouse holds seven SIEM
  tables and `audit.query_archive`, populated from its query log. Grafana
  uses shared analyst and auditor service identities; HyperDX uses
  `svc_hyperdx`. Database audit attribution is to these shared identities,
  not individual app users.
- Grafana and HyperDX authenticate local accounts on host ports 3000 and
  8081. HyperDX uses MongoDB on internal port 27017 for app state. ClickHouse
  host ports 8123 and 9000 bind to loopback. HTTPS requires an appropriate
  separately configured TLS terminator.
- Persistent storage applies to ClickHouse, Grafana, MongoDB and Vector
  buffers. Compose uses named volumes; the appliance uses its separate data
  volume under `/var/lib/ironlog`. Storage connectors are omitted for clarity.
- Local deployment defaults to Podman with a Compose provider; Docker remains
  selectable. The EC2 appliance uses Podman/systemd Quadlets. Packer targets
  RHEL 9 for shipping and Rocky 9 for development, with internet or local/S3
  software inputs. Appliance schema reconciliation gates database consumers;
  Compose readiness checks are different. No IdP or AI/MCP query component is
  deployed by the current stack.

## Source of truth

`docker-compose.yml`, `quadlets/*.container`, `vector/hosts.yaml`,
`vector/vector.yaml`, `clickhouse/ddl/`, and `scripts/firstboot/` were reviewed.
The optional local k3s demo is represented by the Kubernetes source, not as
an additional production dependency. Authentication and deployment details
remain in [local authentication](local-auth.md) and
[private software builds](private-software-builds.md).

## Rebuild diagrams

Drawbridge is registered as a streamable HTTP MCP server named `drawbridge`
at `https://drawbridge.fortiknight.com/mcp`. No account or API key is required.
The renderer uses that same endpoint directly, so diagram rebuilds also work
before an MCP client reloads its configured servers.

```sh
python scripts/render-diagrams.py
```

Each diagram has its own directory under `docs/images/`, with DOT topology,
a layout profile, editable draw.io XML, SVG, PNG, and a round-trip description.
Topology is validated before rendering. Existing device positions and zone
colors are changed through Drawbridge's `edit_diagram` tool, and exports are
checked for preserved devices and connections. Review all PNGs after changes.
The hosted endpoint receives the diagram topology; use a local Drawbridge MCP
deployment for drawings that must stay inside the network.

Current runtime diagrams omit the deferred AI/MCP query integration. This
Drawbridge connection is a documentation tool, not an appliance component.
