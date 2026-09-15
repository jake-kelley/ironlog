#!/usr/bin/env bash
# One-command bring-up for the LOCAL k3s demo cluster (compose profile "k3s").
# Boots k3s, creates the HEC token secret, and points the shipper at the
# aggregator's current container IP (pods in the containerized k3s cannot use
# container DNS names: k3s swaps a loopback node resolver for a public one).
# Run from the repo root. Real clusters don't need this script — see
# docs/host-ingestion.md.
set -euo pipefail

source scripts/container-runtime.sh
runtime=$(ironlog_container_runtime)
ironlog_require_runtime "$runtime"

TOKEN=$(grep '^SPLUNK_HEC_TOKEN=' .env | cut -d= -f2 | tr -d '\r')
[ -n "$TOKEN" ] || { echo "SPLUNK_HEC_TOKEN missing from .env"; exit 1; }

"$runtime" compose --profile k3s up -d k3s

echo "waiting for k3s node..."
for i in $(seq 1 40); do
  "$runtime" exec siem-k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
  sleep 5
  [ "$i" -eq 40 ] && { echo "k3s not ready"; exit 1; }
done

echo "waiting for siem-logging namespace (manifest auto-apply)..."
for i in $(seq 1 24); do
  "$runtime" exec siem-k3s kubectl get ns siem-logging >/dev/null 2>&1 && break
  sleep 5
done

"$runtime" exec siem-k3s kubectl -n siem-logging create secret generic siem-hec \
  --from-literal=token="$TOKEN" 2>/dev/null || true

AGG_IP=$("$runtime" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' siem-vector-hosts)
echo "pointing shipper at aggregator ${AGG_IP}:8088"
"$runtime" exec siem-k3s kubectl -n siem-logging set env daemonset/vector-shipper \
  "SIEM_ENDPOINT=http://${AGG_IP}:8088"

echo "waiting for shipper pod..."
"$runtime" exec siem-k3s kubectl -n siem-logging rollout status ds/vector-shipper --timeout=180s
echo "k3s demo cluster is up and shipping. Verify:"
echo "  SELECT namespace, count() FROM siem.k8s_logs WHERE cluster='k3s-local' GROUP BY namespace"
