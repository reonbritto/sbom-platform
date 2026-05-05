#!/usr/bin/env bash
# Install cert-manager and apply the Let's Encrypt staging ClusterIssuer.
# Uses Workload Identity to do DNS-01 challenges against Azure DNS (reon.buzz).
set -euo pipefail

NS=cert-manager
CHART_VERSION="v1.16.1"

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$NS" \
  --create-namespace \
  --version "$CHART_VERSION" \
  --values ../helm-values/cert-manager-values.yaml \
  --wait

echo "Waiting for cert-manager webhook to become ready..."
kubectl -n "$NS" rollout status deployment/cert-manager-webhook --timeout=180s

echo "Applying Let's Encrypt staging ClusterIssuer..."
kubectl apply -f ../infra-manifests/cert-manager-clusterissuer.yaml

echo "cert-manager + ClusterIssuer ready."
