#!/usr/bin/env bash
# Install Argo CD and expose its UI via Istio at https://argocd.reon.buzz
# (with IP allowlist applied via AuthorizationPolicy).
set -euo pipefail

NS=argocd
CHART_VERSION="7.7.10"   # Argo CD app version 2.13.x

# Mesh-injected so its pods can scrape Prom and use mTLS like everything else.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=enabled --overwrite

helm upgrade --install argocd argo/argo-cd \
  --namespace "$NS" \
  --version "$CHART_VERSION" \
  --values ../helm-values/argocd-values.yaml \
  --wait

echo "Waiting for argocd-server to be ready..."
kubectl -n "$NS" rollout status deployment/argocd-server --timeout=300s

echo "Applying Argo CD Istio VirtualService + IP allowlist AuthorizationPolicy..."
kubectl apply -f ../ingress/argocd-virtualservice.yaml
kubectl apply -f ../ingress/argocd-authorizationpolicy.yaml

echo "Argo CD installed."
echo "Initial admin password:"
kubectl -n "$NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo "Login at https://argocd.reon.buzz (will work once cert-manager issues the cert and ExternalDNS publishes the A record)."
echo "Username: admin"
echo "ROTATE THE PASSWORD via the UI immediately after first login."
