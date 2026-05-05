#!/usr/bin/env bash
# Apply the app-of-apps. Argo CD now takes over and installs everything else
# (ESO, ExternalDNS, Gatekeeper, kube-prometheus-stack, Loki, Tempo, Mimir,
# OTel collector, Promtail, sbom-app) by reading from this repo.
set -euo pipefail

kubectl apply -f ../argocd/argocd-apps.yaml

echo "App-of-apps applied. Watch sync progress:"
echo "  kubectl -n argocd get applications -w"
