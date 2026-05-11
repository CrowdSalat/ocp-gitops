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

**Goal:** Expose TeddyCloud on a stable external IP via Gateway API — both the Toniebox box connection (mTLS on port 443) and the web UI (HTTPS).

### TeddyCloud certificate architecture

TeddyCloud manages **two completely separate TLS contexts**:

| Port | Cert issued by | Stored on PVC | Who consumes the cert |
|------|----------------|---------------|----------------------|
| 443 (box) | TeddyCloud's own generated CA (`certs/server/ca.der`) | `certs/server/` | Toniebox — you must inject `certs/server/ca.der` into the box firmware as the replacement `CA.DER` |
| 8443 (web UI) | TeddyCloud's own generated CA (same or different cert) | `certs/server/` | Browser — self-signed, not trusted by default |

**Critical facts for port 443:**

- **No domain is required** for the box connection to work. The Toniebox does **not** verify the server cert's CN/SAN against the hostname it connects to — it only validates that the server cert was signed by the injected CA. You can therefore use a raw IP address with `--esp32-hostpatch`.
- **No cert-manager involvement** on port 443. The Gateway must pass TLS through untouched. If the gateway terminates TLS, TeddyCloud cannot see the box's client certificate and the mTLS handshake fails.
- TeddyCloud's `certs/server/ca.der` is generated on **first boot**. You must let TeddyCloud boot and initialise before extracting the CA to flash the box.

### Traffic model

| Traffic | Port | Gateway handling | Cert responsibility |
|---------|------|-----------------|---------------------|
| Toniebox box connection | 443 | **TLS Passthrough** — gateway forwards raw TCP, TeddyCloud terminates mTLS | TeddyCloud's self-generated server cert + CA |
| Web UI | 8443 | Keep the existing OpenShift `Route` (edge TLS, already works), **or** add a dedicated gateway HTTPS listener with a cert-manager cert for a proper FQDN | cert-manager (if via gateway); TeddyCloud self-signed (if via Route) |

The simplest path: use the Gateway **only** for port 443 (box), and keep the Route for the web UI. The Route already handles web UI TLS fine. Only add a 8443 gateway listener if you need the web UI on a specific external IP/hostname distinct from the ingress router.

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

**3. Boot TeddyCloud and let it generate its CA**

On first boot TeddyCloud writes `certs/server/ca.der` (its CA) to the PVC. This must exist before you can flash the box. Let the pod reach ready state (the startup probe on port 80 succeeds after cert generation, which can take a few minutes).

**4. Create a `Gateway` in `gitops/applications/teddycloud/`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: teddycloud
  namespace: app-teddycloud
  annotations:
    # Pin a specific IP from the MetalLB pool (recommended — you need a stable
    # IP to patch into the box firmware).
    metallb.universe.tf/loadBalancerIPs: "192.168.x.y"
spec:
  gatewayClassName: openshift-default
  listeners:
  - name: box-tls-passthrough
    port: 443
    protocol: TLS
    tls:
      mode: Passthrough          # TeddyCloud terminates mTLS; gateway sees raw TCP
    allowedRoutes:
      namespaces:
        from: Same
```

**5. Create a `TLSRoute` for box connections**

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
  # No hostnames field: match all SNI on this listener.
  # The box sends the original prod.de.tbs.toys SNI or the patched hostname —
  # we do not filter by SNI since we only have one backend here.
  rules:
  - backendRefs:
    - name: teddycloud
      port: 443
```

Note: `TLSRoute` is `v1alpha2`. If the OpenShift Gateway controller version does not support it, use `TCPRoute` instead (identical passthrough semantics, just no SNI visibility at the route level).

**6. Extract TeddyCloud's CA from the PVC**

```bash
# copy the generated CA off the PVC
oc cp app-teddycloud/<pod-name>:/teddycloud/certs/server/ca.der ./ca.der
```

This is the file you will inject into the box firmware as the replacement `CA.DER`.

**7. Flash the Toniebox with the fake CA and new hostname**

```bash
MAC=<box-mac-address>
GATEWAY_IP=192.168.x.y   # the external IP from step 4

# --- Extract firmware ---
esptool.py -b 921600 read_flash 0x0 0x800000 tb.esp32.bin

# --- Extract box certificates from firmware ---
mkdir -p certs/client/esp32 certs/client/${MAC}
teddycloud --esp32-extract tb.esp32.bin --destination certs/client/esp32

# --- Copy box certs to per-MAC dir and register as the active box ---
cp certs/client/esp32/CLIENT.DER certs/client/${MAC}/client.der
cp certs/client/esp32/PRIVATE.DER certs/client/${MAC}/private.der
cp certs/client/esp32/CA.DER     certs/client/${MAC}/ca.der
# First box: also set as the default client identity used by TeddyCloud
cp certs/client/${MAC}/client.der  certs/client/client.der
cp certs/client/${MAC}/private.der certs/client/private.der
cp certs/client/${MAC}/ca.der      certs/client/ca.der

# --- Build a patched firmware with TeddyCloud's CA and your IP ---
mkdir -p certs/client/esp32-fakeca
cp certs/client/esp32/CLIENT.DER  certs/client/esp32-fakeca/
cp certs/client/esp32/PRIVATE.DER certs/client/esp32-fakeca/
cp ./ca.der                        certs/client/esp32-fakeca/CA.DER   # TeddyCloud's CA

cp tb.esp32.bin tb.esp32.fakeca.bin
teddycloud --esp32-inject    tb.esp32.fakeca.bin --source certs/client/esp32-fakeca
teddycloud --esp32-hostpatch tb.esp32.fakeca.bin --hostname ${GATEWAY_IP}

# --- Flash ---
esptool.py -b 921600 write_flash 0x0 tb.esp32.fakeca.bin
```

After flashing: the box trusts TeddyCloud's CA and connects to `${GATEWAY_IP}:443` (passthrough → TeddyCloud).

**Prefer a hostname over a raw IP.** Patching in a raw IP works but means you must reflash the box if the external IP ever changes (MetalLB pool reallocation, cluster migration, etc.). If you pass a hostname instead, the box resolves it via DNS at connection time — an IP change then only requires updating a DNS record:

```bash
# Better: use a local hostname resolvable from the box's WiFi network
teddycloud --esp32-hostpatch tb.esp32.fakeca.bin --hostname teddycloud.home.example.com
```

Add a local DNS A-record on your home router or Pi-hole pointing `teddycloud.home.example.com` → `<GATEWAY_IP>`. Since the box is always on home WiFi it will use the same DNS server, so a public DNS entry is not required. The hostname does **not** need to match the TeddyCloud server cert's CN — the box only validates the CA chain, not the hostname.

**8. Upload box certs to TeddyCloud**

Copy the per-MAC cert files from your local machine into the PVC so TeddyCloud can authenticate the box's client certificate:

```bash
oc cp certs/client/${MAC}/client.der app-teddycloud/<pod-name>:/teddycloud/certs/client/${MAC}/client.der
oc cp certs/client/${MAC}/private.der app-teddycloud/<pod-name>:/teddycloud/certs/client/${MAC}/private.der
oc cp certs/client/${MAC}/ca.der      app-teddycloud/<pod-name>:/teddycloud/certs/client/${MAC}/ca.der
# If first box, also set as the default:
oc cp certs/client/client.der  app-teddycloud/<pod-name>:/teddycloud/certs/client/client.der
oc cp certs/client/private.der app-teddycloud/<pod-name>:/teddycloud/certs/client/private.der
oc cp certs/client/ca.der      app-teddycloud/<pod-name>:/teddycloud/certs/client/ca.der
```

**9. (Optional) Add web UI to the Gateway**

If you want the web UI on the same external IP rather than via the OpenShift ingress Route, add a second listener to the Gateway and a cert-manager Certificate:

```yaml
# Add to the Gateway's listeners:
  - name: web-https
    port: 8443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: teddycloud-tls
        kind: Secret
    allowedRoutes:
      namespaces:
        from: Same
```

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: teddycloud-tls
  namespace: app-teddycloud
spec:
  secretName: teddycloud-tls
  dnsNames:
  - teddycloud.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
---
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

Then remove `gitops/applications/teddycloud/route.yaml`.

### Sequence summary (critical ordering)

```
1. Deploy teddycloud pod (custom image)
2. Wait for first-boot cert generation (startup probe passes)
3. Apply Gateway + TLSRoute → note the assigned external IP
4. Extract certs/server/ca.der from PVC
5. Flash Toniebox with fake CA + --esp32-hostpatch <external-IP>
6. Upload box client certs to PVC
7. Box connects → TeddyCloud authenticates mTLS → working
```

### Caveats

- **Use a hostname, not a raw IP** — patch with `--esp32-hostpatch teddycloud.home.example.com` and keep a local DNS A-record pointing at the Gateway IP. If the IP ever changes, update DNS only — no reflash. Still pin the IP in MetalLB (`metallb.universe.tf/loadBalancerIPs`) for stability, but the hostname is the escape hatch if it does change.
- **`TLSRoute` is `v1alpha2`** — fall back to `TCPRoute` if the controller does not support it.
- **`oc cp` vs. ConfigMap/Secret** — the box client certs contain private keys and should not be stored in git. Use `oc cp` directly to the PVC or a sealed-secret / external-secret if you want GitOps coverage.
