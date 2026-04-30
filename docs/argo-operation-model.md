# Argo CD Operation Model

## Issue Statement

As cluster scale and multi-tenancy requirements increase, a centralized Argo CD instance can become a single point of failure, a performance bottleneck, or a security risk. A balance is required between centralized management and the isolation expected by independent teams or highly regulated workloads.

## Selected solution: single instance with AppProjects

In this environment, a **single management instance** is used together with **Argo CD AppProjects**.

**Rationale:** A single pane of glass is maintained for cluster-wide visibility, while logical RBAC boundaries are enforced through projects. Resource overhead is reduced and maintenance of the GitOps controller is simplified.

## Option 1: Single instance (hub model)

One Argo CD control plane is deployed (typically in `openshift-gitops`).

* **Implementation:** Source repositories and destination namespaces are scoped through `AppProject` rules.
* **Pros:** Monitoring is simplified, resource consumption is lower, and authentication / OIDC is centralized.
* **Cons:** Blast radius is shared; performance degradation can occur at very large scale (for example, 1,000+ applications).

## Option 2: Multiple instances (federated model)

Independent Argo CD instances are deployed into team-specific namespaces by the OpenShift GitOps Operator.

* **Implementation:** Each instance is defined by its own `ArgoCD` Custom Resource.
* **Pros:** Security isolation is strong; upgrade cycles are independent; performance is dedicated per instance.
* **Cons:** Operational overhead is higher; visibility is fragmented; controller resources are duplicated.

## Option 3: Namespace-scoped (restricted model)

One or more Argo CD instances are deployed without cluster-wide permissions (no `ClusterRole` / `ClusterRoleBinding`).

* **Implementation:** The operator is configured so that only a predefined set of namespaces is watched and managed.
* **Pros:** Global cluster resources (for example nodes or PVs) cannot be modified by the GitOps controller without additional roles.
* **Cons:** Initial RBAC configuration is more involved; broad platform-level infrastructure management is not supported by this pattern alone.


## References

* **OpenShift Documentation:** [Configuring Argo CD for Multi-tenancy](https://docs.openshift.com/container-platform/latest/cicd/gitops/configuring-argo-cd-for-multi-tenancy.html)
* **Argo CD Proj:** [AppProject Specification](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
* **Red Hat Blog:** [Techniques for multi-instance GitOps](https://cloud.redhat.com/blog/multi-instance-gitops-with-openshift-gitops)
