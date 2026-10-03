# Dev Spaces (Eclipse Che) review

Audit of everything Dev Spaces / Che related in this repository, compared against the
Red Hat OpenShift Dev Spaces and upstream Eclipse Che documentation, plus the live state
of the cluster.

- **Cluster:** `static.148.251.134.106.clients.your-server.de` (single node, 11500m CPU / 262654944Ki allocatable)
- **Dev Spaces operator:** `devspacesoperator.v3.30.1` (DevWorkspace Operator `v0.43.0`)
- **CheCluster:** `openshift-devspaces/devspaces`, `chePhase: Active`, `cheURL: https://devspaces.apps.ocp.jharings.de`
- **Date:** 2026-09-28

> Scope note: Red Hat's 4.22 documentation portal returns HTTP 403 to non-browser clients, so
> the comparison is made against the upstream Eclipse Che 7.122.x documentation that the Red Hat
> product is built from and mirrors chapter-for-chapter (`administration-guide/…`,
> `secure/security-best-practices`, `end-user-guide/…`). Field names, defaults and recommendations
> were additionally validated directly against the **live `CheCluster` v2 CRD schema** on this
> cluster, so every "upstream default" quoted below is the actual CRD default here.

---

## 1. Inventory

### In Git

| File | Purpose |
|------|---------|
| `gitops/infra/devspaces/operator-devspaces.yaml` | `Namespace`, `OperatorGroup`, OLM `Subscription` |
| `gitops/infra/devspaces/checluster-devspaces.yaml` | `CheCluster` (v2) — 20 lines |
| `gitops/manifests/devworkspace/namespace.yaml` | `Namespace/app-devworkspace` |
| `gitops/manifests/devworkspace/devworkspace-multi-repo.yaml` | `DevWorkspace/multi-repo` |
| `.devfile.yaml` | repo devfile (auto-imported by the dashboard) |
| `docs/devspaces.md` | runbook |

### On the cluster but **not** in Git

| Object | Note |
|--------|------|
| `DevWorkspace/multi-repo` in `app-teddycloud` | **Running.** No `argocd.argoproj.io/tracking-id`. `controller.devfile.io/creator: ""` |
| `app-devworkspace/claim-devworkspace` PVC | `Pending`, 40Gi |
| `app-teddycloud/claim-devworkspace` PVC | `Bound`, 10Gi |

### Resolved from the two ApplicationSets

- `gitops/infra/*` → Argo app `infra-devspaces`, project `cluster-admin-project`
- `gitops/manifests/*` → Argo app `devworkspace`, project `default`, dest ns `app-devworkspace`

### Git history (16 devspaces commits, `b254721`..`df6d3c8`)

The install is two days old and was built by trial and error: each commit fixes one symptom
(`use the right API group`, `start the workspace`, `lower the CPU request`, `make the endpoint
internal`, …). The current state is the accumulation of those workarounds, not a designed
configuration.

---

## 2. Findings

### CRITICAL

#### C1 — A dev workspace is running inside the production `app-teddycloud` namespace, outside GitOps

```
app-teddycloud/multi-repo   workspace4019eb221a9e40a7   Running
  pod/workspace4019eb221a9e40a7-7bdbc76cbc-bxbln   2/2   16m
  pvc/claim-devworkspace                            10Gi Bound
```

- **Not tracked by Argo.** The DevWorkspace carries no `argocd.argoproj.io/*` annotation, so
  `prune: true` never sees it. It exists only on the cluster.
- **Shares the namespace with production.** Same namespace holds `teddycloud` (public route
  `teddycloud.apps.ocp.jharings.de`), `teddycloud-spotify-shim`, `mosquitto`, and the PVCs
  `teddycloud` (20Gi) and `soloist-session-data` (1Gi). An interactive shell with a browser
  terminal now sits in that trust zone.
- **No owner.** `controller.devfile.io/creator: ""`. Commit `79e765b` deliberately removed
  `controller.devfile.io/restricted-access: "true"`, so there is no per-workspace ownership
  lock. The gateway's `forwardAuth` middleware only does a namespace-level RBAC check
  (`address: http://127.0.0.1:8089?namespace=app-teddycloud`) — anyone with edit/admin on
  `app-teddycloud` can start, stop and read this workspace.
- **Deviates from the upstream model.** Upstream provisions a dedicated
  `<username>-devspaces` project per developer, and the operator-created ClusterRoles
  (`openshift-devspaces-cheworkspaces-clusterrole`, `-devworkspace-clusterrole`,
  `-namespaces-clusterrole`) are prefixed with the *CheCluster* namespace. They therefore
  grant nothing in `app-devworkspace` or `app-teddycloud`. There is no per-user isolation here.
- Note `app-teddycloud` also carries `RoleBinding/admin → ClusterRole/admin` for the Argo CD
  application-controller SA, so the GitOps controller is admin in this namespace too.

**Action:** stop and delete the shadow workspace, and stop placing workspaces in application
namespaces. If a pre-seeded workspace is genuinely wanted, it belongs in its own
`<user>-devspaces` namespace with `restricted-access` set.

#### C2 — The GitOps-managed workspace can never start; Argo and the operator are in a self-heal fight

```
app-devworkspace/multi-repo   workspace17597e9dcb304e2c   Failed
  Error creating DevWorkspace deployment: Detected unrecoverable event FailedScheduling:
  0/1 nodes are available: 1 Insufficient cpu.
```

- Live `spec.started: false` vs Git `spec.started: true`.
- Argo app `devworkspace` is **`OutOfSync`** with `autoHealAttemptsCount: 8`: Argo re-applies
  `started: true`, DWO fails to schedule, flips it back to `false`, Argo retries. This is a
  permanent reconcile loop writing to the API server.
- `ignoredUnrecoverableEvents: ["FailedScheduling"]` (the CRD default) makes the failure
  **terminal** — DWO does not retry, so the workspace is stuck until manually patched.
- Node is at **10798m of 11500m CPU requests (93%)**, **30510m limits (265%)**.
- **Root cause is C1.** The untracked shadow workspace holds the 1 CPU / 8 Gi that the tracked
  one needs. Stopping it frees ~1700m and the tracked workspace would schedule.
- The storage is broken too: `app-devworkspace/claim-devworkspace` is **`Pending`** — the 40Gi
  claim does not bind either.

---

### HIGH

#### H1 — Gateway session secrets are readable in a plaintext ConfigMap

`ConfigMap/che-gateway-config-oauth-proxy` contains, in cleartext:

```
client_secret = "fMLHW8CyDHNE"
cookie_secret = "TkFUWnFGQXNZaXhBQlQ4UA=="
```

Anyone able to `get configmaps -n openshift-devspaces` — which includes the Argo CD
application-controller SA and any Role/RoleBinding granting configmap read there — can mint a
valid `_oauth_proxy` session cookie and reach the dashboard and every workspace **without an
OpenShift login**. The same values also exist in `Secret/che-gateway-oauth-secret`; the
ConfigMap duplication is an operator default that the CheCluster does not override.

#### H2 — `user:full` OAuth scope + access token forwarded to the browser + non-HttpOnly cookie

From the same ConfigMap:

```
scope = "user:full"
pass_access_token = true
cookie_httponly = false
cookie_expire = "24h0m0s"
```

And the per-workspace Traefik middleware (`workspace4019eb221a9e40a7-route`) rewrites
`X-Forwarded-Access-Token` → `Authorization: Bearer <token>` before proxying to the workspace.

So a `user:full` OpenShift token (full read/write on all of the user's own resources) is handed
to the in-browser IDE and to every webview it opens, stored in a cookie that JavaScript can
read, valid for 24 hours. A malicious VS Code extension, a hostile webview, or any XSS in the
IDE yields a broad, long-lived cluster token.

`networking.auth.oAuthScope` and `networking.auth.oAuthAccessTokenMaxAgeSeconds` exist in the
CheCluster v2 schema and are unset.

#### H3 — No access restriction, and no restriction on which sources a workspace may be launched from

- `networking.auth.advancedAuthorization` is **unset** — no `allowUsers` / `allowGroups` /
  `denyUsers` / `denyGroups`. Upstream, under *"What you must configure"*: *"By default, all
  authenticated OpenShift users can access Che."*
- `devEnvironments.allowedSources.urls` is **unset** — upstream documents this as the control
  that *"ensures that CDEs can only be launched from authorized sources."*
- `email_domains = "*"` on the gateway.
- Combined: `defaultNamespace.autoProvision: true` means **any** authenticated OpenShift
  account gets a namespace auto-created and can start a workspace from **any** Git or raw
  devfile URL — arbitrary code execution on the cluster, bounded only by the SCC.
- `docs/devspaces.md:17` assumes a single user ("Log in with the OpenShift cluster admin") but
  nothing enforces it.

#### H4 — Container build capabilities are granted, contradicting the repo's own documentation

The CheCluster has `devEnvironments.containerBuildConfiguration.openShiftSecurityContextConstraint:
container-build`, and the cluster carries the resulting objects:

- `SCC/container-build` — capabilities `["SETUID","SETGID"]`
- `ClusterRole/devspaces-user-container-build` — `use` on that SCC
- `ClusterRole/dev-workspace-container-build` — `get`,`update`,`use`, bound to the
  `devworkspace-controller-serviceaccount`

Upstream names the hardening switch explicitly:

> Setting the following property in the CheCluster Custom Resource prevents assigning extra
> capabilities and SCC to users:
> `spec.devEnvironments.disableContainerBuildCapabilities: true`

`docs/devspaces.md:99-101` states in-workspace podman/docker builds are *"deliberately out of
scope for now"*. The configuration does not reflect that decision.

#### H5 — No NetworkPolicy for Dev Spaces anywhere, and no `workspaces-namespace` label

- `networking.networkPolicy.enabled` is unset (upstream: *"disabled by default"*). Verified:
  `oc get networkpolicy -n openshift-devspaces` → none; none in `app-devworkspace` or
  `app-teddycloud`.
- This is inconsistent with the repo's own hygiene — `gitops/infra/external-secrets` and the
  OpenShift-provided `openshift-gitops`, OLM and `openshift-marketplace` policies all use
  default-deny + explicit allows.
- Concrete consequence: the workspace↔gateway hop is declared `secure: false` / `protocol: http`
  and carries the `Authorization: Bearer <user:full>` header in cleartext on an unisolated pod
  network. Any pod in the cluster can reach the workspace pod directly and impersonate the
  gateway's upstream.
- No namespace in the cluster carries `app.kubernetes.io/component: workspaces-namespace`, so
  even hand-written policies following the upstream guide have no selector to attach to.

#### H6 — No quotas, no limits, unlimited workspaces — on a node at 93% committed CPU

| CheCluster field | Value | Upstream default |
|---|---|---|
| `devEnvironments.maxNumberOfWorkspacesPerUser` | `-1` | `-1` |
| `devEnvironments.maxNumberOfRunningWorkspacesPerUser` | *unset* | *unset* |
| `devEnvironments.maxNumberOfRunningWorkspacesPerCluster` | *unset* | *unset* |
| `devEnvironments.containerResourceCaps` | *unset* | *unset* |
| `networking.networkPolicy.enabled` | *unset* | `false` |

Cluster-wide, `oc get resourcequota -A` returns only `openshift-host-network`, and
`oc get limitrange -A` returns **nothing**. So there is no mechanism preventing a workspace
from requesting the entire node, and no cap on how many any user may start.

Any authenticated user can therefore exhaust the node and take down the control plane, Argo CD
and every production app (teddycloud, mealie, openclaw, ollama, obsidian-sync). Because
`FailedScheduling` is in `ignoredUnrecoverableEvents`, the failure is silent and permanent
rather than throttled with a retry.

---

### MEDIUM

#### M1 — AllNamespaces OperatorGroup, unpinned channel, auto-approved upgrades, no PSS intent

```yaml
kind: OperatorGroup
spec: {}                    # → OLM defaults to AllNamespaces
```

- AllNamespaces means the operator runs with cluster-wide rights and creates ClusterRoles, SCCs
  and OAuthClients cluster-wide. `957fce0` moved here from `targetNamespaces`.
- `channel: stable` + `installPlanApproval: Automatic` + no `startingCSV`. The cluster has
  already auto-advanced `3.30.0 → 3.30.1` with no commit and no review. A catalog refresh can
  change the operator, the injected images and the effective CheCluster behaviour at any time —
  at odds with `AGENTS.md` ("prefer the git flow … for anything that must persist").
- The `Namespace` manifest declares no Pod Security Standards intent. Live labels:
  `pod-security.kubernetes.io/audit: privileged`, `warn: privileged`,
  `security.openshift.io/scc.podSecurityLabelSync: "true"` (injected by the SCC sync
  controller), and **no `enforce` label**. Compare `gitops/manifests/medi-bucher/namespace.yaml`,
  which declares `audit: restricted` / `warn: restricted`.

#### M2 — The plugin registry is unauthenticated on the public internet

`skip_auth_regex = "^/plugin-registry|^/$|/healthz$|…"` bypasses oauth-proxy. Verified from
outside the cluster:

| Request | Result |
|---|---|
| `GET /plugin-registry/v3/plugins` | **404** (not 401 — genuinely unauthenticated; the 404 is the broken backend) |
| `GET /` | 200 (dashboard shell) |
| `GET /healthz` | 418 |
| `GET /workspace4019eb221a9e40a7/` | 403 (kube-rbac-proxy correctly denies) |

Today the only content is 404s, but `pluginRegistry.openVSXURL` and
`pluginRegistry.externalPluginRegistries` are unset, so the moment either is pointed at a
private mirror, that catalog becomes public.

#### M3 — The plugin registry is broken, so the editor the CheCluster mandates cannot load

`ConfigMap/plugin-registry` has `START_OPENVSX: "true"`, but the OpenVSX backend the sidecar
expects is not running. `CheCluster.spec.components.pluginRegistry: {}` and
`spec.devEnvironments.defaultEditor: che-incubator/che-code/latest` therefore resolve to
nothing, and the same plugin is requested again in the DevWorkspace `plugins[]`. Net effect:
the workspace starts, clones repos, gives you a shell — and the web IDE endpoint serves
nothing. `docs/devspaces.md:80-83` records this as a gotcha (and says 503; the actual response
is 404) rather than fixing it or disabling the editor requirement.

#### M4 — `.devfile.yaml` pins a tag that does not exist, and the docs tell you to copy it

```yaml
image: quay.io/devspaces/udi-rhel9:3.30   # .devfile.yaml:9
```

- `docs/devspaces.md:66-67` and commit `20d3063` both state this tag does not exist
  ("manifest unknown"), yet the same block is reproduced at `docs/devspaces.md:25-35` as the
  snippet to copy into other repositories.
- It is a floating, mutable tag — a supply-chain risk in a file the dashboard auto-imports.
- It diverges from `devworkspace-multi-repo.yaml:12`, which correctly pins
  `registry.redhat.io/devspaces/udi-rhel9@sha256:184f43b3…`.
- `cpuRequest: 4` here vs `"1"` in the CR. At 93% node utilisation a 4-CPU request can never
  schedule, so a dashboard-created workspace from this repo fails to start.

#### M5 — A shared, auto-started, ownerless workspace is committed to Git

`devworkspace-multi-repo.yaml:6` sets `spec.started: true` on a `DevWorkspace` named
`multi-repo` in a shared namespace, with no owner. Upstream treats `DevWorkspace` as per-user
runtime state. Committing a running IDE means:

- every Argo self-heal restarts it (see C2 for the loop this currently produces);
- anyone with push access to this repository can boot a 32 Gi / 6-CPU workspace on a shared
  node;
- the object is mutable runtime state under `selfHeal: true` + `prune: true`, which is the
  wrong ownership model for a GitOps repo.

#### M6 — No Git provider OAuth configured

`CheCluster.spec.gitServices.github: []`. Upstream lists this under *"What you must
configure"*:

> OAuth for Git providers. Without OAuth, developers must manually create personal access
> token secrets.

The consequence here is PAT sprawl: long-lived tokens stored as Secrets in workspace
namespaces, and `docs/devspaces.md:52-53` sidesteps it by instructing that auto-cloned repos
stay **public** — so the whole `projects:` list is unauthenticated HTTPS. `homelab` is
already broken this way ("Repository not found", doc lines 78-79) and is left in the list.

#### M7 — No RBAC for the Che / Devfile API groups

`gitops/bootstrap/argo-extra-permissions.yaml` has seven least-privilege rule-sets — LVM,
External Secrets, cert-manager, MetalLB, Gateway API (plus admin/editors) — and **none** for
`org.eclipse.che` or `workspace.devfile.io`. Argo's ability to manage the `CheCluster` and the
`DevWorkspace` comes entirely from the `argocd.argoproj.io/managed-by: openshift-gitops`
namespace label, which the GitOps operator expands into broad admin in that namespace. This is
inconsistent with the least-privilege pattern the same file establishes for the other five
operators, and it is why `app-devworkspace` needs no explicit grant at all.

#### M8 — Route terminates TLS with `edge` + `insecureEdgeTerminationPolicy: Redirect`

Router → `che-gateway` is plain HTTP. For an interactive IDE that forwards a `user:full` bearer
token in a request header, the in-cluster hop should be `reencrypt` — or, at minimum, be
covered by a NetworkPolicy (H5). `networking.tlsSecretName` is unset, so it relies on the
shared ingress wildcard cert (`CN=*.apps.ocp.jharings.de`, Let's Encrypt, expires 2026-12-09)
— fine, but undocumented in the manifest.

#### M9 — Traefik trusts forwarded headers from anyone

`ConfigMap/che-gateway-config` sets `entrypoints.http.forwardedHeaders.insecure: true`, so
che-gateway accepts `X-Forwarded-For` from any peer. Only reachable in-cluster, but combined
with H5 any pod on the node can spoof client IPs toward the gateway.

---

### LOW / correctness and documentation drift

| ID | Finding |
|---|---|
| **L1** | `defaultEditor: che-incubator/che-code/latest` and the DevWorkspace `plugins[].id` are floating `latest` tags. The editor binary executed inside the workspace is not digest-pinned. |
| **L2** | The `web-ide` endpoint is declared twice — on the container (`devworkspace-multi-repo.yaml:18-23`) and again in `componentOverrides` (`:29-34`). The override is redundant. |
| **L3** | `defaultContainerResources` is best-effort: `requests: 250m/256Mi` against `limits: 4 CPU/4Gi`. Also mixed quoting style (`cpu: '4'` vs `memory: 4Gi`) for values in the same block. |
| **L4** | `secondsOfRunBeforeIdling: -1` (never idles on run time) together with `secondsOfInactivityBeforeIdling: 3600`. A forgotten workspace burns 1 CPU / 8 Gi indefinitely on a 93%-full node. Upstream pairs idle settings with the `maxNumberOf*` caps — none of which are set. |
| **L5** | `pvcStrategy: per-workspace` with `claimSize: 40Gi` does not fit the storage. **Corrected after verification:** the LVMS volume group is `VSize 447.13g / VFree 44.71g` — a 40 Gi claim would consume ~90% of remaining free space. In practice PVCs land at the 10 Gi LVMS default and stay there: PVC size is immutable, so a workspace that predates a `claimSize` bump never picks it up (both `claim-devworkspace` volumes bound at 10 Gi despite `claimSize: 40Gi`). |
| **L6** | `components.metrics.enable: true` with no documented scrape/retention policy. `dashboard.logLevel: ERROR` vs `cheServer.logLevel: INFO` — asymmetric and undocumented. |
| **L7** | `imagePuller.enable: false` — every cold workspace pulls the multi-GiB UDI from `registry.redhat.io` over a 1 GbE NIC. Directly worsens the pressure in C2. |
| **L8** | **Documentation drift** in `docs/devspaces.md` — see below. |
| **L9** | No admission guard against `exposure: public`. Commit `df6d3c8` fixed a real exposure — `exposure: public` produced a per-workspace Route straight to port 8080 with no oauth-proxy, verified HTTP 200 unauthenticated from the internet. The fix is one line in Git with nothing preventing regression (a `ValidatingAdmissionPolicy` on `devworkspaceroutings` / `DevWorkspace` would). |

#### L8 detail — statements in `docs/devspaces.md` that are false today

| Line | Claim | Reality |
|---|---|---|
| 21-23, 25-35 | `.devfile.yaml` "pins `quay.io/devspaces/udi-rhel9:3.30`" and copy this block elsewhere | Tag does not exist; `cpuRequest: 4` cannot schedule |
| 48-49 | "shared che-gateway host (`http://workspace<id>-1.apps.ocp.jharings.de/`)" | Routing is **path-based** on the single host: `https://devspaces.apps.ocp.jharings.de/workspace<id>/`, over TLS |
| 82-83 | "endpoint returns 503" | Returns 404 |
| 89-90 | "keep exactly one dev workspace running at a time" | Not enforced anywhere — and the extra one is in `app-teddycloud` |
| 91-92 | "the workspace PVC (40 Gi on LVMS) is the actual long-term storage" | The CheCluster asks 40 Gi but only **44.71 GiB of 447 GiB** is free on the LVMS VG; volumes bind at the 10 Gi default |
| 107 | "Workspace pods land per user namespace" | They land in shared `app-*` namespaces |
| — | (absent) | No mention of the shadow workspace in `app-teddycloud`, the Argo self-heal loop, or the CPU exhaustion |

---

## 3. What is already correct

Worth keeping — do not regress these:

- Container image is **digest-pinned** in the DevWorkspace
  (`registry.redhat.io/devspaces/udi-rhel9@sha256:184f43b3…`).
- Workspace pod security context is sound: `runAsNonRoot: true`, `runAsUser: 1000800000`,
  `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`.
- The endpoint uses `exposure: internal`, not `public` — the `df6d3c8` fix is in place, and the
  gateway's `forwardAuth` correctly returns **403** to unauthenticated requests for a workspace
  path.
- `disableContainerRunCapabilities: true` is the default and the resulting
  `containerRunConfiguration` capabilities were cleaned up by the operator.
- The `argocd.argoproj.io/managed-by: openshift-gitops` labels on both namespaces are correct
  per `AGENTS.md` and `docs/argocd-namespace-permissions.md`.
- `app-devworkspace` carries `pod-security.kubernetes.io/audit: restricted` /
  `warn: restricted`.
- No secrets or tokens are committed — verified across all Git revisions.
- `get_started` first-week guidance aside, the choice of built-in OpenShift OAuth (no Keycloak)
  is the right call for a single-node homelab.

---

## 4. Recommended `CheCluster`

Applies M1/H3/H4/H5/H6 and the resource caps. Requires `quota`/`limitrange` and a GitHub OAuth
secret to be added separately.

```yaml
apiVersion: org.eclipse.che/v2
kind: CheCluster
metadata:
  name: devspaces
  namespace: openshift-devspaces
spec:
  devEnvironments:
    # --- who may use the platform (H3) ---
    defaultEditor: che-incubator/che-code/latest
    allowedSources:
      urls:
        - https://github.com/CrowdSalat/*

    # --- what a workspace may do (H4) ---
    disableContainerBuildCapabilities: true

    # --- blast radius (H6) ---
    maxNumberOfWorkspacesPerUser: 2
    maxNumberOfRunningWorkspacesPerUser: 1
    maxNumberOfRunningWorkspacesPerCluster: 1
    containerResourceCaps:
      requests:
        cpu: "2"
        memory: 12Gi
      limits:
        cpu: "4"
        memory: 24Gi
    defaultContainerResources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: "2"
        memory: 8Gi

    # --- lifecycle (L4) ---
    secondsOfInactivityBeforeIdling: 900
    secondsOfRunBeforeIdling: 28800

    # --- persistence (L5) ---
    storage:
      pvcStrategy: per-user
      perUserStrategyPvcConfig:
        claimSize: 40Gi

  networking:
    # --- pod isolation (H5) ---
    networkPolicy:
      enabled: true
    auth:
      # --- gateway hardening (H2, M8) ---
      oAuthScope: "user:read user:write"
      oAuthAccessTokenMaxAgeSeconds: 28800
      gateway:
        kubeRbacProxy:
          logLevel: 2
    # --- who may use the platform (H3) ---
    advancedAuthorization:
      allowGroups:
        - system:authenticated
```

## 5. Remediation order

1. **C1/C2** — stop and delete `app-teddycloud/multi-repo`; delete
   `app-devworkspace/claim-devworkspace` if it stays `Pending`. Verify the Argo `devworkspace`
   app returns to `Synced`. Nothing else in this report matters until the tracked object is
   actually converged.
2. **Remove `devworkspace-multi-repo.yaml` from `gitops/manifests/`** (M5). Workspaces are
   runtime state, not desired state. If a seeded workspace is required, put it in a dedicated
   namespace with `controller.devfile.io/restricted-access: "true"` and `spec.started: false`.
3. **H6** — add a `ResourceQuota` and `LimitRange` to every namespace that can host a
   workspace, and set the `maxNumberOf*` caps above. Without this, H3's arbitrary-source
   workspace creation is a cluster-wide DoS.
4. **H3** — set `advancedAuthorization` and `allowedSources`.
5. **H1/H2** — review the gateway's `user:full` scope, the 24h token, and `cookie_httponly =
   false`. If none of these can be overridden cleanly, put an authenticating proxy in front of
   the `devspaces` route (same pattern as `docs/oauth-proxy.md` / the TeddyCloud entry in
   `TODO.md`).
6. **M4/L8** — fix `.devfile.yaml` to the digest and a schedulable `cpuRequest`, and correct
   `docs/devspaces.md`. Add the shadow workspace, the self-heal loop and the CPU ceiling to
   the runbook.
7. **M1** — pin `startingCSV`, switch the `OperatorGroup` to `OwnNamespace` if the operator can
   cope, and declare PSS labels on `openshift-devspaces`.
8. **M7** — add Che / Devfile API groups to `argo-extra-permissions.yaml`, mirroring the other
   five operators.
9. **M3** — either bring up a real OpenVSX registry (`openVSXRegistry.enable: true`) or drop the
   `defaultEditor` / `plugins[]` requirement so the broken path is not load-bearing.
10. **L9** — add a `ValidatingAdmissionPolicy` that rejects `exposure: public` on
    `DevWorkspace` endpoints, so `df6d3c8` cannot regress.

---

## 6. Upstream references

- Protect your deployment — <https://eclipse.dev/che/docs/stable/secure/security-best-practices/>
- Restrict access to specific users and groups (`advancedAuthorization`) —
  <https://eclipse.dev/che/docs/stable/secure/configuring-advanced-authorization/>
- Configure network policies (`networking.networkPolicy.enabled`) —
  <https://eclipse.dev/che/docs/stable/administration-guide/configuring-network-policies/>
- Configure allowed URLs for CDEs (`devEnvironments.allowedSources.urls`) —
  <https://eclipse.dev/che/docs/stable/administration-guide/configuring-allowed-urls-for-cloud-development-environments/>
- Configure OAuth for Git providers —
  <https://eclipse.dev/che/docs/stable/administration-guide/configuring-oauth-for-git-providers/>
- Limiting the number of workspaces a user can run —
  <https://eclipse.dev/che/docs/stable/administration-guide/limiting-the-number-of-workspaces-that-all-users-can-run-simultaneously/>
- Configuring the storage strategy —
  <https://eclipse.dev/che/docs/stable/administration-guide/configuring-the-storage-strategy/>
- Automatic Kubernetes token injection in workspaces —
  <https://eclipse.dev/che/docs/stable/end-user-guide/automatic-token-injection/>
- Red Hat OpenShift Dev Spaces (product docs, 4.22 — blocks non-browser clients) —
  <https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/4.22>
