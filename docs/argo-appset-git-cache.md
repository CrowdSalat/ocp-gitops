# Argo CD ApplicationSet Refresh

## How refresh works by default

Argo CD maintains an internal git cache shared across all `Application` and `ApplicationSet` resources pointing at the same repo. It does **not** query the remote on every reconcile.

Two independent timers control when the cache is updated:

| Setting | ConfigMap key | Default | What it controls |
|---|---|---|---|
| Repository polling | `timeout.reconciliation` in `argocd-cm` | `180s` | How often Argo polls the remote for new commits |
| App reconciliation | internal controller loop | `~30s` | How often each Application/ApplicationSet re-evaluates against the (possibly cached) repo |

This means a commit pushed to GitHub may not be visible to Argo for up to **3 minutes**.

## When does an ApplicationSet generate/update its Applications?

The ApplicationSet controller reconciles whenever:

1. The `ApplicationSet` resource itself changes (e.g. `oc apply`).
2. The git cache is refreshed and the controller detects a change in the matched paths.
3. A manual refresh is triggered (see below).

On each reconcile the git generator queries the cache for directories matching the configured `path` glob. If the cache is stale, new directories are invisible and fewer (or zero) Applications are generated.

## How to force a refresh

### Hard refresh (re-fetches from remote, clears cache)

```bash
oc annotate applicationset <name> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

Use this right after a `git push` when you don't want to wait for the 3-minute polling cycle.

The same annotation works on a regular `Application`:

```bash
oc annotate application <name> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Normal refresh (re-evaluates against current cache, no remote fetch)

```bash
oc annotate applicationset <name> -n openshift-gitops \
  argocd.argoproj.io/refresh=normal --overwrite
```

Useful to re-run template generation when only the `ApplicationSet` spec changed and the repo content is already up to date.

### Via the Argo CD UI

Open the Application or ApplicationSet → click **Refresh** (dropdown) → choose **Hard Refresh**.

## How to debug refresh / generation problems

### 1. Check what the git generator sees

```bash
oc logs -n openshift-gitops deployment/openshift-gitops-applicationset-controller \
  | grep "applications result from the repo service"
```

The `allPaths` field shows every directory the repo service returned. If your new subdirectories are missing, the cache is stale — force a hard refresh.

### 2. Check how many Applications were generated

```bash
oc logs -n openshift-gitops deployment/openshift-gitops-applicationset-controller \
  | grep "generated.*applications"
```

`generated 0 applications` with a non-empty path glob is the clearest sign of a stale cache.

### 3. Check the ApplicationSet status conditions

```bash
oc get applicationset <name> -n openshift-gitops -o jsonpath='{.status.conditions}' | jq .
```

| Condition type | Meaning |
|---|---|
| `ErrorOccurred: False` | No error |
| `ParametersGenerated: True` | Template parameters resolved successfully |
| `ResourcesUpToDate: True` | Generated Applications match current desired state |

### 4. Check ApplicationSet events

```bash
oc describe applicationset <name> -n openshift-gitops | grep -A 20 "Events:"
```

### 5. Check generated Application health

```bash
oc get applications -n openshift-gitops
```

`OutOfSync` + `Healthy` usually means the resource exists and runs fine but is not yet owned by Argo (field ownership diff from a previous manager). Sync with Server-Side Apply to resolve:

```bash
# In the UI: Sync → check "Server-Side Apply"
# Or patch the syncOptions in the ApplicationSet template:
syncOptions:
- ServerSideApply=true
```

## Change the default polling interval

Edit the `argocd-cm` ConfigMap in the Argo CD namespace:

```bash
oc edit configmap argocd-cm -n openshift-gitops
```

```yaml
data:
  timeout.reconciliation: 60s   # poll every 60 s instead of 180 s
```

Lower values reduce lag but increase load on the git remote. On OpenShift GitOps the operator may revert manual ConfigMap changes; check if a `GitOpsService` or `ArgoCD` CR controls this first.
