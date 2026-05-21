# TODO

**How to add items:** Keep a short bullet list at the top as a task index (one bullet per open item). For each bullet, add a section below headed with the same short title; put details, decisions, links, and sub-steps only under that heading. New work should extend the index and add a matching section so the file stays scannable.

## Task index

- [Verify SCC vs. file capabilities behaviour against official docs](#verify-scc-vs-file-capabilities-behaviour-against-official-docs)
- [TeddyCloud web UI: add an auth proxy in front of it](#teddycloud-web-ui-add-an-auth-proxy-in-front-of-it)
- [Learn Gateway API terminology](#learn-gateway-api-terminology)
- [Fix "Unable to open session log" in TeddyCloud](#fix-unable-to-open-session-log-in-teddycloud)
- ~~[Create cert-manager Certificate for the ingress controller](#create-cert-manager-certificate-for-the-ingress-controller)~~ ✓


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

## TeddyCloud web UI: add an auth proxy in front of it

The old OpenShift `Route` has been removed intentionally. The web UI (port 8443) will only be re-exposed once an authentication layer sits in front of it, since TeddyCloud's UI has no built-in login.

**Chosen approach:** OpenShift OAuth proxy sidecar — integrates with the built-in OpenShift OAuth server, zero external IdP needed. See [`docs/oauth-proxy.md`](docs/oauth-proxy.md) for the full pattern.

**When ready:**
1. Add the `oauth-proxy` sidecar to `gitops/applications/teddycloud/deployment.yaml` (proxy on `:8443`, upstream `http://localhost:8080`).
2. Add a `ServiceAccount` with the OAuth redirect annotation and a `ClusterRoleBinding` for `system:auth-delegator`.
3. Create a session-secret `ExternalSecret` in `app-teddycloud` (pull from Infisical, do not commit the value).
4. Update `service.yaml` to expose the proxy port instead of the raw app port.
5. The existing Gateway listener on port 8443 and the cert-manager `Certificate` are already in place — no changes needed there.

---

## Learn Gateway API terminology

Read through the official Gateway API concepts and terminology docs to get fluent with the resource model (GatewayClass, Gateway, HTTPRoute, TLSRoute, TCPRoute, ReferenceGrant, etc.) and how they relate to each other.

**Starting point:** https://gateway-api.sigs.k8s.io/concepts/api-overview/

---

## Fix "Unable to open session log" in TeddyCloud

TeddyCloud logs `Unable to open session log` on startup. Investigate the cause (likely a missing or unwritable directory on the PVC) and fix it — either by ensuring the path exists/has correct permissions in the container entrypoint, or by adding an `initContainer` that creates the directory.

---

## Create cert-manager Certificate for the ingress controller

Replace the default OpenShift ingress controller certificate with one issued by cert-manager using the `letsencrypt-prod` ClusterIssuer and the Cloudflare DNS-01 solver.

**Steps:**
- Create a `Certificate` resource for `*.apps.ocp.jharings.de` (wildcard) in the `openshift-ingress` namespace, referencing `letsencrypt-prod`.
- Patch the `IngressController` (default) to use the resulting secret via `spec.defaultCertificate.name`.
- Add the manifests under `gitops/infra/cert-manager/` and grant Argo the necessary namespace-scoped rights in `argo-extra-permissions.yaml` if needed.
