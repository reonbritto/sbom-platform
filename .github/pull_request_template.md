## Summary

<!-- 1-2 sentences: what's changing in cluster state? -->

## Why

<!-- Link to related work in reon/sbom or an incident -->

## Validation

- [ ] `kubectl kustomize apps/sbom-app/overlays/dev | kubeconform -strict` passes
- [ ] `kubectl kustomize apps/sbom-app/overlays/prod | kubeconform -strict` passes
- [ ] If touching `policies/`: conftest passes
- [ ] If touching `argocd/`: dry-run validated against ArgoCD CRD schema

## Rollback

<!-- How would we revert this safely? GitOps means: revert this commit. -->

## Checklist

- [ ] Conventional Commits format on PR title
- [ ] No secrets, tokens, or `.env` values committed
- [ ] No `image: …:latest` references — pinned digest or version only
- [ ] If introducing a new resource: corresponding NetworkPolicy, ServiceAccount, RBAC are present
