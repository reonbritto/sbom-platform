#!/usr/bin/env bash
# Add all Helm chart repos used downstream.
# Idempotent: `helm repo add` returns success if the repo already exists.
set -euo pipefail

helm repo add jetstack          https://charts.jetstack.io
helm repo add istio             https://istio-release.storage.googleapis.com/charts
helm repo add argo              https://argoproj.github.io/argo-helm
helm repo add external-secrets  https://charts.external-secrets.io
helm repo add external-dns      https://kubernetes-sigs.github.io/external-dns/
helm repo add gatekeeper        https://open-policy-agent.github.io/gatekeeper/charts
helm repo add prometheus        https://prometheus-community.github.io/helm-charts
helm repo add grafana           https://grafana.github.io/helm-charts
helm repo add open-telemetry    https://open-telemetry.github.io/opentelemetry-helm-charts

helm repo update
echo "All Helm repos added + updated."
