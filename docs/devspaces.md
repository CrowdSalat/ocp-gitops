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
stopped (`spec.started: false`) and clones ocp-gitops, medi-bucher,
teddycloud-spotify-radio-shim, workstation-playbook and homelab every time it starts.

To use it:
- Open the Dashboard and press start on the `multi-repo` workspace (or
  `oc -n app-devworkspace patch dw multi-repo --type=merge -p '{"spec":{"started":true}}'`).
- Adjust the `projects:` list in the manifest to your taste; repos clone under
  `/projects/crowdsalat/<name>`.
- Private repos need a one-time personal access token (Dashboard OAuth flow); a raw
  `DevWorkspace` has no token until one is added — keep auto-cloned repos public for now.

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