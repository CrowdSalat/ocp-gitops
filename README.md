# OpenShift GitOps Repository

GitOps repository for OpenShift manifests using ArgoCD and ApplicationSets.


## Structure

```
├── bootstrap/          # ArgoCD setup and ApplicationSets
├── applications/       # Individual applications
```

## Quick Start

1. **Bootstrap GitOps:**
   ```bash
   oc apply -f bootstrap/
   ```

## How It Works

- **ApplicationSet** scans `applications/` directory
- **Creates ArgoCD Applications** for each discovered app
- **Each app gets its own namespace** based on directory name (app-*)

## Template Variables

- `{{path.basename}}` = application name (e.g., "my-app")
- `{{path}}` = full path (e.g., "applications/my-app")


## Documentation

- [Operator updates via GitOps](docs/operator-updates-gitops.md) — OLM subscriptions, channels, and install-plan approval as represented in this repository
- [Argo CD Operation Model](docs/argo-operation-model.md) — tenancy, scaling, and separation patterns for Argo CD on OpenShift
