# Operator updates via GitOps

## How — what lives in Git and how it is applied

Operator install intent is stored as plain YAML (typically `Subscription`, plus `OperatorGroup` and `Namespace` where needed). E.g. [`gitops/bootstrap/openshift-gitops-operator.yaml`](../gitops/bootstrap/openshift-gitops-operator.yaml).

Subscriptions use a **fixed catalog channel** (not `latest`) and **`installPlanApproval: Automatic`**.

## Why — the trade-offs this layout is aiming for

- **Channel** — Keeps the operator on one Red Hat–published line (for example `gitops-1.20`). Changing line is an explicit edit in Git.
- **Automatic approval** — OLM can apply `InstallPlan`s for updates **on that channel** without a separate human approval, so subscriptions are less likely to sit pending and GitOps sync health is not blocked on manual install-plan clicks alone.

Exact channel names depend on the package and cluster catalog; use `oc get packagemanifest <name> -o yaml` when adding or bumping an operator.

## Ref — where to dig deeper

- [Upgrading installed Operators](https://docs.openshift.com/container-platform/latest/operators/admin/olm-upgrading-operators.html) (OpenShift documentation)
- [OLM workflow](https://docs.openshift.com/container-platform/latest/operators/understanding/olm/olm-workflow.html) (OpenShift documentation)
- [Red Hat Ecosystem Catalog](https://catalog.redhat.com/) (channels and compatibility)
