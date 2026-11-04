# Ironlog Helm chart

One chart for Kubernetes, Amazon EKS and OpenShift. It deploys the three
ironlog images (contract: `images/README.md`, per-image notes in
`images/<name>/README.md`):

| Workload | Kind | Notes |
|---|---|---|
| `<release>-ironlog-clickhouse` | StatefulSet (1 replica) + PVC | Services `…-clickhouse` (ClusterIP 8123/9000) and `…-clickhouse-headless` |
| `…-clickhouse-schema` | Job, Helm hook `post-install,post-upgrade` | runs `ironlog-schema` against the ClickHouse Service |
| `…-grafana` | Deployment + PVC (default) | Service, optional Ingress, optional OpenShift Route |
| `…-vector` | Deployment (`IRONLOG_VECTOR_ROLE=hosts`) | Service 8088 HEC / 6000 agents, type configurable |
| `…-vector-aws` | Deployment (`aws`), **off by default** | SQS/S3 pull; IRSA or static keys |

## Install

Kubernetes / EKS:

```
kubectl create namespace ironlog
kubectl label namespace ironlog pod-security.kubernetes.io/enforce=restricted   # optional, the chart complies
helm install ironlog deploy/helm/ironlog -n ironlog
```

OpenShift (restricted-v2; no `runAsUser`, `runAsGroup` or `fsGroup` is set, the SCC assigns them):

```
oc new-project ironlog
helm install ironlog deploy/helm/ironlog -n ironlog \
  --set openshift=true --set grafana.route.enabled=true --set grafana.route.host=grafana.apps.example.com
```

Passwords are generated on first install and kept on upgrade (read back from
the release Secret with `lookup`). Read the Grafana admin password:

```
kubectl -n ironlog get secret ironlog -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d
```

(The Secret is named `<release>-ironlog`, or just `<release>` when the
release name contains "ironlog", as with `helm install ironlog` above.) `helm template` cannot
`lookup`, so each render shows fresh random values; use `helm install`, or set
the passwords or `secrets.existingSecret`, when the Secret must be stable.

## Schema and start-up order

`ironlog-schema` is applied by the post-install/post-upgrade hook Job and
verifies 7 `siem` tables, `audit.query_archive`, the 3 service accounts, TTLs
and storage policy. It exits non-zero otherwise, which fails the Helm
release. The Job is deleted on success; on failure it stays for `kubectl logs`.

Grafana and Vector carry a `wait-for-schema` **init container** (ClickHouse
image, bounded by `schemaGate.timeoutSeconds`, then it fails and the pod
retries). It logs in with the pod's own ClickHouse account and waits for
`schemaGate.expectedTables` `siem` tables. Why not a Job-only design:

- A hook Job runs once per Helm operation. Pods restart, reschedule and scale at
  other times (node drain, OOM, `kubectl rollout restart`, a ClickHouse restart
  that has not finished its schema step); an init container re-checks the real
  state every time.
- `helm install --wait` runs post-install hooks only **after** resources are
  ready, so a Job-only gate with `--wait` would deadlock. This does not happen
  here because the ClickHouse image also runs `ironlog-schema` itself in the
  background on every server start; the gate opens from that, and the hook Job
  then re-applies and verifies (idempotent). Tested: `helm install --wait` and
  `helm upgrade --wait` both succeed.
- The gate uses each pod's own least-privilege account, not the admin password.

Limit: the gate proves login and table existence, not the TTLs. The hook Job is
the authority for the full verification.

## Security

Every pod: `runAsNonRoot`, seccomp `RuntimeDefault`; every container:
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`; service accounts
do not mount a token. This matches Pod Security `restricted` and OpenShift
`restricted-v2`.

- `openshift: false` (default): the chart pins the image users (ClickHouse and
  Vector 10001, Grafana 472), `runAsGroup: 0`, `fsGroup: 0` so fresh PVCs are
  writable.
- `openshift: true`: none of those are set.
- `podSecurityContext`: extra pod-level keys merged over the above, e.g.
  `{runAsUser: 1000770000, runAsGroup: 0}` to imitate OpenShift on any cluster.
- Writable paths and `readOnlyRootFilesystem` (all `true` by default,
  `<component>.readOnlyRootFilesystem` switches it off): ClickHouse
  `/var/lib/clickhouse` (PVC), `/tmp`, `/var/log/clickhouse-server`, and
  `/etc/clickhouse-server` (an `emptyDir` seeded from the image by an init
  container, because the entrypoint writes `users.d/default-user.xml` and
  `config.d/20-storage-s3.xml`); Grafana `/var/lib/grafana` (PVC or `emptyDir`),
  `/tmp`, `/var/log/grafana`; Vector `/var/lib/vector` (`emptyDir`, so disk
  buffers do not survive a pod replacement) and `/tmp`.
- `networkPolicy.enabled`: only Grafana, Vector (hosts, aws), the schema Job and
  ClickHouse pods may reach ClickHouse on 8123/9000. Needs a CNI that enforces
  NetworkPolicy.
- Grafana keeps its SQLite files `0640`: a persistent `/var/lib/grafana` must be
  reused by the same UID (`images/grafana/README.md`). OpenShift assigns one UID
  per namespace, so this holds there; on plain Kubernetes keep
  `grafana.uid` stable or use Postgres.

## Values summary

| Key | Default | Meaning |
|---|---|---|
| `openshift` | `false` | restricted-v2 mode (no fixed UID/GID/fsGroup) |
| `podSecurityContext` | `{}` | extra pod securityContext keys |
| `image.registry` | `ghcr.io/jake-kelley` | registry for all three images |
| `image.{clickhouse,grafana,vector}.{repository,tag}` | `ironlog-<name>`, `26.8.34.13` / `13.3.0` / `0.61.0` | moving upstream-version tags; pin `<version>-<git sha>` for production |
| `image.pullPolicy`, `image.pullSecrets` | `IfNotPresent`, `[]` | |
| `secrets.existingSecret` | `""` | Secret with keys `CLICKHOUSE_PASSWORD CH_VECTOR_PASSWORD CH_GRAFANA_ANALYST_PASSWORD CH_GRAFANA_AUDITOR_PASSWORD GF_SECURITY_ADMIN_PASSWORD SPLUNK_HEC_TOKEN` (+ optional `IRONLOG_S3_ACCESS_KEY_ID IRONLOG_S3_SECRET_ACCESS_KEY GF_DATABASE_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY`) |
| `secrets.*Password`, `secrets.hecToken` | `""` | explicit values; empty = generated and kept |
| `s3.enabled` | `false` | sets `IRONLOG_S3_TIER=on` |
| `s3.endpoint`, `s3.region`, `s3.hotDays`, `s3.retentionDays` | `""`, `""`, `30`, `400` | `IRONLOG_S3_ENDPOINT`, `_REGION`, `IRONLOG_HOT_DAYS`, `IRONLOG_RETENTION_DAYS` |
| `s3.accessKeyId`, `s3.secretAccessKey` | `""` | static keys (S3-compatible stores); both empty = AWS credential chain, e.g. `clickhouse.serviceAccount.annotations` with an IRSA role |
| `clickhouse.replicas` | `1` | other values fail until replication exists |
| `clickhouse.persistence.{size,storageClass,accessModes,retainOnDelete}` | `100Gi`, default, `[ReadWriteOnce]`, `true` | |
| `schema.{waitSeconds,backoffLimit,activeDeadlineSeconds}` | `300`, `3`, `900` | hook Job |
| `schemaGate.{timeoutSeconds,expectedTables}` | `600`, `7` | init container |
| `grafana.replicas` | `1` | `>1` requires `database.type=postgres` |
| `grafana.persistence.{enabled,size,storageClass,existingClaim}` | `true`, `5Gi` | ignored with Postgres (`emptyDir`) |
| `grafana.database.{type,host,name,user,password,sslMode}` | `sqlite` | `postgres` sets `GF_DATABASE_*`; password from `grafana.database.password` or key `GF_DATABASE_PASSWORD` |
| `grafana.rootUrl` | `""` | `GF_SERVER_ROOT_URL` |
| `grafana.service.{type,port}` | `ClusterIP`, `80` | |
| `grafana.ingress.{enabled,className,annotations,hosts,tls}` | off | `hosts: [{host, path}]` |
| `grafana.route.{enabled,host,annotations,tls}` | off | OpenShift Route, edge TLS with redirect |
| `vector.hosts.replicas` | `1` | |
| `vector.hosts.service.{type,annotations,loadBalancerSourceRanges,hecPort,agentPort,hecNodePort,agentNodePort}` | `ClusterIP`, 8088, 6000 | use `LoadBalancer` / `NodePort` for agents and clusters outside this one |
| `vector.aws.enabled` | `false` | when on, `region` and all four `queues.*` (SQS URLs) are required |
| `vector.aws.{accessKeyId,secretAccessKey}` | `""` | optional; empty = IRSA via `vector.aws.serviceAccount.annotations` |
| `<component>.{resources,nodeSelector,tolerations,affinity,extraEnv,serviceAccount.annotations}` | | per workload |
| `networkPolicy.enabled` | `false` | see Security |

Not covered by this chart: TLS between services, replication/Keeper, a Postgres
for Grafana (bring your own), pod anti-affinity defaults, HEC through an
Ingress (use a `LoadBalancer`/`NodePort` Service or your own Ingress/Route).

## Validate

```
helm lint deploy/helm/ironlog
helm template t deploy/helm/ironlog | kubeconform -strict -kubernetes-version 1.34.0 -summary
```

`ci/kind-values.yaml` is the live-test profile: locally built images
(`ghcr.io/jake-kelley/ironlog-<name>:dev`, `docker build -f images/<name>/Dockerfile .`,
`kind load docker-image`), `openshift=true`, pods forced to
`runAsUser: 1000770000` / `runAsGroup: 0`, namespace labelled
`pod-security.kubernetes.io/enforce=restricted`.

```
helm install ironlog deploy/helm/ironlog -n ironlog -f deploy/helm/ironlog/ci/kind-values.yaml --wait --timeout 8m
```

Verified on kind v0.30.0 (Kubernetes v1.34.0): install and upgrade, schema hook
Job success, Grafana `/api/health` ok and datasource health OK, HEC POST landing
in `siem.k8s_logs`, NetworkPolicy blocking an unrelated pod. **Not verified on
a real OpenShift cluster**: the SCC admission, assigned UID/fsGroup behaviour,
Route and the OpenShift image registry were never exercised. kind does not
apply an fsGroup to local-path volumes, so volume-permission behaviour under a
real restricted-v2 SCC is untested.
