# OpenShift Dev Spaces playground

Browser IDE on OpenShift, for working on this repository from anywhere — including a phone.
Installed via the `infra` ApplicationSet (dir `gitops/infra/devspaces` → Application `infra-devspaces`).

## What gets deployed

- `devspaces` Subscription (OLM, catalog `redhat-operators`, channel `stable`, operator in
  `openshift-devspaces`).
- `CheCluster` CR:
  - che-code (Code-OSS) as default editor.
  - idling after 60 min so builds survive a closed browser.
  - `disableContainerBuildCapabilities: true` — nested `podman`/`docker` builds are out of
    scope, so users are not given the `container-build` SCC (which adds `SETUID`/`SETGID`).
  - `maxNumberOfRunningWorkspacesPerCluster: 1` — see [Resource budget](#resource-budget-single-node-reality).
  - `defaultContainerResources` for any devfile without explicit resource specs.
  - `pvcStrategy: per-user`, 40 Gi per user.
- Auth = built-in OpenShift OAuth (no Keycloak to run).

## Workspaces are runtime state, not GitOps content

A `DevWorkspace` is **not** committed to this repository. Create one from the Dashboard or
`chectl`:

```shell
oc get route devspaces -n openshift-devspaces
```

Then open the URL and log in with your OpenShift account.

This is deliberate. An earlier revision kept a `multi-repo` `DevWorkspace` in
`gitops/manifests/devworkspace/` with `spec.started: true`. That was wrong for two reasons:

- A workspace is mutable runtime state. Under `selfHeal: true` + `prune: true`, Argo CD
  fought the DevWorkspace operator over `spec.started`, minting a fresh workspace ID and PVC
  on every cycle.
- A workspace was created with `controller.devfile.io/creator: ""` (no owner) and without
  `controller.devfile.io/restricted-access`, so anyone with edit access to the namespace could
  drive it. A copy of it was even left running in the production `app-teddycloud` namespace,
  sharing that namespace with `teddycloud` and its PVCs.

If you ever do want a pre-seeded workspace, put it in a dedicated `<user>-devspaces`
namespace, set `controller.devfile.io/restricted-access: "true"`, and leave
`spec.started: false`.

## GitHub SSH key in every workspace

`gitops/infra/devspaces/externalsecret-git-ssh-key.yaml` pulls `GH_SSH_KEY_PRIVATE` and
`GH_SSH_KEY_PUBLIC` from Infisical and mounts them as `~/.ssh/id_ed25519_github` in every
workspace.

The DevWorkspace Operator only discovers automount Secrets **in the workspace's own
namespace**, which is exactly the namespace we do not put in Git. So the ExternalSecret
targets `openshift-devspaces`, and Dev Spaces' own replication engine fans it out: a Secret
there labelled `app.kubernetes.io/part-of=che.eclipse.org` +
`app.kubernetes.io/component=workspaces-config` is copied into every `<username>-devspaces`
namespace, carrying its labels and annotations, and drift in a user namespace is reverted.

The mount itself is four labels/annotations on the generated Secret (set through
`spec.target.template.metadata`, not on the ExternalSecret):

| Setting | Value | Why |
|---|---|---|
| `watch-secret` / `mount-to-devworkspace` | `true` | Both are required. `watch-secret` is what puts the Secret in the operator's informer. |
| `mount-path` | `/home/user/.ssh` | |
| `mount-as` | `subpath` | Each key becomes its own file. `file` would replace the whole directory and drop `known_hosts`. |
| `mount-access-mode` | `"0600"` | The operator defaults to `0640`; OpenSSH rejects any identity file with group or world bits set. |
| `mount-on-start` | `"true"` | An ESO refresh must not restart a running workspace. |

`id_ed25519_github` is not one of ssh's auto-detected names, so a static `config` key ships
alongside it pointing `IdentityFile` at the key for `github.com` only. That makes
`~/.ssh/config` GitOps-managed: it **shadows** anything the user put there on the workspace
PVC.

Consequences worth knowing before you change any of this:

- **The key goes to every user namespace on the cluster.** That is inherent to fan-out, not
  to this implementation.
- **Rotation needs a workspace restart.** `subpath` mounts do not refresh in place.
- **The key must not have a passphrase.** A passphrase needs the operator's experimental
  `ssh-add` postStart hook (`config.enableExperimentalFeatures` in the
  `DevWorkspaceOperatorConfig`) and nothing can prompt for it on a cold start.

## The devfile in this repository

`.devfile.yaml` at the repository root gives you a beefy workspace when you create one from
this repo in the Dashboard:

```yaml
components:
- name: universal-developer-image
  container:
    image: registry.redhat.io/devspaces/udi-rhel9@sha256:6399008ef079cda484724c7d5c8a9729c3d1cadf3b70bc65c6ffe94ced588cfc
    memoryLimit: 32Gi
    memoryRequest: 8Gi
    cpuLimit: "6"
    cpuRequest: "1"
    mountSources: true
```

Keep a similar block in other repositories you want the large workspace in, but pin the digest
of the image **your operator version injects** — there is no `quay.io/devspaces/udi-rhel9:3.30`
tag (that was the bug: "manifest unknown"). To read the current value:

```shell
oc get deploy devspaces-operator -n openshift-devspaces \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHE_DEFAULT_SPEC_DEVENVIRONMENTS_DEFAULTCOMPONENTS")].value}'
```

Because the digest is per-operator-version, it drifts when the operator upgrades — see the
Gotchas.

## Access path

Workspaces are served **path-based** on the single gateway host, not on per-workspace
subdomains:

```
https://devspaces.apps.ocp.jharings.de/workspace<workspace-id>/
```

The route is TLS `edge` with `insecureEdgeTerminationPolicy: Redirect`, using the shared
ingress wildcard certificate (`*.apps.ocp.jharings.de`). The che-gateway enforces OpenShift
authentication on every workspace path and RBAC per namespace; unauthenticated requests to a
workspace URL get `403`.

## Gotchas (verified on this cluster)

- **The operator upgrades itself.** The Subscription is `channel: stable` with
  `installPlanApproval: Automatic` and no `startingCSV`, so OLM advances the CSV on a catalog
  refresh with no change in this repository. It moved `3.30.1 → 3.30.2` unattended, which
  also changed the injected UDI digest. Expect the digest in `.devfile.yaml` to need a bump.
- **`cpuRequest` is the schedulable quantity, not `cpuLimit`.** The node has 11.5 CPU
  allocatable and the platform already commits ~9.7, so a 4-CPU request never schedules. Ask
  for little, burst against the limit.
- **The web IDE endpoint must be declared explicitly** if you hand-write a devfile (target
  port 8080). The operator's default container component does not declare one, so without it
  the workspace starts, exposes no URL, and the tooling container only runs `tail -f /dev/null`.
- Endpoint `exposure` is a string enum: `public` / `internal` / `none` (not a number). An
  unquoted `2` is rejected by the DevWorkspace webhook. Keep endpoints `internal` — `public`
  creates a per-workspace Route straight to the container port with no oauth-proxy in front.
- Editing a running workspace's devfile is only picked up while it is **stopped**. Stop it,
  let the change land, then start it.
- **The plugin registry is broken.** The in-cluster `plugin-registry` sidecar is told
  `START_OPENVSX: "true"` but the OpenVSX backend it expects is not running, so
  `/plugin-registry/v3/plugins` returns `404` and devfile editor plugins (including
  `che-incubator/che-code/latest`) flatten to nothing. The shell and repos work; the in-browser
  editor does not. Unresolved — see the report.

## Resource budget (single-node reality)

- The host has 6 physical / 12 logical cores. The control plane, Argo CD and the application
  namespaces together commit roughly 9.7 of the 11.5 allocatable CPU, so a single workspace
  already dominates the budget. This is why
  `maxNumberOfRunningWorkspacesPerCluster: 1` is set — it is a guardrail, not a hint.
- 32 Gi RAM on a 256 Gi box is fine; memory sits around 11% used.
- A workspace PVC holds the persistent home, so unsaved work survives idling. Keep
  `git push` discipline regardless.

## Building & shipping

- "Shipping" = `git commit && push`, Argo CD does the rest — no container build needed.
- In-workspace nested container builds are deliberately out of scope; see
  `disableContainerBuildCapabilities` above.

## Verification / runbook

- `oc get checluster -n openshift-devspaces` → status phase `Active`.
- `oc get pods -n openshift-devspaces` → operator, devspaces (che-server), dashboard, gateway
  and plugin-registry running.
- Workspace pods land in the **user's** namespace (`oc get dw -A`), normally
  `<username>-devspaces` — auto-provisioned on first login. They are never placed in an
  application namespace.
- SSH key: `oc get externalsecret devspaces-git-ssh-key -n openshift-devspaces` → condition
  `Ready`. A copy of the Secret must exist in each user namespace, and the one in
  `openshift-devspaces` must carry the replication and mount labels:

```shell
oc get secret devspaces-git-ssh-key -A -o custom-columns='NS:.metadata.namespace,PART_OF:.metadata.labels.app\.kubernetes\.io/part-of,MOUNT:.metadata.annotations.controller\.devfile\.io/mount-path'
```

  Inside a started workspace, `ls -l ~/.ssh/id_ed25519_github` must show `-rw-------` and
  `ssh -T git@github.com` must not report a permissions error. If it reports
  `Permissions ... are too open`, the `mount-access-mode` annotation was lost on the way.
