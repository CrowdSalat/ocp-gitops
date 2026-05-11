# ArgoCD Namespace Permissions on OpenShift

## Problem

OpenShift GitOps runs ArgoCD in a dedicated namespace (`openshift-gitops`). By default its application controller service account has **no rights in other namespaces**. Without explicit permission, ArgoCD cannot create or manage resources in an app namespace, and syncs will fail with `forbidden` errors.

The naive fix is to run this manually for every new namespace:

```bash
oc adm policy add-role-to-user admin \
  system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n <app-namespace>
```

This is error-prone and does not scale.

## Solution

Add a `Namespace` manifest to each application directory with the label `argocd.argoproj.io/managed-by: openshift-gitops`. The OpenShift GitOps operator watches for this label and **automatically creates the necessary RoleBinding** in that namespace.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app-<appname>
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
```

ArgoCD manages the `Namespace` resource itself, so `CreateNamespace=true` in the ApplicationSet `syncOptions` becomes optional but harmless.

Every new application directory needs its own `namespace.yaml` with this label — no manual `oc adm` step required.
