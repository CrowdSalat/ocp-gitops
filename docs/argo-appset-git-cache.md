# Argo CD Git Cache and ApplicationSet Reconciliation

## What happened

During the infra ApplicationSet migration, the new `ApplicationSet` was applied to the cluster immediately after the Git commit was pushed. The ApplicationSet controller reconciled within seconds but generated **0 applications**, even though the commit was already on GitHub.

The controller log showed:

```
generated 0 applications
allPaths="[... gitops/infra]"   ← subdirectories not visible yet
```

After forcing a hard refresh, the 7 expected Applications appeared instantly.

## Why

Argo CD does **not** query GitHub on every reconcile. Instead it maintains an internal git cache that is refreshed on a fixed polling interval (default: **3 minutes**). The sequence was:

```
[t=0]  git push  (new subdirectories land on GitHub)
[t=1]  oc apply infra-applicationset.yaml
[t=2]  ApplicationSet controller reconciles → reads stale cache → 0 dirs found → 0 apps
[t+3m] next scheduled cache refresh → new dirs visible → 7 apps generated
```

The cache is shared across all Applications and ApplicationSets pointing at the same repo. Its age is controlled by the `timeout.reconciliation` setting on the `argocd-cm` ConfigMap (default `180s`).

## How to force a refresh

Annotate the ApplicationSet (or a regular Application) with the hard-refresh annotation:

```bash
oc annotate applicationset <name> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

`hard` forces Argo to bypass the cache and re-clone from the remote. Use `normal` to trigger a reconcile against the existing cache without re-fetching.

For a regular `Application` the equivalent is:

```bash
oc annotate application <name> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

Or in the Argo CD UI: open the app and click **Refresh → Hard Refresh**.

## Takeaway

When applying a new `ApplicationSet` right after a `git push`, the git cache is likely stale. Either:

- Wait up to 3 minutes for the scheduled refresh, or
- Immediately annotate with `argocd.argoproj.io/refresh=hard` to skip the wait.
