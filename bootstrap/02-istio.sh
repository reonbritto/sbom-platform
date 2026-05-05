#!/usr/bin/env bash
# Install Istio: base (CRDs) -> istiod (control plane) -> ingress gateway.
set -euo pipefail

NS=istio-system
ISTIO_VERSION="1.24.1"

# Namespace + WI label so istio-ingressgateway pods can use Workload Identity later if needed.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=disabled --overwrite

# 1. CRDs
helm upgrade --install istio-base istio/base \
  --namespace "$NS" \
  --version "$ISTIO_VERSION" \
  --set defaultRevision=default \
  --wait

# 2. Control plane
helm upgrade --install istiod istio/istiod \
  --namespace "$NS" \
  --version "$ISTIO_VERSION" \
  --values ../helm-values/istiod-values.yaml \
  --wait

# 3. Ingress gateway (public LB)
helm upgrade --install istio-ingressgateway istio/gateway \
  --namespace "$NS" \
  --version "$ISTIO_VERSION" \
  --values ../helm-values/istio-ingressgateway-values.yaml \
  --wait

echo "Waiting for ingress LB external IP..."
for i in $(seq 1 60); do
  IP=$(kubectl -n "$NS" get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$IP" ] && break
  sleep 5
done

if [ -z "${IP:-}" ]; then
  echo "WARNING: ingress LB has no external IP yet. Check 'kubectl -n $NS get svc istio-ingressgateway'."
else
  echo "Istio ingress LB IP: $IP"
  echo "Once ExternalDNS is up (via Argo), it will create A records for *.reon.buzz pointing here."
fi

echo "Applying Istio Gateway + mesh-wide PeerAuthentication (STRICT mTLS)..."
kubectl apply -f ../infra-manifests/istio-peerauthentication-strict.yaml
kubectl apply -f ../infra-manifests/istio-gateway-public.yaml
kubectl apply -f ../infra-manifests/istio-telemetry.yaml

echo "Istio installed."
