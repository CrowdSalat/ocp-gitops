# Gateway API / Istio — removed on purpose

This cluster has **no Gateway API** and **no Service Mesh**. The `GatewayClass` that used to
exist was removed on purpose, and it is worth writing down why, because putting it back
silently costs 500m of CPU.

## What happened

`gitops/infra/gateway-api/gapi-gatewayclass.yaml` created:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
```

The **Cluster Ingress Operator** (CIO) treats any GatewayClass with that controller as
"Istio is wanted here" and installs the whole Istio stack itself — its own env says so:

```
GATEWAY_API_OPERATOR_CATALOG=redhat-operators
GATEWAY_API_OPERATOR_VERSION=servicemeshoperator3.v3.3.8
ISTIO_VERSION=v1.28-latest
```

That means `istiod-openshift-gateway` in `openshift-ingress` (**500m CPU request**, the
largest single pod on the node), the 14 Istio API CRDs
(`networking.istio.io`, `security.istio.io`, `extensions.istio.io`), the sidecar-injector
MutatingWebhookConfiguration, the `istiod-allow` NetworkPolicy and a pile of ClusterRoles.
The CRDs carry `ingress.operator.openshift.io/owned: "true"` and
`helm.sh/resource-policy: keep`, so **deleting them by hand does nothing** — the CIO
recreates them within seconds:

```
operator.init.install  Drift detected (CRD deleted) {"name":"gateways.networking.istio.io"}
operator.init.install  Drift detected (CRD added)   {"name":"gateways.networking.istio.io"}
```

Deleting the GatewayClass is the only lever. It triggers
`operator.init.install  Uninstalling {"revision":"openshift-gateway"}` and the CIO removes
the Helm release, the CRDs and the RBAC.

## Service Mesh 3 (OSSM) was removed separately

The `servicemeshoperator3` OLM subscription was installed by hand (never in this repo) and
removed manually: Subscription → CSV → the 9 `sailoperator.io` CRDs → the 114 inert CSV
copies in the other namespaces. Nothing in Git touches it, so it will not come back on its
own.

One trap: the `istiocsrs.operator.openshift.io` CRD looks like Service Mesh but belongs to
the **cert-manager operator** (`app.kubernetes.io/part-of: cert-manager-operator`,
`olm.managed: true`). Do not delete it — and if the OLM-generated aggregate ClusterRoles
`istiocsrs.operator.openshift.io-v1alpha1-{admin,edit,view,crdview}` ever disappear, OLM
will not always bring them back in time.

## State after the cleanup

- Node CPU requests: 9487m of 11500m (82%) — roughly 2 CPU free, enough for a Dev Spaces
  workspace (1080m) to schedule again.
- No `GatewayClass`, no Istio API, no istiod, no Service Mesh operator.
- The console terminal (`web-terminal`) is unaffected — it only needs the DevWorkspace
  operator, see [web-terminal.md](web-terminal.md).

## If Gateway API is ever needed again

Re-adding the GatewayClass brings the istiod back with it. Budget for 500m, or expose apps
with `Route` + `oauth-proxy` instead — see [oauth-proxy.md](oauth-proxy.md).
