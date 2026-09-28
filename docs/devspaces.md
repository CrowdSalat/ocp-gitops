# OpenShift Dev Spaces playground

Online IDE for OpenShift, accessible from any browser — including from the phone.
Installed via the `infra` ApplicationSet (dir `gitops/infra/devspaces` → Application `infra-devspaces`).

## What gets deployed

- `devspaces` Subscription (OLM, channel `stable`, operator runs in `openshift-devspaces`).
- `CheCluster` CR: per-workspace PVC (40 Gi), che-code (Code-OSS) as default editor,
  idling moved from 10 min to 60 min so builds survive a browser being closed,
  moderate `defaultContainerResources` for any devfile without explicit resource specs.
- Auth = built-in OpenShift OAuth (no Keycloak to run).

## Opening a workspace

1. Find the route: `oc get route -n openshift-devspaces devspaces` (or from the Dashboard).
2. Log in with the OpenShift cluster admin / existing user.
3. "Create Workspace" from the git repo you want to work on. A `.devfile.yaml` in a repo
   is picked up automatically; otherwise the UDI (Universal Developer Image) default is used.

For this repo, `.devfile.yaml` at the root pins `quay.io/devspaces/udi-rhel9:3.30` and
gives the container **32 Gi RAM, 4 CPU request / 6 CPU limit**. Keep a similar block in
other repos you want the beefy workspace in:

```yaml
components:
- name: universal-developer-image
  container:
    image: quay.io/devspaces/udi-rhel9:3.30
    memoryLimit: 32Gi
    memoryRequest: 8Gi
    cpuLimit: 6
    cpuRequest: 4
    mountSources: true
```

### Multi-repo workspace (auto-clone)

`gitops/manifests/devworkspace/devworkspace-multi-repo.yaml` is an Argo-managed
`DevWorkspace` named `multi-repo` (lands in namespace `app-devworkspace`). It is created
with `spec.started: true` and clones ocp-gitops, medi-bucher,
teddycloud-spotify-radio-shim and workstation-playbook every time it starts (homelab
fails — see Gotchas).

To use it:
- Open the Dashboard and press start on the `multi-repo` workspace (or
  `oc -n app-devworkspace patch dw multi-repo --type=merge -p '{"spec":{"started":true}}'`).
- The workspace exposes a web IDE endpoint on port 8080 through the shared che-gateway
  host (`http://workspace<id>-1.apps.ocp.jharings.de/`, path-routed on the dashboard host).
- Adjust the `projects:` list in the manifest to your taste; repos clone under
  `/projects/crowdsalat/<name>`.
- Private repos need a one-time personal access token (Dashboard OAuth flow); a raw
  `DevWorkspace` has no token until one is added — keep auto-cloned repos public for now.

### Gotchas (verified on this cluster)

- Do **not** set `controller.devfile.io/restricted-access: "true"` on a GitOps-managed
  `DevWorkspace`. That annotation is copied onto the `DevWorkspaceRouting`, which makes the
  devworkspace-operator `mutate-ws-resources` webhook demand that the per-workspace Route
  be created by the DevWorkspace controller SA. Routing is actually created by the
  che-gateway controller, so the request is denied and the workspace fails with
  "Failed to set up networking ... Only the workspace controller can create workspace
  objects." Dashboard-created workspaces do not set it. It is also immutable once set, so
  the object must be deleted and recreated (Argo recreates it from Git).
- Pin the tooling image to the exact digest the operator injects
  (`registry.redhat.io/devspaces/udi-rhel9@sha256:184f43b3…`); the `quay.io/devspaces/udi-rhel9:3.30`
  tag does not exist ("manifest unknown").
- Endpoint `exposure` is a string enum: `public` / `internal` / `none` (not a number). An
  unquoted `2` is rejected by the DevWorkspace webhook.
- The web IDE endpoint must be declared explicitly on the container (targetPort 8080);
  without it the workspace starts but exposes no URL and the tooling container only runs
  `tail -f /dev/null`.
- `cpuRequest` is the schedulable quantity, not `cpuLimit`. ~9.75 of the node's 11.5
  allocatable CPU is already committed by platform + app workloads, so a 4 CPU request
  never schedules; the manifest uses `cpuRequest: "1"` with `cpuLimit: "6"` to burst.
- Editing a `DevWorkspace` `template` (devfile) is only picked up on a **stopped** workspace.
  Stop it, let Argo sync, then start it.
- `homelab` does not clone: the GitHub repo is private/nonexistent for unauthenticated
  clones ("Repository not found"). It needs an access token added to the workspace.
- The in-cluster `plugin-registry` proxies an OpenVSX backend on `localhost:9000` that is
  not running, so devfile editor plugins (e.g. `che-incubator/che-code/latest`) cannot be
  fetched and flatten to nothing. Until that backend is restored, the tooling container has
  no in-browser editor (endpoint returns 503). The shell/repos work regardless.


## Resource budget (single-node reality)

- The host has 6 physical / 12 logical cores. Cluster-wide operators, Argo and OpenShift
  control plane share those cores, so a workspace at `cpuLimit: 6` already bursts into
  everything else — keep exactly one dev workspace running at a time.
- 32 Gi RAM on a 256 Gi box is comfortable; the workspace PVC (40 Gi on LVMS) is the
  actual long-term storage, so keep `git push` discipline.
- After hitting the 60 min idle timeout the workspace exits; uncommitted changes live in
  the PVC (persistent home), so work isn't lost.

## Building & shipping

- "Shipping" = `git commit && push`, Argo does the rest — no container build needed.
- If you want in-workspace `podman`/`docker` builds (nested containers) later, that
  requires enabling container build capabilities + workspace SCC changes; deliberately
  out of scope for now to keep the plumbing simple. Revisit before relying on it.

## Verification / runbook

- `oc get checluster -n openshift-devspaces` → status phase `Active`.
- `oc get pods -n openshift-devspaces` → che, dashboard, gateway, plugin registry running.
- Workspace pods land per user namespace (`oc get dw -A`), not in `openshift-devspaces`.
- Newsletter check: embedded plugin registry is deprecated → an on-prem Open VSX registry
  will become a follow-up; fine for the playground.