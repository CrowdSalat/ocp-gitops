# MetalLB on OpenShift Bare Metal

## When to use MetalLB

Use MetalLB when an application needs its **own dedicated external IP** — either because it requires a specific IP instead of the shared wildcard DNS, or because it exposes a **non-HTTP service** (database, UDP, etc.) that cannot go through an OpenShift Route. In both cases you declare `type: LoadBalancer` and MetalLB assigns an IP from a pre-defined pool automatically.

## Why the default Ingress Controller does not use a LoadBalancer Service

OpenShift Bare Metal IPI solves external access for `*.apps.cluster.com` without a LoadBalancer:

- **Ingress VIP** — a dedicated IP reserved at install time
- **Keepalived (VRRP)** — floats the VIP across nodes; if a node dies the IP moves instantly
- **HAProxy in hostNetwork** — the Ingress Controller pods listen directly on ports 80/443 of the node's physical interface

Traffic flow: `client → VIP → node holding VIP → HAProxy → Pod`

No `LoadBalancer` resource is involved, so MetalLB is not needed for standard cluster routes.
