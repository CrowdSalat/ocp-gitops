# Console terminal (`oc` in the browser)

The **Web Terminal Operator** adds a "Cloud Shell" tab to the OpenShift console. It runs a
`DevWorkspace` with `oc`, `kubectl`, `helm` and friends, pre-authenticated as the logged-in
user — no local `oc` install needed.

Managed by the `infra` ApplicationSet:

| Directory | Application | Content |
|---|---|---|
| `gitops/infra/web-terminal/` | `infra-web-terminal` | `web-terminal` Subscription |
| `gitops/infra/devworkspace/` | `infra-devworkspace` | `devworkspace-operator` Subscription |

Both live in `openshift-operators`, the vendor-default namespace. The Web Terminal operator
has no CR of its own; on install it creates the `DevWorkspaceTemplate`s
`web-terminal-tooling` and `web-terminal-exec` in its namespace. The console then creates a
`DevWorkspace` per terminal session in the user's current project.

## Why the DevWorkspace operator is declared explicitly

The `web-terminal` CSV has a *required API* dependency on `devworkspaces` /
`devworkspaceroutings`. When no subscription for `devworkspace-operator` exists in the target
namespace, OLM resolves that by scheduling the `devworkspace-operator` CSV into the **same**
InstallPlan. Pinning the subscription in Git makes the placement explicit instead of relying
on an OLM-generated dependency subscription (which is what used to exist in
`openshift-devspaces`).

Dev Spaces keeps working with the operator in `openshift-operators`: it only needs the
cluster-wide CRDs and the all-namespaces controller. Its `DevWorkspaceOperatorConfig` stays
owned by the `CheCluster` in `openshift-devspaces`.

## Gotchas (verified on this cluster)

- **A pending Manual plan in the target namespace blocks everything.** OLM batches all
  subscriptions of one OperatorGroup into a single InstallPlan. While `servicemeshoperator3`
  was `installPlanApproval: Manual` with an upgrade pending, every new subscription in
  `openshift-operators` produced a plan that also contained the Service Mesh upgrade and sat
  at `RequiresApproval`. It must be `Automatic` (or pinned to an installed channel) before
  adding operators here.
- **OLM copies CSVs to every namespace.** A CSV with `status.reason: Copied` is inert — no
  deployment is created for it. A subscription can resolve to such a stale copy (the copy
  carries `olm.operatorNamespace` of wherever the operator was originally installed), which
  looks like "installed" while nothing runs. Deleting the subscription *and* the stale CSV
  copies, then re-creating the subscription, forces a real install.
- **Never delete a Subscription by hand while Argo manages it.** The `infra` ApplicationSet
  runs `selfHeal: true`; Argo re-creates the manifest within seconds. Change Git first, or
  turn auto-sync off for the app during the operation.

## Verification

```shell
oc get sub web-terminal devworkspace-operator -n openshift-operators
oc get csv -n openshift-operators | grep -E 'web-terminal|devworkspace'
oc get dwt -n openshift-operators          # web-terminal-tooling, web-terminal-exec
```

The console backend picks the namespace up at runtime (`/api/terminal/installedNamespace`),
so no console restart is needed.

End-to-end check — create the same `DevWorkspace` the console would, watch it reach `Running`,
then delete it:

```shell
oc get dw -A                       # PHASE Running, URL on the internal service
oc exec -n <ns> <terminal-pod> -c web-terminal-tooling -- oc version
```

Terminal sessions are runtime state: never commit a `DevWorkspace` for this. The
`/api/terminal/available` endpoint returning `204` means the console found the operator.

## Resource budget

The Web Terminal and DevWorkspace controllers request CPU that this single node has to
schedule. With the cluster at ~100% *requests*, both stay `Pending` with
`0/1 nodes are available: 1 Insufficient cpu` — check `oc describe node | grep -A6 'Allocated
resources'` and free something before blaming the operator.
