# OpenShift GitOps Repository

GitOps repository for OpenShift manifests using ArgoCD and ApplicationSets.

## Structure

```
├── bootstrap/          # ArgoCD setup and ApplicationSets
├── applications/       # Individual applications
```

## Quick Start

1. **Bootstrap ArgoCD:**
   ```bash
   oc apply bootstrap/
   ```

## How It Works

- **ApplicationSet** scans `applications/` directory
- **Creates ArgoCD Applications** for each discovered app
- **Each app gets its own namespace** based on directory name (app-*)

## Template Variables

- `{{path.basename}}` = application name (e.g., "my-app")
- `{{path}}` = full path (e.g., "applications/my-app")

## Repository URL

Currently configured for: `git@github.com:CrowdSalat/ocp-gitops.git`
