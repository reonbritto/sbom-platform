# sbom-platform

GitOps state and platform manifests for the [SBOM Vulnerability Analyzer](https://github.com/reon/sbom).

## What lives here

| Path | Purpose |
|---|---|
| `apps/sbom-app/base/` | Kustomize base — the canonical app manifests (Deployment, Service, HTTPRoute, ServiceAccount, etc.) |
| `apps/sbom-app/overlays/{dev,prod}/` | Per-environment patches + image digest pin (Harness mutates `kustomization.yaml` here) |
| `argocd/argocd-apps.yaml` | App-of-apps root — the only Application that's manually applied; everything else fans out from here |
| `argocd/apps/sbom-app-{dev,prod}.yaml` | ArgoCD `Application` CRs pointing at the overlays |
| `infra-manifests/` | Cluster-wide platform pieces (cert-manager Issuer, Envoy Gateway, ClusterIssuer) |
| `policies/gatekeeper/` | OPA Gatekeeper ConstraintTemplates + Constraints |

## How it's mutated

Two writers are allowed:

- **Humans** (via PR + CODEOWNER review): everything except `apps/*/overlays/*/kustomization.yaml`'s `images:` block
- **`harness-bot`** (via PAT in Azure Key Vault): only `apps/*/overlays/*/kustomization.yaml` `newTag` field, automatically on each release

ArgoCD watches this repo via a read-only deploy key and reconciles into the AKS cluster.

## Branch protection

`main`:
- Require PR + status checks (`kustomize-validate`, `policy-test`, `lint-pr`)
- `harness-bot` is on the bypass list for `apps/*/overlays/*/kustomization.yaml` only
- Linear history, signed commits, no force-push

## Validating locally

```sh
# render base
kubectl kustomize apps/sbom-app/base | less

# render dev overlay
kubectl kustomize apps/sbom-app/overlays/dev | less

# render prod overlay
kubectl kustomize apps/sbom-app/overlays/prod | less

# validate against schemas
kubectl kustomize apps/sbom-app/overlays/dev | kubeconform -strict -summary
```

## Bootstrap order

1. AKS cluster exists (provisioned by [reon/sbom infra](https://github.com/reon/sbom/tree/main/infra))
2. Install platform components in cluster: cert-manager, Envoy Gateway, OpenObserve, Istio, ArgoCD, Gatekeeper (via `manual-install/*.sh` in the app repo)
3. Add this repo as a deploy key on `reon/sbom-platform` (read-only)
4. `kubectl apply -f argocd/argocd-apps.yaml` — the app-of-apps takes over
5. ArgoCD reconciles `argocd/apps/sbom-app-dev.yaml` → deploys `apps/sbom-app/overlays/dev`

## License

[MIT](LICENSE)
