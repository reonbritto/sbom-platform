# Bootstrap (manual)

Linear, copy-paste install order. Every infra-tier component is installed manually with `helm install` or `kubectl apply`. After Argo CD is up, it manages the application-tier components (kube-prometheus-stack, Loki, Tempo, Mimir, OTel collector, Promtail, sbom-app, ingress) from this repo.

## Layered model

| Layer | Components | How |
|---|---|---|
| **Infra (manual)** | cert-manager, Istio, ExternalDNS, External Secrets Operator, Gatekeeper, Argo CD | `helm install` + `kubectl apply` in this runbook |
| **Application (GitOps)** | kube-prometheus-stack, Loki, Tempo, Mimir, OTel collector, Promtail, sbom-app, per-host VirtualServices/AuthorizationPolicies | `kubectl apply -f argocd/argocd-apps.yaml` — Argo CD takes over |

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
- `git pull origin main` so you're working off the substituted values

---

## Step 1 — Add Helm chart repos

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

```sh
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.1 \
  --values helm-values/cert-manager-values.yaml \
  --wait

kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
```

Apply the Let's Encrypt staging ClusterIssuer (DNS-01 against Azure DNS, reuses the ExternalDNS managed identity):

```sh
kubectl apply -f infra-manifests/cert-manager-clusterissuer.yaml

kubectl get clusterissuer
# READY=True for letsencrypt-staging
```

The wildcard `Certificate` waits until step 3 (needs the `istio-system` namespace).

---

## Step 3 — Istio

`istio-base` (CRDs) → `istiod` (control plane) → `istio-ingressgateway` (public LB).

```sh
kubectl create namespace istio-system
# Do NOT label istio-system with istio-injection=disabled — the gateway pod
# uses the sidecar webhook to rewrite its own proxy image. Other workloads in
# this namespace (istiod) skip injection because they don't carry the
# `sidecar.istio.io/inject=true` annotation.

helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --version 1.24.1 \
  --set defaultRevision=default \
  --wait

helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version 1.24.1 \
  --values helm-values/istiod-values.yaml \
  --wait

helm upgrade --install istio-ingressgateway istio/gateway \
  --namespace istio-system \
  --version 1.24.1 \
  --values helm-values/istio-ingressgateway-values.yaml \
  --wait
```

Wait for the LoadBalancer external IP:

```sh
kubectl -n istio-system get svc istio-ingressgateway -w
# Wait until EXTERNAL-IP shows an actual IP (not <pending>). Note the IP — it
# becomes the target of every reon.buzz A record. Ctrl-C when it appears.
```

Apply the Gateway + mesh-wide mTLS + telemetry CRs and the wildcard cert:

```sh
kubectl apply -f infra-manifests/istio-peerauthentication-strict.yaml
kubectl apply -f infra-manifests/istio-gateway-public.yaml
kubectl apply -f infra-manifests/istio-telemetry.yaml
kubectl apply -f infra-manifests/reon-buzz-wildcard-cert.yaml
```

Verify:

```sh
kubectl -n istio-system get pods
# istiod-*, istio-ingressgateway-* — all 1/1 Running

kubectl -n istio-system get gateway public-gateway
kubectl -n istio-system get peerauthentication default
kubectl -n istio-system get telemetry mesh-default
kubectl -n istio-system get certificate reon-buzz-wildcard
# READY flips True after cert-manager completes the DNS-01 challenge
# (writes _acme-challenge TXT record, waits for LE to verify). 30–120s.
```

---

## Step 4 — ExternalDNS

```sh
helm upgrade --install external-dns external-dns/external-dns \
  --namespace external-dns \
  --create-namespace \
  --version 1.15.0 \
  --values helm-values/external-dns-values.yaml \
  --wait
```

Verify the pod's Workload Identity is wired and the controller picks up the Istio Gateway:

```sh
kubectl -n external-dns get pods
# external-dns-* — 1/1 Running

kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=20
# Expected within ~60s:
#   "Desired change: CREATE argocd.reon.buzz A [<istio-LB-IP>]"
#   "Desired change: CREATE grafana.reon.buzz A [<istio-LB-IP>]"
#   ... and so on for every VirtualService host
```

Confirm A records are live in Azure DNS:

```sh
az network dns record-set list -g sa -z reon.buzz -o table | grep -i ' A '
# Expect rows for argocd, grafana, prometheus, etc. — but only AFTER step 5
# applies the per-host VirtualServices via Argo CD. For now, ExternalDNS sees
# only the Gateway's hosts (`reon.buzz`, `*.reon.buzz`) and may write a single
# A record at the apex.
```

> [!NOTE]
> **Re-deployment cleanup.** If A records already exist from a previous teardown (pointing to an old Istio LB IP), ExternalDNS logs `"All records are already up to date"` and won't update them. Wipe the stale records and TXT ownership entries first:
>
> ```sh
> # A records
> for host in "@" argocd grafana prometheus loki tempo; do
>   az network dns record-set a delete \
>     --name "$host" --zone-name reon.buzz --resource-group sa --yes 2>/dev/null
> done
>
> # TXT ownership records (ExternalDNS uses these to track what it owns)
> for host in reon.buzz argocd.reon.buzz grafana.reon.buzz prometheus.reon.buzz loki.reon.buzz tempo.reon.buzz; do
>   az network dns record-set txt delete \
>     --name "extdns-$host" --zone-name reon.buzz --resource-group sa --yes 2>/dev/null
> done
>
> kubectl rollout restart deployment/external-dns -n external-dns
> kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=20 -f
> # Expected: "Desired change: CREATE <host> A <NEW_LB_IP>"
> ```

---

## Step 5 — External Secrets Operator

```sh
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 0.10.5 \
  --values helm-values/external-secrets-values.yaml \
  --wait
```

Apply the cluster-scoped store that points at Azure Key Vault:

```sh
kubectl apply -f infra-manifests/eso-clustersecretstore.yaml

kubectl get clustersecretstore azure-kv
# Expect: STATUS=Valid, READY=True
# (Takes ~10s for the controller to validate the WI federation against AAD.)
```

If `READY=False`, check:

```sh
kubectl describe clustersecretstore azure-kv
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=30
```

Most common cause: federated credential subject doesn't match the actual SA. Should be `system:serviceaccount:external-secrets:eso-service-account`.

---

## Step 6 — Gatekeeper

```sh
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --version 3.17.1 \
  --values helm-values/gatekeeper-values.yaml \
  --wait
```

Apply the constraint templates and constraints:

```sh
kubectl apply -f policies/gatekeeper/templates/
kubectl apply -f policies/gatekeeper/constraints/
```

Verify:

```sh
kubectl get constrainttemplate
# K8sRequiredLabels, K8sAllowedRepos, K8sNoPrivileged

kubectl get constraints -A
# All constraints listed, ENFORCEMENT=deny
```

> [!NOTE]
> Constraint syncing can lag the constraint object by a few seconds. If the next workload install (Argo CD or anything in step 8) gets denied for an unrelated-looking reason, `kubectl get constraint <name> -o yaml` and look at `status.byPod[].observedGeneration` — should match `metadata.generation`.

---

## Step 7 — Argo CD

```sh
kubectl create namespace argocd
# Do NOT enable istio-injection on this namespace — the chart's pre-install Job
# (argocd-redis-secret-init) gets blocked by the istio-proxy sidecar. Argo CD
# doesn't need mesh mTLS for itself; it talks to the K8s API and to Git.

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.7.10 \
  --values helm-values/argocd-values.yaml \
  --wait

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
```

Expose the UI via Istio (publicly — no IP allowlist):

```sh
kubectl apply -f ingress/argocd-virtualservice.yaml
```

Get the initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Save it. Login at `https://argocd.reon.buzz` once DNS + cert finish propagating. Username `admin`. **Rotate immediately via the UI** — the UI is public.

If `argocd.reon.buzz` doesn't resolve yet:
- ExternalDNS may not have written the per-host A record yet (it writes one once Argo CD applies the per-host VirtualServices in step 8). Until then, only `reon.buzz` apex resolves.
- Port-forward as a fallback: `kubectl -n argocd port-forward svc/argocd-server 8080:80` → http://localhost:8080.

Verify:

```sh
kubectl -n argocd get pods
# argocd-application-controller, argocd-server, argocd-repo-server,
# argocd-applicationset-controller, argocd-notifications-controller,
# argocd-redis — all 1/1 Running
```

---

## Step 8 — Hand off to Argo CD (app-of-apps)

This is the GitOps takeover. After this command, Argo CD reads from `sbom-platform/main` and installs everything in the application tier (kube-prometheus-stack, Loki, Tempo, Mimir, OTel collector, Promtail, observability config, per-host VirtualServices, sbom-app).

```sh
kubectl apply -f argocd/argocd-apps.yaml
```

Watch sync progress:

```sh
kubectl -n argocd get applications -w
```

Press Ctrl-C when you've seen what you want. Expected order (sync waves):

| Wave | App |
|---|---|
| -60  | gatekeeper-policies (templates + constraints) |
| -40  | kube-prometheus-stack |
| -35  | loki |
| -30  | tempo, mimir |
| -25  | opentelemetry-collector |
| -20  | promtail |
| -15  | observability-config (ESO ExternalSecrets + Grafana datasources) |
| -10  | ingress (per-host VirtualServices + AuthorizationPolicies) |
| 0    | sbom-app-dev |

A green `Synced + Healthy` per app is the happy path.

Once `ingress` syncs, ExternalDNS picks up each per-host VirtualService and writes A records for `argocd.reon.buzz`, `grafana.reon.buzz`, `prometheus.reon.buzz`, `loki.reon.buzz`, `tempo.reon.buzz` (~30–60s after sync).

---

## Step 9 — Verify

### Cert + DNS

```sh
kubectl -n istio-system get certificate reon-buzz-wildcard
# READY=True

az network dns record-set list -g sa -z reon.buzz -o table | grep -i ' A '
# Rows for: @ (apex), argocd, grafana, prometheus, loki, tempo

nslookup argocd.reon.buzz
nslookup grafana.reon.buzz
```

### Argo CD UI

Open `https://argocd.reon.buzz`. Login `admin` / step-7 password. **Rotate the password.**

### Grafana

Open `https://grafana.reon.buzz`. Login `admin` / `terraform output -raw grafana_admin_password`.

In Explore:
- **Mimir** datasource → query `up` → ~30 series
- **Loki** → `{namespace="argocd"}` → Argo CD pod logs
- **Tempo** → search by service `istio-ingressgateway` → traces

### Workload Identity sanity (storage writes actually working?)

```sh
POD=$(kubectl -n observability get pod -l app.kubernetes.io/name=loki -o jsonpath='{.items[0].metadata.name}')
kubectl -n observability exec "$POD" -- ls /var/run/secrets/azure/tokens/azure-identity-token
# File exists = WI webhook fired = pod label correct

SA=$(cd ../sbom-analyzer/infra && terraform output -raw observability_storage_account_name)
az storage blob list --account-name "$SA" --container-name loki --auth-mode login -o table | head
# Expect blobs (or "no blobs" if Loki started <30s ago — wait + retry)
```

---

## Re-running steps (idempotency)

| Step | Idempotent? | What re-running does |
|---|---|---|
| 1 (helm repo add) | yes | no-op if already added |
| 2, 3, 4, 5, 6, 7 (helm upgrade --install) | yes | re-applies values, no-op if no diff |
| 2.kubectl apply, 3.kubectl apply, 4 cleanup, 5.apply, 6.apply, 7.apply | yes | server-side apply, no diff = no-op |
| 7 admin password fetch | once-only | the secret is auto-deleted after Argo's first reconcile loop. Lost? `argocd account update-password`. |
| 8 (argocd-apps.yaml) | yes | Argo re-adopts anything missing |

---

## Common failure modes

| Symptom | Most likely cause | First check |
|---|---|---|
| `helm install` errors with `no matches for kind "ServiceMonitor"` | The chart's values try to create a ServiceMonitor before kube-prometheus-stack CRDs exist | Set `serviceMonitor.enabled: false` in that chart's values. cert-manager / ESO / ExternalDNS already pre-disabled. Re-enable via `helm upgrade` after step 8 syncs kube-prom-stack. |
| `kubectl apply` of ClusterIssuer fails with `managed identity can not be used at the same time as clientID, clientSecretSecretRef or tenantID` | cert-manager webhook enforces mutually-exclusive auth modes for `azureDNS` solvers | When using `managedIdentity.clientID`, do NOT also set `tenantID`/`clientID`/`clientSecretSecretRef`. Already pre-fixed in `infra-manifests/cert-manager-clusterissuer.yaml`. |
| `kubectl apply` of `reon-buzz-wildcard-cert.yaml` fails with `namespaces "istio-system" not found` | Order: the Certificate targets `istio-system`, which is created in step 3 | Apply in step 3, not step 2. |
| `helm upgrade istio-ingressgateway` errors with `context deadline exceeded`, pods `ImagePullBackOff` for image `auto` | The chart writes `image: auto` as a sentinel for the sidecar-injection webhook to rewrite. Webhook didn't fire on the pod. | Don't set `istio-injection=disabled` on `istio-system`. The pod has `sidecar.istio.io/inject=true` and gets injected via that annotation. Force a fresh pod: `kubectl -n istio-system rollout restart deploy/istio-ingressgateway`. |
| Challenge `pending` with `AADSTS700213: No matching federated identity record found for presented assertion subject 'system:serviceaccount:cert-manager:cert-manager'` | The ExternalDNS MI's federated cred is bound to `external-dns/external-dns-sa`; cert-manager's pod runs as a different SA. AAD rejects. | A second `azurerm_federated_identity_credential` on `id-sbom-external-dns` with subject `system:serviceaccount:cert-manager:cert-manager` is in `infra/main.tf`. `terraform apply`. Then `kubectl -n istio-system delete order --all`. |
| Challenge `pending` with `Waiting for DNS-01 challenge propagation: DNS record for "reon.buzz" not yet propagated` | TXT record was written to Azure DNS, but cert-manager's internal propagation check hasn't seen it yet. Normal — public resolvers need a few seconds. | Wait. Confirm: `az network dns record-set txt list -g sa -z reon.buzz -o table` and `nslookup -type=TXT _acme-challenge.reon.buzz 8.8.8.8`. If both look good but >5 min, `kubectl -n istio-system delete order --all` to retrigger. |
| ExternalDNS pod `CrashLoopBackOff` with `failed to read Azure config file '/etc/kubernetes/azure.json'` | The chart's top-level `azure:` block doesn't mount the file — only `secretConfiguration.enabled: true` does. | Use `secretConfiguration` in `helm-values/external-dns-values.yaml` (already pre-set). Re-run `helm upgrade --install`. |
| `helm upgrade ... Error: another operation (install/upgrade/rollback) is in progress` | A previous `helm install --wait` was killed (timeout, Ctrl-C, or pod failure) before Helm could finalize the release. It's stuck in `pending-install`. | `helm -n <ns> list -a` confirms the `pending-*` status. Then `helm -n <ns> uninstall <release>` and re-run `helm upgrade --install`. |
| ExternalDNS logs `"All records are already up to date"` but DNS isn't right | Stale A + TXT records from a previous deployment | Run the cleanup block in the step-4 NOTE callout. |
| ESO `ClusterSecretStore.READY=False` with `AADSTS700213: No matching federated identity record found for presented assertion subject 'system:serviceaccount:external-secrets:eso-service-account'` | The ESO MI's federated credential subject was bound to a different namespace (e.g. `sbom`) than where ESO actually runs (`external-secrets`). AAD rejects. | Fix the FIC subject in `infra/main.tf` to `system:serviceaccount:external-secrets:eso-service-account`. Already fixed. `terraform apply`, then ESO retries automatically within ~60s. |
| ESO `ClusterSecretStore.READY=False` with `multiple tenantID found. Check secretRef, 'spec.provider.azurekv.tenantId', and serviceAccountRef` | The store sets `spec.provider.azurekv.tenantId` AND the linked SA has `azure.workload.identity/tenant-id` annotation. ESO refuses ambiguity. | Pick one source. Removed `tenantId` from `infra-manifests/eso-clustersecretstore.yaml`; SA annotation stays. |
| `kubectl apply` of ESO manifests fails with `no matches for kind "ClusterSecretStore" in version "external-secrets.io/v1"` | ESO chart 0.10.x ships only `v1alpha1` + `v1beta1`. The `v1` GA bump landed in chart 0.18+. | Use `apiVersion: external-secrets.io/v1beta1` in all ESO manifests (`ClusterSecretStore` + every `ExternalSecret`). Already pre-fixed. |
| `helm install argocd` errors with `failed pre-install: timed out waiting for the condition`, `argocd-redis-secret-init` Job pod is `1/2 NotReady` | Argo CD's pre-install Job has an Istio sidecar injected. Main container exits, `istio-proxy` keeps running, Job never reports Completed. | Don't enable `istio-injection=enabled` on the `argocd` namespace. Recover: `kubectl label ns argocd istio-injection-`, `kubectl -n argocd delete job argocd-redis-secret-init`, re-run helm. |
| `argocd.reon.buzz` returns `DNS_PROBE_FINISHED_NXDOMAIN` after step 7 | Per-host VirtualService not synced yet (it lands in step 8 wave -10), so ExternalDNS hasn't written the A record | Run step 8. Or port-forward: `kubectl -n argocd port-forward svc/argocd-server 8080:80`. |
| Loki/Tempo/Mimir Pod `CrashLoopBackOff` with `unauthorized` from blob | WI token not mounted | `kubectl exec ... -- env | grep AZURE_` — should show client+tenant ID. If empty, pod label `azure.workload.identity/use: "true"` is missing. |
| Argo CD Application stuck `OutOfSync` with `manifest generation failed` | Helm chart version no longer exists on chart repo | Bump `targetRevision` in `argocd/apps/<name>.yaml`. |
| Gatekeeper rejects pod with `disallowed image registry` | New component's registry not in allowlist | Edit `policies/gatekeeper/constraints/allowed-registries-cluster.yaml`, add registry, push. Argo syncs. |
| Grafana login fails with bad credentials | `grafana-admin` Secret didn't sync from KV | `kubectl -n observability get externalsecret grafana-admin -o yaml` — look at status. |
| Argo CD UI shows `RBAC: access denied` after successful login | The Argo CD chart writes `policy.default: ""` into `argocd-rbac-cm` regardless of whether you set the `rbac:` block. With no default policy and no matching group binding, the local `admin` user has no permissions. | In `helm-values/argocd-values.yaml`, set `configs.rbac.policy.default: role:admin` explicitly (or `role:readonly` + a `g, admin, role:admin` CSV binding for tighter control). `helm upgrade --install argocd ...` then `kubectl -n argocd rollout restart deploy/argocd-server`. |

---

## Rollback / teardown

### Stop everything but keep the cluster

```sh
kubectl delete -f argocd/argocd-apps.yaml
helm uninstall argocd -n argocd
helm uninstall gatekeeper -n gatekeeper-system
helm uninstall external-secrets -n external-secrets
helm uninstall external-dns -n external-dns
helm uninstall istio-ingressgateway istiod istio-base -n istio-system
helm uninstall cert-manager -n cert-manager
```

### Burn everything down (cluster + Azure infra)

```sh
cd ../sbom-analyzer/infra
terraform destroy
```
