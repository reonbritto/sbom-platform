# Bootstrap

One-shot manual installs to get the cluster from "fresh AKS" to "Argo CD running, managing itself + everything else from this repo."

Run the four scripts in order. Each one is idempotent — re-running doesn't break anything.

```sh
./00-helm-repos.sh
./01-cert-manager.sh
./02-istio.sh
./03-argocd.sh
./04-app-of-apps.sh
```

## Prerequisites

Before running, you must have:

1. **Filled in placeholders** across `helm-values/` and `infra-manifests/`. Every `__PLACEHOLDER__` token must be replaced with a real value from `terraform output` in the app repo. See `../docs/bootstrap-runbook.md` for the exact mapping.
2. **`kubectl` pointed at the AKS cluster** (`az aks get-credentials --resource-group rg-sbom --name aks-sbom`).
3. **Helm 3.12+** installed.

## What each script does

| # | Script | Installs |
|---|---|---|
| 00 | `00-helm-repos.sh` | Adds Helm chart repositories. No cluster changes. |
| 01 | `01-cert-manager.sh` | cert-manager controller + CRDs in `cert-manager` ns; applies the Let's Encrypt **staging** ClusterIssuer. |
| 02 | `02-istio.sh` | `istio-base` (CRDs) + `istiod` (control plane) + `istio-ingressgateway` (public LB) in `istio-system`. |
| 03 | `03-argocd.sh` | Argo CD in `argocd` ns. Creates the Istio VirtualService + AuthorizationPolicy for `argocd.reon.buzz`. |
| 04 | `04-app-of-apps.sh` | `kubectl apply -f ../argocd/argocd-apps.yaml` — Argo CD takes over from here. |

## After step 04

Watch Argo CD sync everything:

```sh
kubectl -n argocd get applications -w
```

Expected sequence (over ~5–10 min):
1. `external-secrets-operator` syncs first (other apps need it for KV secrets)
2. `external-dns`, `gatekeeper` sync in parallel
3. `kube-prometheus-stack`, `loki`, `tempo`, `mimir`, `opentelemetry-collector`, `promtail` sync next
4. `sbom-app` syncs last

Get the Argo CD initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Login at https://argocd.reon.buzz with username `admin`. **Rotate the password immediately** via the UI.
