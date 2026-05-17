# Agent instructions

**OpenShift GitOps** repository: Kubernetes/OpenShift manifests, **Argo CD** ApplicationSets, operators (OLM), and app workloads. Prefer what existing manifests and `docs/` already do when adding or changing resources.

## Layout

- **`gitops/bootstrap/`** — Argo CD bootstrap, ApplicationSets, extra RBAC for the application controller.
- **`gitops/infra/`** — cluster/platform operators and shared config (cert-manager, External Secrets, MetalLB, Gateway API, LVMS, …).
- **`gitops/applications/<app>/`** — GitOps-managed apps wired through the ApplicationSet (e.g. TeddyCloud).
- **`applications/`** — legacy/sample app manifests; not always on the same ApplicationSet generator path.
- **`docs/`** — operational notes, runbooks, ADR-style reasoning.
- **`teddycloud-ocp/`** — container build assets for the TeddyCloud OCP image.

When unsure where a resource belongs, find the nearest similar concern (same operator or same app) and mirror its directory and naming.

## Hardware

Single-node cluster (no GPU). Avoid workloads or operators that require GPU, NUMA tuning, or multi-node HA assumptions.

| Component | Spec |
|-----------|------|
| CPU | Intel Xeon E5-1650 V3 |
| RAM | 8 × 32 GiB DDR4 ECC registered (256 GiB total) |
| Storage | 2 × 480 GiB SSD SATA (datacenter grade) |
| NIC | Intel I210 (1 GbE) |

## Validation and workflow

- **Always use the git flow** (`edit → commit → push → Argo syncs`) for anything under `gitops/infra/` and for changes that must persist. Both ApplicationSets run `selfHeal: true` + `prune: true`, so direct changes are reverted and non-git resources are deleted within the next sync cycle.
- **Pre-push validation:** `oc apply --dry-run=server -f <file>` for schema/admission checks; `argocd app diff <app>` and `argocd app sync <app> --dry-run` to catch Argo-specific issues (sync-waves, hooks, ordering) before applying.
- **Direct `oc apply`** is acceptable only for stateless, recreatable app-tier resources (Deployment, Service, Route, ConfigMap, …) as a short-lived test window. Never use it for operators, LVMS, MachineConfig, CRDs, ClusterIssuers, or SecretStores.

## Conventions

- **Cluster CLI:** prefer **`oc`** for OpenShift-specific resources; otherwise match existing docs/scripts.
- **Secrets:** never commit real tokens or kubeconfigs. Use **External Secrets Operator** + Infisical; follow the bootstrap scripts already in `gitops/infra/` as the pattern.
- **Scripts next to YAML** are intentional — Argo ignores non-YAML files; keep scripts idempotent and safe to re-run.
- **Docs:** longer reasoning, runbooks, and design notes go in `docs/`; only short inline comments belong in manifests.

## Git commits

When writing commit messages (including suggested messages in chat):

- **[Conventional Commits](https://www.conventionalcommits.org/)** — use `type(optional scope): summary`. Pick a fitting `type` (`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, etc.); add a short `scope` when it clarifies the area (role name, component).
- **Subject** — imperative after the colon; the header line is at most **72 characters** total (including `type(scope): `), no trailing period.
- **Body** — optional. Add a blank line and a short body only when it helps (e.g. why, migration hint). Keep it tight; avoid long bodies that restate the diff.
- **Footers** — none, except a **`BREAKING CHANGE:`** footer when documenting a breaking change, as Conventional Commits allows. Mark breaking commits with `!` on the type or scope when that is enough (`feat!:`, `feat(scope)!:`).
- **One logical change per commit** — do not mix unrelated topics; avoid splitting one logical change into many tiny commits.

Examples: `feat(teddycloud): add OCP entrypoint and Dockerfile`, `fix(metallb): correct BGP peer configuration`.
