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

## How to assign a second IP address to the cluster

When an application needs a dedicated external IP that is separate from the cluster's main ingress VIP, you provision a second IP through your hosting provider and expose it via MetalLB.

### Step 1 — Provision the IP at the provider

See the [Hetzner Robot section](#hetzner-robot-additional-ips) below for provider-specific steps. The result should be a routable IP (or subnet) that is forwarded to your server.

### Step 2 — Create the MetalLB instance CR (once per cluster)

If the MetalLB instance CR does not yet exist:

```yaml
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
```

### Step 3 — Declare an IPAddressPool

Place this in `gitops/infra/metallb/ipaddresspool.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: hetzner-additional
  namespace: metallb-system
spec:
  addresses:
    - 5.9.x.x/32   # replace with the IP you bought
```

Add more entries to `addresses` if you later buy a subnet (e.g. `5.9.x.0/29`).

### Step 4 — Advertise the pool via L2

Place this in `gitops/infra/metallb/l2advertisement.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: hetzner-additional
  namespace: metallb-system
spec:
  ipAddressPools:
    - hetzner-additional
```

MetalLB elects one cluster node to answer ARP for the IP. If that node goes away, it re-elects another node automatically.

### Step 5 — Use the IP in a workload

Set `type: LoadBalancer` on any Service. To pin a specific IP from the pool, add the annotation:

```yaml
metadata:
  annotations:
    metallb.universe.tf/loadBalancerIPs: "5.9.x.x"
spec:
  type: LoadBalancer
```

Without the annotation MetalLB picks any free IP from the pool.

---

## Hetzner Robot additional IPs

Hetzner Robot (dedicated servers) routes additional IPs differently from Hetzner Cloud. Understanding the model is important before configuring MetalLB.

### How Hetzner routes additional IPs

Hetzner's routers do **not** use a shared broadcast domain between your server and the outside world. Instead they use a **point-to-point /30 subnet** for the server's main IP and then route all additional IPs (or subnets) toward that server via a **host route** (`/32` or a subnet route).

```
Internet → Hetzner upstream router → /32 host-route to your server's main IP → your server
```

Because the additional IP is delivered as a routed packet (not a bridged Ethernet frame), Hetzner needs to know which MAC address to send the Ethernet frame to on the last hop. That is solved with a **virtual MAC**:

1. In the Robot panel, go to **Servers → your server → IPs**.
2. Select the additional IP and click **Request virtual MAC**.
3. Hetzner maps that virtual MAC to the additional IP in their ARP table.
4. Any interface on your server that presents that virtual MAC will receive packets destined for the additional IP.

With MetalLB in L2 mode you do **not** configure the virtual MAC on a cluster interface manually. MetalLB's speaker pod answers ARP requests for the IP from the node's real MAC. This works because Hetzner's router only needs the MAC on the last Ethernet segment (between the top-of-rack switch and your server), and MetalLB's ARP reply is what updates that entry.

### Buying and configuring an additional IP

1. In the Robot panel, go to **Servers → your server → IPs → Order additional IP**.
2. Choose **single IP** (for one dedicated service endpoint) or a **/29 subnet** (gives 6 usable IPs) for multiple services.
3. For a single IP: request a virtual MAC as described above.
4. For a subnet: Hetzner routes the entire subnet to your server's main IP — no virtual MAC is needed; configure a loopback or dummy interface on one node with the gateway IP of the subnet, or let MetalLB handle ARP for individual IPs within the subnet.
5. Add the IP or CIDR to the `IPAddressPool` manifest in step 3 above.

### Failover IPs vs. additional IPs

| Type | Use case | Movable between servers? |
|---|---|---|
| Additional IP | Permanently assigned to one server | No |
| Failover IP | High-availability; can be moved to another server via API | Yes |

For a single-server OpenShift cluster both types work identically from MetalLB's point of view. Use a Failover IP if you might migrate the cluster to a different Hetzner server later.
