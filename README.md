# sbom-platform

GitOps state and platform manifests for the [SBOM Vulnerability Analyzer](https://github.com/reonbritto/sbom-analyzer).

## What lives here

| Path | Purpose |
|---|---|
| `apps/sbom-app/base/` | Kustomize base — the canonical app manifests (Deployment, Service, HTTPRoute, ServiceAccount, etc.) |
| `apps/sbom-app/overlays/dev/` | Per-environment patches + image tag pin (Harness mutates `kustomization.yaml` here) |
| `argocd/argocd-apps.yaml` | App-of-apps root — the only Application that's manually applied; everything else fans out from here |
| `argocd/apps/sbom-app-dev.yaml` | ArgoCD `Application` CR pointing at the dev overlay |
| `infra-manifests/` | Cluster-wide platform pieces (cert-manager Issuer, Envoy Gateway, ClusterIssuer) |
| `policies/gatekeeper/` | OPA Gatekeeper ConstraintTemplates + Constraints |

## How it's mutated

Two writers are allowed:

- **Humans** (via PR + CODEOWNER review): everything except `apps/*/overlays/*/kustomization.yaml`'s `images:` block
- **`harness-bot`** (via PAT): only `apps/*/overlays/*/kustomization.yaml` `newTag` field, automatically on each release

ArgoCD watches this repo via a read-only deploy key and reconciles into the cluster.

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

# validate against schemas
kubectl kustomize apps/sbom-app/overlays/dev | kubeconform -strict -summary
```

## Bootstrap order

1. Cluster exists (minikube locally, or whatever target cluster you've provisioned)
2. Install platform components in cluster: cert-manager, Envoy Gateway, ArgoCD, Gatekeeper
3. Add this repo as a deploy key on `reonbritto/sbom-platform` (read-only)
4. `kubectl apply -f argocd/argocd-apps.yaml` — the app-of-apps takes over
5. ArgoCD reconciles `argocd/apps/sbom-app-dev.yaml` → deploys `apps/sbom-app/overlays/dev`

## License

[MIT](LICENSE)
