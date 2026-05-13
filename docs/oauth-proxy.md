# OpenShift OAuth Proxy

Red Hat docs: https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/using-service-accounts-in-applications#service-accounts-as-oauth-clients

## What it is

`openshift/oauth-proxy` is a reverse-proxy sidecar that gates a backend service behind the cluster's built-in OAuth server. Unauthenticated requests are redirected to the OCP login page; once the user authenticates the proxy forwards the request to the upstream application.

No external identity provider needed — it reuses whatever login method is configured on the cluster (htpasswd, LDAP, OIDC, …). All authenticated cluster users can access the app by default; access can be narrowed with `--openshift-sar` (see below).

## Traffic flow

```
Browser → OCP Router (edge TLS, wildcard cert)
        → Route → Service :4180
        → oauth-proxy sidecar :4180 (plain HTTP, --http-address)
        → App container :80 (localhost, plain HTTP)
```

The proxy:
1. Checks for a valid session cookie.
2. If missing: redirects to the cluster OAuth server.
3. After login the OAuth server redirects back with a code; the proxy exchanges it for a token, sets a signed session cookie, and forwards the original request.
4. Subsequent requests with a valid cookie go straight to the upstream.

## Files to add / change

Given an existing app with a `Deployment` and a `Service`, add these six pieces:

### 1. `serviceaccount.yaml` — the OAuth client identity

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: <app>
  namespace: <app-namespace>
  annotations:
    # Tell the OAuth server which Route hosts the callback URL.
    # Use oauth-redirecturi.primary (literal URL) if you expose via
    # Gateway/HTTPRoute instead of a Route.
    serviceaccounts.openshift.io/oauth-redirectreference.primary: >
      {"kind":"OAuthRedirectReference","apiVersion":"v1",
       "reference":{"kind":"Route","name":"<route-name>"}}
```

### 2. `clusterrolebinding.yaml` — token validation

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: <app>-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: <app>
  namespace: <app-namespace>
```

### 3. `externalsecret-proxy-session.yaml` — cookie signing key

The proxy signs its session cookies with a random secret. Store it in Infisical (key name of your choice) and pull it via ExternalSecret — never commit the value to git.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-proxy-session
  namespace: <app-namespace>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical
  target:
    name: <app>-proxy-session
  data:
  - secretKey: session_secret
    remoteRef:
      key: <INFISICAL_KEY_NAME>
```

Generate a suitable value once (at least 16 bytes):

```bash
openssl rand -base64 32
```

### 4. `route.yaml` — edge-terminated HTTPS (wildcard cert automatic)

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: <route-name>
  namespace: <app-namespace>
spec:
  host: <app>.apps.ocp.jharings.de
  to:
    kind: Service
    name: <app>
  port:
    targetPort: proxy
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

The OCP Router applies the wildcard ingress cert automatically — no `Certificate` resource needed.

### 5. `service.yaml` — expose the proxy port

Replace the existing web-UI port with the proxy port (or add it alongside if other components still need the raw app port):

```yaml
ports:
- name: proxy
  port: 4180
  targetPort: proxy
  protocol: TCP
```

### 6. `deployment.yaml` — sidecar and volumes

Three changes to an existing Deployment:

**a) Set the ServiceAccount on the pod spec:**

```yaml
spec:
  serviceAccountName: <app>
```

**b) Add the sidecar container:**

```yaml
- name: oauth-proxy
  image: quay.io/openshift/origin-oauth-proxy:4.16
  args:
  - --http-address=:4180
  - --https-address=          # must be explicit; default is :443 which crashes without a cert
  - --provider=openshift
  - --openshift-service-account=<app>
  - --upstream=http://localhost:<app-http-port>
  - --cookie-secret-file=/etc/proxy/secrets/session_secret
  - --openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  ports:
  - name: proxy
    containerPort: 4180
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop:
      - ALL
  volumeMounts:
  - name: proxy-session-secret
    mountPath: /etc/proxy/secrets
    readOnly: true
```

**c) Add the session-secret volume:**

```yaml
volumes:
- name: proxy-session-secret
  secret:
    secretName: <app>-proxy-session
```

## Checklist

- [ ] ServiceAccount created with `oauth-redirectreference` annotation pointing at the Route
- [ ] ClusterRoleBinding `system:auth-delegator` for the ServiceAccount
- [ ] Secret value stored in Infisical; ExternalSecret created
- [ ] Route created with `tls.termination: edge`
- [ ] Service updated to expose port `4180` (named `proxy`)
- [ ] Deployment updated: `serviceAccountName`, sidecar container, `proxy-session-secret` volume

## Image version

Pin the image to the same minor stream as the cluster:

```
quay.io/openshift/origin-oauth-proxy:4.16   # for OCP 4.21.x
```

The origin-oauth-proxy minor version does not need to match OCP exactly but should be close. Avoid `latest` in GitOps.

## Restricting access to specific users or groups

By default any authenticated cluster user can reach the app. To restrict further, add `--openshift-sar`:

```
- --openshift-sar={"namespace":"<app-namespace>","resource":"services","verb":"get"}
```

This grants access only to users who can `get` Services in the app namespace (i.e. admins with namespace access). Adjust the SAR predicate to match your RBAC.

## Caveats

### `--https-address=` must be set explicitly

The proxy defaults `--https-address=:443` even when `--http-address` is specified. Without an explicit `--https-address=` (empty string), the proxy tries to load a TLS cert, fails with `FATAL: loading tls config (, ) failed - missing filename for serving cert`, and crash-loops. Always include the empty flag when using plain-HTTP mode behind an edge-terminated Route.

### Session cookie vs. OCP OAuth

The session secret is **not** an OCP credential — it only signs the proxy's own session cookie. Losing or rotating it invalidates all active sessions (users must log in again) but has no other side effect. OCP's OAuth server handles the actual authentication.

### Non-browser clients

Clients that cannot follow HTTP redirects (e.g. the Toniebox) must bypass the proxy via a separate Service and port. Protect that port at the network level (LoadBalancer Service with a fixed IP, firewall rules, etc.).

### Gateway API alternative

If the app is exposed via Gateway API (HTTPRoute) instead of a Route, replace the `oauth-redirectreference` annotation with a literal URI:

```yaml
serviceaccounts.openshift.io/oauth-redirecturi.primary: https://<host>/oauth/callback
```

And adjust the Gateway listener + HTTPRoute to target the proxy port.
