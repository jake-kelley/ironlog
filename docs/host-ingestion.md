---
type: Runbook
title: Host and Kubernetes ingestion
description: How to onboard Linux agents, Windows agents, and Kubernetes clusters to the always-on Vector aggregator.
tags: [linux, windows, kubernetes, ingestion, runbook]
timestamp: 2026-07-16T00:00:00Z
---

# Host + Kubernetes ingestion (Phase 3)

The always-on `vector-hosts` aggregator accepts two inputs. Everything lands in
ClickHouse as `svc_vector` (INSERT-only); events are committed in
docs/event-catalog.md (Linux + Kubernetes sections).

    Linux hosts (vector agent: journald + auditd)
        -> :6000  Vector native protocol -> siem.linux_syslog
    Kubernetes clusters (any Splunk-HEC-capable shipper)
        -> :8088  splunk_hec (token)     -> siem.k8s_logs

## Linux agents

1. Install Vector (>= 0.57) from the official apt/yum repo on each in-scope host.
2. Deploy `vector/agent-linux.yaml` to `/etc/vector/vector.yaml`.
3. Set environment for the service (e.g. systemd drop-in
   `/etc/systemd/system/vector.service.d/siem.conf`):

       [Service]
       Environment=VECTOR_AGGREGATOR_ADDR=<siem-host>:6000
       Environment=VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true

   (Vector >= 0.57 disables `${VAR}` config interpolation unless that flag is set.)
4. Vector must run as root (default unit) to read `/var/log/audit/audit.log`
   and the full journal; alternatively add ACLs for a dedicated user.
5. `systemctl enable --now vector`, then confirm rows:
   `SELECT host, count() FROM siem.linux_syslog GROUP BY host` (as analyst).

Agent behavior: journald events ship with their native fields; auditd lines
ship raw, tagged `source=auditd` + `host`. ALL normalization happens on the
aggregator (vector/hosts.yaml -> linux_map) so parsing changes never require
touching fleet agents. Agents buffer to local disk when the aggregator is down.

## Kubernetes clusters

Point any Splunk-HEC-compatible shipper (Vector DaemonSet with `splunk_hec`
sink, splunk-connect-for-kubernetes, fluentd splunk plugin) at:

    endpoint:  http://<siem-host>:8088   (path /services/collector/event)
    token:     SPLUNK_HEC_TOKEN from .env

Event contract — send JSON event objects with these keys (all optional,
defaulted to '' when missing; unknown keys are kept in `raw`):

    {"cluster":"prod-east","namespace":"payments","node":"node-3",
     "container":"api","pod":"api-7d9f8b6c5-x2vqz","level":"error",
     "message":"the log line"}

Recommended scope (per the AU-2 catalog): namespaces in compliance scope, plus
the API server audit log — ship audit events with `container: "apiserver-audit"`
and the audit JSON in `message` so RBAC denials and auth failures are queryable.

Vector DaemonSet sink example:

    sinks:
      siem:
        type: splunk_hec_logs
        inputs: [k8s_meta]        # transform that sets the contract keys
        endpoint: http://<siem-host>:8088
        default_token: "${SIEM_HEC_TOKEN}"
        encoding: { codec: json }

## Local k3s demo cluster

A single-node k3s (compose profile `k3s`) exercises the full K8s path locally.
Bring it up with `bash k8s/k3s-demo-up.sh` (boots k3s, creates the HEC token
secret, and points the shipper at the aggregator's container IP — pods inside
the in-docker k3s cannot resolve docker service names because k3s replaces a
loopback node resolver with a public one). `k8s/vector-shipper.yaml` is the
same manifest a real cluster would use; on real clusters deploy it with
kubectl, create the secret, and set SIEM_ENDPOINT to your aggregator URL.

## Verifying the pipeline

- `docker logs siem-vector-hosts` — no auth or sink errors.
- HEC smoke test (expect `{"text":"Success"}`):

      curl -H "Authorization: Splunk $TOKEN" \
        -d '{"event":{"cluster":"smoke","message":"hello"}}' \
        http://localhost:8088/services/collector/event

- Rows: `SELECT cluster, count() FROM siem.k8s_logs GROUP BY cluster`.

## Windows hosts (Phase 4)

From an elevated PowerShell in the repo root:

    powershell -ExecutionPolicy Bypass -File scripts\install-windows-agent.ps1

Installs Vector 0.57.0 to `C:\Program Files\Vector`, deploys
`vector\agent-windows.yaml` to `C:\ProgramData\vector\vector.yaml`, and runs
the `vector` service as LocalSystem (required to read the Security channel).
Ships Security, System, and Microsoft-Windows-PowerShell/Operational to the
aggregator -> `siem.windows_events`.

**If the aggregator runs in WSL2 docker on the same machine** (this lab):
`localhost:6000` does NOT work from Windows services — the WSL localhost
relay exists only in interactive logon sessions, so the agent buffers to disk
and ships nothing. Fix + keep fixed across reboots (also auto-starts the
stack at boot):

    powershell -ExecutionPolicy Bypass -File scripts\fix-windows-agent-addr.ps1 -Register

**Idle-freeze pilot watch**: the windows_event_log source has a known
idle-freeze bug (vectordotdev/vector#25194). Symptom: service Running but
`SELECT max(event_time) FROM siem.windows_events` goes stale while the machine
is active. Remedy: `Restart-Service vector` (buffered events are preserved);
fallback if chronic: Winlogbeat OSS. Events are buffered on the agent's disk
whenever the aggregator is unreachable, so restarts don't lose data.

## Notes

- One shared HEC token (SPLUNK_HEC_TOKEN). Rotating it: update .env,
  `docker compose up -d vector-hosts`, then update cluster shippers.
- The sink-level ClickHouse healthcheck is disabled in the vector configs:
  Vector probes without auth, which our locked-down `default` user correctly
  rejects (403). Inserts are authenticated and unaffected.
- Windows agents are Phase 4 (windows_event_log source; pilot first — known
  idle-freeze bug, see CLAUDE.md conventions).
