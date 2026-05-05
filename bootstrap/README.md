# Bootstrap (manual)

Step-by-step commands to take the cluster from "Terraform applied, kubectl wired" to "Argo CD running, managing everything else from this repo."

Every step is a copy-paste command. No shell scripts — run each one yourself, read the output, move on when it looks right.

---

## Prereqs

```sh
helm version    # need >= 3.12
kubectl version --client
kubectl config current-context     # must be: aks-sbom
kubectl get nodes                  # must show at least 1 Ready node
```

You should already have done:
- `terraform apply` (in `sbom-analyzer/infra/`)
- Substituted all `__PLACEHOLDER__` tokens in `helm-values/` and `infra-manifests/` and pushed to `sbom-platform/main`
- `git pull origin main` in this repo so you're working off the substituted values

---

## Step 1 — Add Helm chart repos

One-time. Idempotent.

```sh
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
```

Expect: `"...has been added to your repositories"` per repo, then `Update Complete. ⎈Happy Helming!⎈`.

---

## Step 2 — cert-manager

> **Note on ServiceMonitor.** cert-manager (and later ESO + ExternalDNS) can emit a `ServiceMonitor` for Prometheus scraping. That CRD is owned by kube-prometheus-stack, which installs later in step 5. To avoid a chicken-and-egg `no matches for kind "ServiceMonitor"` error on these early `helm install`s, the values files in this repo ship with `serviceMonitor.enabled: false`. After kube-prom-stack syncs in step 5, you can flip those back to `true` and `helm upgrade` to start scraping.

### 2.1 Install the chart

Run from the repo root:

```sh
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.1 \
  --values helm-values/cert-manager-values.yaml \
  --wait
```

### 2.2 Wait for the webhook

```sh
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
```

### 2.3 Apply the ClusterIssuer

(The wildcard `Certificate` lives in `istio-system`, which doesn't exist yet — applied in step 3.7.)

```sh
kubectl apply -f infra-manifests/cert-manager-clusterissuer.yaml
```

### 2.4 Verify

```sh
kubectl -n cert-manager get pods
# Expect: cert-manager, cert-manager-cainjector, cert-manager-webhook all Running

kubectl get clusterissuer
# Expect: letsencrypt-staging   READY=True
```

---

## Step 3 — Istio

Three Helm releases, in order: `base` → `istiod` → `gateway`.

### 3.1 Create the namespace

The `istio/gateway` chart relies on the sidecar-injection webhook to rewrite the
ingressgateway pod's proxy image. The pod carries `sidecar.istio.io/inject=true`
explicitly, so it gets injected regardless of namespace label. Don't set
`istio-injection=disabled` on this namespace — it'll break the gateway install
with `image "auto"` ImagePullBackOff. Other `istio-system` workloads (istiod
itself) skip injection because they don't carry the inject annotation.

```sh
kubectl create namespace istio-system
```

### 3.2 istio-base (CRDs)

```sh
helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --version 1.24.1 \
  --set defaultRevision=default \
  --wait
```

### 3.3 istiod (control plane)

```sh
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version 1.24.1 \
  --values helm-values/istiod-values.yaml \
  --wait
```

### 3.4 istio-ingressgateway (public LB)

```sh
helm upgrade --install istio-ingressgateway istio/gateway \
  --namespace istio-system \
  --version 1.24.1 \
  --values helm-values/istio-ingressgateway-values.yaml \
  --wait
```

### 3.5 Wait for the LoadBalancer external IP

```sh
kubectl -n istio-system get svc istio-ingressgateway -w
# Wait until EXTERNAL-IP shows an actual IP (not <pending>). Ctrl-C when it appears.
# Note the IP — ExternalDNS will write it into reon.buzz A records.
```

### 3.6 Apply the Gateway + mTLS + Telemetry CRs + wildcard Certificate

```sh
kubectl apply -f infra-manifests/istio-peerauthentication-strict.yaml
kubectl apply -f infra-manifests/istio-gateway-public.yaml
kubectl apply -f infra-manifests/istio-telemetry.yaml
kubectl apply -f infra-manifests/reon-buzz-wildcard-cert.yaml
```

### 3.7 Verify

```sh
kubectl -n istio-system get pods
# Expect: istiod-*, istio-ingressgateway-* all Running

kubectl -n istio-system get gateway public-gateway
kubectl -n istio-system get peerauthentication default
kubectl -n istio-system get telemetry mesh-default

kubectl -n istio-system get certificate reon-buzz-wildcard
# READY will flip to True once cert-manager completes the DNS-01 challenge
# (creates a TXT record under reon.buzz, waits for Let's Encrypt to verify).
# Takes 30–120 seconds. If it stays False past 5 min, see the failure-modes table.
```

---

## Step 4 — Argo CD

### 4.1 Create the namespace

Don't enable Istio injection on `argocd`. Argo CD ships a pre-install Helm hook
Job (`argocd-redis-secret-init`) — if it gets an Istio sidecar, the main
container exits but `istio-proxy` keeps running, so the Job never reaches
`Completed` and `helm install --wait` times out. Argo CD doesn't need mesh
mTLS for its own components anyway (it talks to the K8s API and to Git).

```sh
kubectl create namespace argocd
```

### 4.2 Install

```sh
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.7.10 \
  --values helm-values/argocd-values.yaml \
  --wait
```

### 4.3 Wait for the server

```sh
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
```

### 4.4 Expose the UI via Istio + IP allowlist

```sh
kubectl apply -f ingress/argocd-virtualservice.yaml
kubectl apply -f ingress/argocd-authorizationpolicy.yaml
```

### 4.5 Get the initial admin password

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Save it somewhere. Login at https://argocd.reon.buzz with username `admin` once DNS + cert are ready (see step 6 verify). **Rotate the password via the UI immediately after first login.**

### 4.6 Verify

```sh
kubectl -n argocd get pods
# Expect: argocd-application-controller, argocd-server, argocd-repo-server,
#         argocd-applicationset-controller, argocd-notifications-controller,
#         argocd-redis, argocd-dex-server (if enabled) — all Running
```

`argocd.reon.buzz` won't resolve yet — ExternalDNS isn't installed (it syncs in
step 5 wave -80). To eyeball Argo CD before then, port-forward:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:80
# Open http://localhost:8080
# Login: admin / <password from step 4.5>
```

You can also just proceed to step 5 — the public URL starts working ~2 min after
ExternalDNS syncs.

---

## Step 5 — Hand off to Argo CD (app-of-apps)

This is the GitOps takeover. After this command, Argo CD reads from `sbom-platform/main` and installs everything else.

```sh
kubectl apply -f argocd/argocd-apps.yaml
```

### 5.1 Watch sync progress

```sh
kubectl -n argocd get applications -w
```

Press Ctrl-C when you've seen everything you want. Expected order over ~10 minutes (sync waves baked into each Application):

| Wave | Apps |
|---|---|
| -100 | cert-manager (already installed manually — Argo just adopts it) |
| -90  | external-secrets |
| -80  | external-dns |
| -70  | gatekeeper |
| -60  | gatekeeper-policies |
| -50  | platform-services (ClusterIssuer + Istio CRs + ESO ClusterSecretStore) |
| -40  | kube-prometheus-stack |
| -35  | loki |
| -30  | tempo, mimir |
| -25  | opentelemetry-collector |
| -20  | promtail |
| -15  | observability-config (ESO ExternalSecrets + Grafana datasources) |
| -10  | ingress (per-host VirtualServices + AuthorizationPolicies) |
| 0    | sbom-app-dev |

A green `Synced + Healthy` per app is the happy path.

---

## Step 6 — Verify

### 6.1 Cert + DNS

```sh
# Wildcard cert should now be Ready
kubectl -n istio-system get certificate reon-buzz-wildcard
# Expect: READY=True

# DNS records published by ExternalDNS
az network dns record-set list -g sa -z reon.buzz -o table | grep -i ' A '
# Expect rows for reon.buzz, argocd.reon.buzz, grafana.reon.buzz, prometheus.reon.buzz
```

DNS propagation can take a minute. Test:

```sh
nslookup argocd.reon.buzz
```

### 6.2 Argo CD UI

Open https://argocd.reon.buzz from `37.60.98.75` only (other IPs get blocked by the AuthorizationPolicy — by design).

Login `admin` / password from step 4.5. **Rotate the password.**

### 6.3 Grafana

Open https://grafana.reon.buzz from `37.60.98.75`. Login `admin` / value of `terraform output -raw grafana_admin_password` (from `sbom-analyzer/infra`).

In Explore:
- **Mimir** datasource → query `up` → ~30 series
- **Loki** → `{namespace="argocd"}` → Argo CD pod logs
- **Tempo** → search by service `istio-ingressgateway` → traces

### 6.4 Workload Identity sanity (storage writes actually working?)

```sh
# Pick a Loki pod
POD=$(kubectl -n observability get pod -l app.kubernetes.io/name=loki -o jsonpath='{.items[0].metadata.name}')
kubectl -n observability exec "$POD" -- ls /var/run/secrets/azure/tokens/azure-identity-token
# Token file exists = WI webhook fired = pod label correct

# Confirm storage write actually worked
SA=$(cd ../sbom-analyzer/infra && terraform output -raw observability_storage_account_name)
az storage blob list --account-name "$SA" --container-name loki --auth-mode login -o table | head
# Expect blobs (or "no blobs" if Loki started <30s ago — wait + retry)
```

If the projected token file is missing, the chart's `podLabels.azure.workload.identity/use: "true"` didn't propagate. Rollout-restart the deployment.

---

## Re-running steps (idempotency)

| Step | Idempotent? | What re-running does |
|---|---|---|
| 1 (helm repo add) | yes | no-op if already added |
| 2.1, 3.2-3.4, 4.2 (helm upgrade --install) | yes | re-applies values, no-op if no diff |
| 2.3, 3.6, 4.4 (kubectl apply -f) | yes | server-side apply, no diff = no-op |
| 4.5 (get password) | once-only | the secret is deleted after Argo's first reconcile loop. If you've lost the password, change it via `argocd account update-password`. |
| 5 (kubectl apply argocd-apps.yaml) | yes | Argo will re-adopt anything missing |

---

## Common failure modes

| Symptom | Most likely cause | First check |
|---|---|---|
| `helm install` errors with `no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"` | The chart's values try to create a ServiceMonitor before the kube-prometheus-stack CRDs exist | Set `serviceMonitor.enabled: false` (or `prometheus.servicemonitor.enabled: false` for cert-manager) in that chart's values file. Re-enable later, after kube-prom-stack syncs in step 5. cert-manager / ESO / ExternalDNS already pre-disabled in this repo for that reason. |
| `kubectl apply` of ClusterIssuer fails with `managed identity can not be used at the same time as clientID, clientSecretSecretRef or tenantID` | cert-manager's webhook enforces mutually-exclusive auth modes for `azureDNS` solvers | When using `managedIdentity.clientID`, do NOT also set `tenantID`/`clientID`/`clientSecretSecretRef` under `azureDNS`. Already pre-fixed in `infra-manifests/cert-manager-clusterissuer.yaml`. |
| `kubectl apply` of `reon-buzz-wildcard-cert.yaml` fails with `namespaces "istio-system" not found` | Order-of-apply: the Certificate targets `istio-system`, which is created in step 3.1 | Apply in step 3.6, not step 2. The runbook reflects this; if you ran step 2.3 from an older revision, just re-run after step 3.1. |
| `helm upgrade istio-ingressgateway` errors with `context deadline exceeded`, and pods are `ImagePullBackOff` for image `auto` | The `istio/gateway` chart writes `image: auto` as a sentinel meant to be rewritten by the sidecar-injection webhook. If the webhook doesn't fire on the pod, the literal string `auto` ends up in the Deployment and kubelet tries to pull `docker.io/library/auto:latest`. | Don't set `istio-injection=disabled` on the `istio-system` namespace. The gateway pod has `sidecar.istio.io/inject=true` and gets injected via that annotation regardless of namespace label. Then force a fresh pod: `kubectl -n istio-system rollout restart deploy/istio-ingressgateway`. |
| Challenge `pending` with `AADSTS700213: No matching federated identity record found for presented assertion subject 'system:serviceaccount:cert-manager:cert-manager'` | The ExternalDNS MI's federated credential is bound to `external-dns/external-dns-sa`, but cert-manager's pod runs as `cert-manager/cert-manager`. AAD rejects the token swap. | Add a second `azurerm_federated_identity_credential` on `id-sbom-external-dns` with subject `system:serviceaccount:cert-manager:cert-manager`. Already added in `infra/main.tf` — `terraform apply` to create it. Then `kubectl -n istio-system delete order --all` to force a fresh challenge cycle (cert-manager auto-recreates within seconds). |
| Challenge `pending` with `Waiting for DNS-01 challenge propagation: DNS record for "reon.buzz" not yet propagated` | TXT record was successfully written to Azure DNS, but cert-manager's internal propagation check hasn't seen it yet. Normal — public resolvers need a few seconds to converge. | Wait. cert-manager retries every ~10s. Confirm the record is live: `az network dns record-set txt list -g sa -z reon.buzz -o table` (should show `_acme-challenge`) and `nslookup -type=TXT _acme-challenge.reon.buzz 8.8.8.8`. If both look good but >5 min has passed, `kubectl -n istio-system delete order --all` to retrigger. |
| `cert-manager` Certificate stuck `Ready=False` >5 min for some other reason | DNS-01 challenge generic failure — could be RBAC, zone delegation, or transient ACME error | `kubectl -n istio-system describe challenge` — check the `Reason` field. `kubectl -n cert-manager logs -l app=cert-manager` for full context. Verify external_dns MI still has `DNS Zone Contributor` on `reon.buzz` via `az role assignment list`. |
| Loki/Tempo/Mimir Pod `CrashLoopBackOff` with `unauthorized` from blob | WI token not mounted | `kubectl exec ... -- env | grep AZURE_` — should show client+tenant ID. If empty, pod label `azure.workload.identity/use: "true"` is missing. |
| `argocd.reon.buzz` returns connection refused | DNS not propagated, or LB external IP not assigned | `kubectl -n istio-system get svc istio-ingressgateway` — check EXTERNAL-IP. `nslookup argocd.reon.buzz`. |
| `argocd.reon.buzz` returns `DNS_PROBE_FINISHED_NXDOMAIN` after step 4 | Expected at this point. ExternalDNS is wave -80 in step 5; the A record doesn't exist yet. | Either run step 5 now (the natural next step) or port-forward to eyeball Argo: `kubectl -n argocd port-forward svc/argocd-server 8080:80` then http://localhost:8080. |
| Argo CD Application stuck `OutOfSync` with `manifest generation failed` | Helm chart version no longer exists on chart repo | Check `argocd/apps/<name>.yaml` `targetRevision`; bump to a current version. |
| Gatekeeper rejects pod with `disallowed image registry` | New component's registry not in allowlist | Edit `policies/gatekeeper/constraints/allowed-registries-cluster.yaml`, add registry, push. Argo will sync. |
| Grafana login fails with bad credentials | `grafana-admin` Secret didn't sync from KV | `kubectl -n observability get externalsecret grafana-admin -o yaml` — look at status. Most likely: ESO MI federated credential subject doesn't match the actual SA. |
| `helm install argocd` errors with `failed pre-install: timed out waiting for the condition`, and `argocd-redis-secret-init` Job pod is `1/2 NotReady` | Argo CD's pre-install Job has an Istio sidecar injected. The main `secret-init` container exits, but `istio-proxy` keeps running, so the Job never reports Completed. Helm gives up at the timeout. | Don't enable `istio-injection=enabled` on the `argocd` namespace. Recover: `kubectl label ns argocd istio-injection-` to remove the label, then `kubectl -n argocd delete job argocd-redis-secret-init`, then re-run `helm install`. |

---

## Rollback / teardown

### Stop everything but keep the cluster

```sh
kubectl delete -f argocd/argocd-apps.yaml
helm uninstall argocd -n argocd
helm uninstall istio-ingressgateway istiod istio-base -n istio-system
helm uninstall cert-manager -n cert-manager
```

### Burn everything down (cluster + Azure infra)

```sh
cd ../sbom-analyzer/infra
terraform destroy
```
