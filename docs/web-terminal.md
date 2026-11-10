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

Both operators were **moved** out of `openshift-devspaces`. The move is not a `kubectl apply`
away, because of how OLM resolves on this cluster:

- Deleting the Subscription by hand is pointless while Argo manages it — `selfHeal: true`
  re-creates it within seconds. Change Git first, then let Argo prune.
- OLM copies every globally-installed CSV into **every** namespace (`status.reason: Copied`).
  Those copies carry the `olm.operatorNamespace` of the original install, and a new
  subscription happily resolves to such a stale copy: the Subscription reports
  `AtLatestKnown` while **no deployment exists**. To get a real install, delete the stale
  copies and re-create the Subscription.
- Re-installing the DevWorkspace operator fails with `no endpoints available for service
  devworkspace-controller-manager-service`: OLM validates existing CRs against the new CRD
  schema, which needs the *conversion webhook* that only the operator itself serves. Delete
  the `DevWorkspaceTemplate` CRs first, then install the CSV, then let the Web Terminal
  operator recreate the templates.
- The old install leaves a `MutatingWebhookConfiguration` (`controller.devfile.io`) pointing
  at the previous namespace. The new operator refuses to start with `conflicting webhook
  definition found on cluster` until that configuration is deleted.

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

The Web Terminal controller (100m) and the DevWorkspace controller (250m) plus its two webhook
servers (2×100m) need ~550m of CPU *requests*. This node has 11.5 CPU allocatable and runs
at ~90% requests, so anything that adds an operator stack can push these pods into
`Pending` with `0/1 nodes are available: 1 Insufficient cpu`.

The RHACM hub was the reason: with `availabilityConfig: High` its components run 2–3
replicas each and consumed the last ~900m. `gitops/infra/rhacm/multiclusterhub.yaml` now
pins `availabilityConfig: Basic`, which is the correct setting for a single-node cluster
anyway and leaves headroom for operators.

Check before blaming the operator:

```shell
oc describe node | sed -n '/Allocated resources/,/Events/p'
oc get pods -A --field-selector=status.phase=Pending
```
