# Operator updates via GitOps

## How — what lives in Git and how it is applied

Operator install intent is stored as plain YAML (typically `Subscription`, plus `OperatorGroup` and `Namespace` where needed). Example: [`gitops/bootstrap/openshift-gitops-operator.yaml`](../gitops/bootstrap/openshift-gitops-operator.yaml).

Subscriptions are configured with a **fixed catalog channel** (not `latest`) and **`installPlanApproval: Automatic`**. Unless an operator requires another catalog, `source: redhat-operators` and `sourceNamespace: openshift-marketplace` are used.

## Why — trade-offs implied by this layout

- **Channel** — The operator is kept on one Red Hat–published line (for example `gitops-1.20`). A move to another line is made through an explicit Git change.
- **Automatic approval** — `InstallPlan`s for updates **on that channel** may be applied by OLM without a separate human approval step, so subscriptions are less likely to remain pending and GitOps sync health is less often blocked on manual install-plan approval alone.
- **Catalog defaults** — The standard OperatorHub sources documented for OpenShift are followed.

Channel names depend on the package and cluster catalog; when an operator is added or bumped, catalog data is read with `oc get packagemanifest <name> -o yaml`.

## Ref — further reading

- [Upgrading installed Operators](https://docs.openshift.com/container-platform/latest/operators/admin/olm-upgrading-operators.html) (OpenShift documentation)
- [OLM workflow](https://docs.openshift.com/container-platform/latest/operators/understanding/olm/olm-workflow.html) (OpenShift documentation)
- [Red Hat Ecosystem Catalog](https://catalog.redhat.com/) (channels and compatibility)
