# TODO

**How to add items:** Keep a short bullet list at the top as a task index (one bullet per open item). For each bullet, add a section below headed with the same short title; put details, decisions, links, and sub-steps only under that heading. New work should extend the index and add a matching section so the file stays scannable.

## Task index

- [Verify SCC vs. file capabilities behaviour against official docs](#verify-scc-vs-file-capabilities-behaviour-against-official-docs)
- [Expose TeddyCloud via Gateway API with an external IP](#expose-teddycloud-via-gateway-api-with-an-external-ip)
- [Disable Cursor commit attribution](#disable-cursor-commit-attribution)


---

## Verify SCC vs. file capabilities behaviour against official docs

Gemini and Claude gave contradictory information about whether `securityContext.capabilities.add` alone (without `setcap` on the binary) is sufficient to grant a capability to a container process. Specifically the disputed claim is "Path A: no setcap needed, CRI-O grants it to the whole container".

**What to look up:**

- OpenShift official docs on SCCs and Linux capabilities — search for `NET_BIND_SERVICE` + `allowPrivilegeEscalation`
- Red Hat blog / solution articles on running containers on privileged ports without root
- Kernel `capabilities(7)` man page, specifically the `execve` transformation rules and the `no_new_privs` section
- OpenShift `restricted-v2` SCC definition — check `allowedCapabilities` and `defaultAddCapabilities` fields

**The specific question to resolve:**

Does `capabilities.add: [NET_BIND_SERVICE]` in the pod spec, with `allowPrivilegeEscalation: false`, cause `NET_BIND_SERVICE` to appear in the running process's `CapEff` **without** any `setcap` on the binary?

Based on current understanding: **No** — the `execve` formula resets `CapPrm`/`CapEff` to zero for any binary without file capabilities, regardless of what the OCI spec configured before exec. The only escape hatch is ambient capabilities, which Kubernetes does not expose via the standard pod spec.

**Good starting points:**
- https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html
- https://www.redhat.com/en/blog/linux-capabilities-in-openshift
- `man 7 capabilities` → section "Effect of user ID changes on capabilities" and "Transformation of capabilities during execve()"

---

## Disable Cursor commit attribution

Cursor automatically appends `Co-authored-by: Cursor <cursoragent@cursor.com>` to every commit made by the agent. The git-commit-style rule forbids trailer lines.

**Fix:** Go to **Cursor Settings → Agent → Attribution** and turn off the Co-authored-by option.

---

## Expose TeddyCloud via Gateway API with an external IP

**Goal:** Replace the existing OpenShift `Route` with Gateway API resources so TeddyCloud is reachable on a stable external IP — both the web UI (HTTPS) and the Toniebox box connection (mTLS on port 443).

### Why not just keep the Route?

The OpenShift `Route` currently handles only the web UI (edge TLS on port 80 → HTTPS). It cannot expose raw TCP/TLS passthrough for port 443, which is **required** for Toniebox box connections: the box uses mutual TLS with TeddyCloud's own CA and the TLS session must reach TeddyCloud unmodified. A gateway that terminates TLS on port 443 will break the box handshake.

### Traffic model

| Traffic | Port | Protocol | Gateway handling |
|---------|------|----------|-----------------|
| Toniebox box connection | 443 | TLS (mTLS, TeddyCloud CA) | **Passthrough** — TLS must not be terminated at the gateway; TeddyCloud itself terminates and validates client certs |
| Web UI | 8443 | HTTPS | TLS termination at gateway with a cert-manager certificate; backend on port 8443 (already TLS) or 80 with re-encrypt |

Putting both listeners on the same `Gateway` is fine; the gateway distinguishes them by port.

### Step-by-step

**1. Fix the deployment image**

The deployment currently uses the upstream image `ghcr.io/toniebox-reverse-engineering/teddycloud:tc_v0.6.8`, which requires root to bind ports 80/443. Switch to the custom `teddycloud-ocp` wrapper image (built via `teddycloud-ocp/build-push.sh`) that has `cap_net_bind_service=+ep` stamped on the binary so `restricted-v2` SCC is satisfied.

```yaml
image: docker.io/<DOCKERHUB_USER>/teddycloud-ocp:tc_v0.6.8
```

**2. Verify or provision an external IP mechanism**

Gateway API on OCP creates a `LoadBalancer` Service for each `Gateway`. On a bare-metal cluster you need MetalLB (or similar) to assign an IP from an `IPAddressPool`. Confirm:
- MetalLB operator is installed and an `IPAddressPool` + `L2Advertisement` exist, or
- The cluster has a cloud provider that hands out LB IPs automatically.

If MetalLB is not yet installed, add it to `gitops/infra/` as part of the infra ApplicationSet task.

**3. Create a `Gateway` in `gitops/applications/teddycloud/`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: teddycloud
  namespace: app-teddycloud
  annotations:
    # Optional: pin a specific IP from the MetalLB pool
    # metallb.universe.tf/loadBalancerIPs: "192.168.x.y"
spec:
  gatewayClassName: openshift-default
  listeners:
  - name: box-tls-passthrough
    port: 443
    protocol: TLS
    tls:
      mode: Passthrough          # TeddyCloud terminates mTLS itself
    allowedRoutes:
      namespaces:
        from: Same
  - name: web-https
    port: 8443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: teddycloud-tls    # cert-manager Certificate (see step 4)
        kind: Secret
    allowedRoutes:
      namespaces:
        from: Same
```

**4. Issue a TLS certificate for the web UI listener**

Create a `Certificate` (cert-manager) and `Issuer`/`ClusterIssuer` for the web UI hostname. The `Secret` name must match `certificateRefs` above.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: teddycloud-tls
  namespace: app-teddycloud
spec:
  secretName: teddycloud-tls
  dnsNames:
  - teddycloud.example.com     # replace with your actual hostname
  issuerRef:
    name: letsencrypt-prod      # or your ClusterIssuer
    kind: ClusterIssuer
```

**5. Create a `TLSRoute` for Toniebox box connections (port 443 passthrough)**

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: teddycloud-box
  namespace: app-teddycloud
spec:
  parentRefs:
  - name: teddycloud
    sectionName: box-tls-passthrough
  rules:
  - backendRefs:
    - name: teddycloud
      port: 443
```

`TLSRoute` with a `Passthrough` listener routes based on SNI. The Toniebox sends the prod hostname as SNI; you either need to match that SNI or leave it open (no `hostnames` field = match all SNI on that listener). The TeddyCloud box override DNS entry on the box is what points the box to this external IP.

**6. Create an `HTTPRoute` for the web UI (port 8443)**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: teddycloud-web
  namespace: app-teddycloud
spec:
  parentRefs:
  - name: teddycloud
    sectionName: web-https
  hostnames:
  - teddycloud.example.com
  rules:
  - backendRefs:
    - name: teddycloud
      port: 8443
```

**7. Remove the old OpenShift `Route`**

Delete or remove `gitops/applications/teddycloud/route.yaml` (or keep it during transition and remove once the Gateway is healthy).

**8. DNS**

- Point `teddycloud.example.com` (web UI) at the Gateway's external IP.
- For box connections: configure the Toniebox to use TeddyCloud's DNS override so it resolves `prod.de.tbs.toys` to the same external IP (port 443).

### Caveats / open questions

- **`TLSRoute` API stability:** `TLSRoute` is `v1alpha2` — confirm the OpenShift Gateway controller version supports it. If not, fall back to `TCPRoute` (same passthrough semantics, no SNI filtering).
- **Port 80 redirect:** If you want an HTTP→HTTPS redirect for the web UI, add a second listener on port 80 with an `HTTPRoute` that returns a 301. This is optional since the old Route already does this.
- **mTLS CA bootstrap:** On first boot TeddyCloud generates its own CA under `/teddycloud/certs` on the PVC. The Toniebox must be provisioned with that CA. Passthrough is essential for this to work end-to-end.
- **MetalLB vs node port:** If MetalLB is unavailable, an alternative is `NodePort` + a static IP on a node. That is fragile; prefer MetalLB.
