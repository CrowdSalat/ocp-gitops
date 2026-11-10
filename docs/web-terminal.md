# Console terminal (`oc` in the browser)

The **Web Terminal Operator** adds a "Cloud Shell" tab to the OpenShift console. It runs a
`DevWorkspace` with `oc`, `kubectl`, `helm` and friends, pre-authenticated as the logged-in
user — no local `oc` install needed.

Managed by the `infra` ApplicationSet (dir `gitops/infra/web-terminal` → Application
`infra-web-terminal`).

## What gets deployed

A single OLM `Subscription` (`web-terminal`, catalog `redhat-operators`, channel `fast`). The
operator has no CR of its own; on install it creates the `DevWorkspaceTemplate`s
`web-terminal-tooling` and `web-terminal-exec` in its namespace. The console then creates a
`DevWorkspace` per terminal session in the user's current project.

## Why the Subscription lives in `openshift-devspaces`

The vendor default is `openshift-operators`, but that namespace has a second, unrelated
`Subscription` (`servicemeshoperator3`) on `installPlanApproval: Manual` with an upgrade
pending. OLM batches all subscriptions of one OperatorGroup into a **single InstallPlan**, so
a new `web-terminal` Subscription there produced a plan that also contained the Service Mesh
upgrade — marked `RequiresApproval` and never auto-approved. Approving it would have upgraded
Service Mesh as a side effect.

`openshift-devspaces` has the same global OperatorGroup scope (`status.namespaces: [""]`) and
already runs the DevWorkspace Operator that web terminals depend on, so the plan resolves
there on its own. Keep that in mind if Dev Spaces is ever removed: move this Subscription
then.

## Verification

```shell
oc get sub web-terminal -n openshift-devspaces     # AtLatestKnown, web-terminal.v1.17.2
oc get dwt -n openshift-devspaces                  # web-terminal-tooling, web-terminal-exec
```

The console backend picks the namespace up at runtime (`/api/terminal/installedNamespace`
returns `openshift-devspaces`), so no console restart is needed.

End-to-end check — create the same `DevWorkspace` the console would, watch it reach `Running`,
then delete it:

```shell
oc get dw -A                       # PHASE Running, URL on the internal service
oc exec -n <ns> <terminal-pod> -c web-terminal-tooling -- oc version
```

Terminal sessions are runtime state: never commit a `DevWorkspace` for this. The
`/api/terminal/available` endpoint returning `204` means the console found the operator.
