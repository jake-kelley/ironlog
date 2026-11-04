{{- define "ironlog.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- else if contains "ironlog" .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-ironlog" .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ironlog.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: ironlog
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/* selector labels: (dict "root" $ "component" "grafana") */}}
{{- define "ironlog.selector" -}}
app.kubernetes.io/name: ironlog
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* pod template labels: common labels plus the component (selector = name+instance+component) */}}
{{- define "ironlog.podLabels" -}}
{{ include "ironlog.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* image reference: (dict "root" $ "img" .Values.image.grafana) */}}
{{- define "ironlog.image" -}}
{{- printf "%s/%s:%s" .root.Values.image.registry .img.repository (.img.tag | toString) -}}
{{- end -}}

{{- define "ironlog.pullSecrets" -}}
{{- with .Values.image.pullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "ironlog.secretName" -}}
{{- default (include "ironlog.fullname" .) .Values.secrets.existingSecret -}}
{{- end -}}

{{/* ClickHouse service DNS name (same namespace) */}}
{{- define "ironlog.chHost" -}}
{{- printf "%s-clickhouse" (include "ironlog.fullname" .) -}}
{{- end -}}

{{/* Secret value: explicit value, else the one already in the cluster, else random. (dict "root" $ "key" K "value" V) */}}
{{- define "ironlog.pw" -}}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace (include "ironlog.fullname" .root) -}}
{{- if .value -}}
{{- .value -}}
{{- else if and $existing $existing.data (hasKey $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}

{{/* env var from the chart/existing Secret: (dict "root" $ "name" N "key" K "optional" bool) */}}
{{- define "ironlog.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "ironlog.secretName" .root }}
      key: {{ default .name .key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end -}}

{{/* Pod securityContext: (dict "root" $ "uid" 10001) */}}
{{- define "ironlog.podSC" -}}
{{- $sc := dict "runAsNonRoot" true "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- if not .root.Values.openshift -}}
{{- $_ := set $sc "runAsUser" (int .uid) -}}
{{- $_ := set $sc "runAsGroup" 0 -}}
{{- $_ := set $sc "fsGroup" 0 -}}
{{- end -}}
{{- toYaml (mergeOverwrite $sc (deepCopy .root.Values.podSecurityContext)) -}}
{{- end -}}

{{/* Container securityContext: (dict "readOnly" bool) */}}
{{- define "ironlog.containerSC" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: {{ .readOnly }}
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* S3 tier / retention env shared by the server and the schema Job */}}
{{- define "ironlog.tierEnv" -}}
{{- if .Values.s3.enabled }}
{{- if not .Values.s3.endpoint }}{{ fail "s3.enabled=true requires s3.endpoint" }}{{ end }}
{{- if le (int .Values.s3.retentionDays) (int .Values.s3.hotDays) }}{{ fail "s3.retentionDays must exceed s3.hotDays" }}{{ end }}
- name: IRONLOG_S3_TIER
  value: "on"
- name: IRONLOG_S3_ENDPOINT
  value: {{ .Values.s3.endpoint | quote }}
{{- with .Values.s3.region }}
- name: IRONLOG_S3_REGION
  value: {{ . | quote }}
{{- end }}
- name: IRONLOG_HOT_DAYS
  value: {{ .Values.s3.hotDays | quote }}
- name: IRONLOG_RETENTION_DAYS
  value: {{ .Values.s3.retentionDays | quote }}
{{- else }}
- name: IRONLOG_S3_TIER
  value: "off"
{{- end }}
{{- end -}}

{{/* clickhouse-client address and account for non-server pods: (dict "root" $ "user" U "key" SECRETKEY) */}}
{{- define "ironlog.chAccountEnv" -}}
- name: CLICKHOUSE_HOST
  value: {{ include "ironlog.chHost" .root }}
- name: HOME
  value: /tmp
- name: CLICKHOUSE_USER
  value: {{ .user }}
{{ include "ironlog.secretEnv" (dict "root" .root "name" "CLICKHOUSE_PASSWORD" "key" .key) }}
{{- end -}}

{{/* Init container that waits until the schema is usable: (dict "root" $ "user" U "key" SECRETKEY) */}}
{{- define "ironlog.schemaGate" -}}
- name: wait-for-schema
  image: {{ include "ironlog.image" (dict "root" .root "img" .root.Values.image.clickhouse) }}
  imagePullPolicy: {{ .root.Values.image.pullPolicy }}
  command:
    - /bin/bash
    - -c
    - |
      deadline=$((SECONDS + {{ int .root.Values.schemaGate.timeoutSeconds }}))
      while true; do
        n=$(clickhouse-client --query "SELECT count() FROM system.tables WHERE database = 'siem'" 2>/dev/null || true)
        if [ "${n:-0}" -ge {{ int .root.Values.schemaGate.expectedTables }} ] 2>/dev/null; then
          echo "schema ready: $n siem tables visible to $CLICKHOUSE_USER"; exit 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "timed out waiting for the ClickHouse schema (got '${n:-}' tables)" >&2; exit 1
        fi
        sleep 3
      done
  env:
    {{- include "ironlog.chAccountEnv" . | nindent 4 }}
  securityContext:
    {{- include "ironlog.containerSC" (dict "readOnly" true) | nindent 4 }}
  resources:
    requests: {cpu: 10m, memory: 32Mi}
    limits: {memory: 128Mi}
  volumeMounts:
    - {name: tmp, mountPath: /tmp}
{{- end -}}
