# TODO

**How to add items:** Keep a short bullet list at the top as a task index (one bullet per open item). For each bullet, add a section below headed with the same short title; put details, decisions, links, and sub-steps only under that heading. New work should extend the index and add a matching section so the file stays scannable.

## Task index

- [Move infra from a single Application to an ApplicationSet and split `gitops/infra` into per-component directories](#move-infra-from-a-single-application-to-an-applicationset-and-split-gitopsinfra-into-per-component-directories)

---

## Move infra from a single Application to an ApplicationSet and split `gitops/infra` into per-component directories

**Goal:** Match how `applications` are managed: one Argo CD `Application` per directory under a root path, driven by a git directory `ApplicationSet`, instead of one monolithic `Application` that syncs all of `gitops/infra` at once.

**Why:** Smaller blast radius per sync, clearer ownership, and room to tune sync policy, sync waves, or destinations per component later without touching unrelated manifests.

**Migration outline**

1. Add an `ApplicationSet` (for example in `gitops/bootstrap/`) that mirrors `apps-applicationset.yaml`: `git` generator with `directories.path: gitops/infra/*`, template `name` from `path.basename`, `path: '{{path}}'`, same `repoURL` / `targetRevision` as today.
2. Reuse the **cluster-admin** Argo `project` (or equivalent) that the current `infra` `Application` uses, since infra manifests are cluster-scoped or land in privileged namespaces. Do not copy the `applications` set’s `default` project unless you intentionally relax that boundary.
3. Align **destination** with what the current infra `Application` does (`server: https://kubernetes.default.svc`; namespace as today unless a subdirectory needs an explicit namespace in the template).
4. Split today’s flat `gitops/infra/*.yaml` files into **one subdirectory per Argo Application**, each folder holding only that component’s manifests (and a `kustomization.yaml` if you later want to compose multiple files without growing one giant YAML).
5. Remove or disable the old single `Application` manifest so only the `ApplicationSet` owns those paths (avoid double-sync).

**Proposed layout under `gitops/infra/`** (one immediate child directory = one generated `Application`; names are suggestions—rename to match your naming taste)

| Directory | Purpose |
|-----------|---------|
| `cert-manager/` | Cert-manager operator install (Subscription, OperatorGroup, etc.). |
| `external-secrets/` | External Secrets Operator install. |
| `lvms/` | LVMS operator plus cluster storage CRs (for example `LVMCluster` / LVMS-related resources) so storage stays with its operator. |
| `openshift-lightspeed/` | OpenShift Lightspeed operator install. |
| `gateway-api/` | Cluster-wide Gateway API pieces (for example `GatewayClass`). |
| `image-registry/` | Image registry configuration. |
| `machine-config/` | Machine config or SSH/bootstrap manifests that apply at cluster or node level. |

Adjust boundaries if you prefer separating **operator Subscription** from **instance CRs** into two apps (then use two sibling directories and rely on sync waves or manual ordering).

**Follow-ups after the move**

- Update `README.md` “Structure” / “How it works” so it documents infra `ApplicationSet` behavior alongside `applications/`.
- Run a one-time sync in a test cluster and confirm no duplicate resources if the old `Application` was removed after the new set is healthy.
