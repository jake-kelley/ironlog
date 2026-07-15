# Auditable event catalog (AU-2, AU-12)

Status: DRAFT — this is the organization's committed list of captured events.
Review annually and when onboarding new systems. The Vector VRL transforms
(Phase 2+) implement exactly this list; changes require updating both.

## Windows (channels: Security, System, Microsoft-Windows-PowerShell/Operational)

| Category | Event IDs |
|---|---|
| Logon / logoff / failures | 4624, 4625, 4634, 4647, 4648 |
| Special privileges / privilege use | 4672, 4673, 4674 |
| Account management | 4720, 4722, 4723, 4724, 4725, 4726, 4728, 4732, 4738, 4740, 4767 |
| Process creation | 4688 |
| Service install / scheduled tasks | 4697, 4698, 4699, 4702 |
| Audit log tampering | 1102, 1104 |
| PowerShell execution | 4103, 4104 |

## Linux (journald + auditd)

| Category | Source |
|---|---|
| Authentication (sshd, PAM, su) | journald: sshd, login, su identifiers |
| Privilege escalation | journald: sudo; auditd: USER_CMD |
| Identity changes | auditd: ADD_USER, DEL_USER, USER_MGMT, GRP_MGMT |
| Process execution (privileged) | auditd: SYSCALL/execve per audit.rules |
| Service state changes | journald: systemd unit start/stop/fail |
| Audit subsystem health | auditd: DAEMON_START, DAEMON_END, CONFIG_CHANGE |

## AWS

| Source | Scope |
|---|---|
| CloudTrail | All management events, all regions, org trail; ConsoleLogin, IAM/*, KMS/*, sts:AssumeRole highlighted |
| GuardDuty | All findings, all severities |
| VPC Flow Logs | ACCEPT + REJECT, all VPCs in scope |
| S3 access logs | Buckets holding audit records and sensitive data |

## Kubernetes

| Category | Scope |
|---|---|
| API server audit log | Cluster-level; recommended addition via HEC |
| Workload stdout/stderr | Namespaces in compliance scope |
| RBAC denials, auth failures | From API audit policy |
