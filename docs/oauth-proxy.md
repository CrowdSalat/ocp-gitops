# OpenShift OAuth Proxy

Red Hat docs: https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/using-service-accounts-in-applications#service-accounts-as-oauth-clients

## What it is

`openshift/oauth-proxy` is a reverse proxy sidecar that gates access to a backend service using OpenShift's built-in OAuth server. Unauthenticated requests are redirected to the cluster login page; once the user authenticates the proxy forwards the request to the upstream application.

No external identity provider, no Keycloak, no Authentik — it reuses whatever login method is already configured on the cluster (htpasswd, LDAP, OIDC, …).

## When to use it

Use it when an application has no authentication of its own (or weak authentication) and you want to restrict access to cluster users without deploying a separate identity provider.

Typical use case in this repo: TeddyCloud's web UI on port 8443 — it has no login screen and must not be publicly accessible without authentication.

## How it works

```
Client → Gateway (TLS terminated) → oauth-proxy sidecar (:8443) → app container (:8080 plain HTTP)
```

The proxy:

1. Checks for a valid session cookie on the request.
2. If missing / expired: redirects to `https://<cluster-oauth-server>/oauth/authorize`.
3. After login the OAuth server sends the user back with a code; the proxy exchanges it for a token and sets a session cookie.
4. Subsequent requests with the valid cookie are forwarded to the upstream app.

## Required pieces

### 1. ServiceAccount

The proxy authenticates **as a ServiceAccount**, which is registered as an OAuth client with the cluster. The `oauth-redirectreference` annotation tells the OAuth server which redirect URI to accept.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
  namespace: app-myapp
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: >
      {"kind":"OAuthRedirectReference","apiVersion":"v1",
       "reference":{"kind":"Route","name":"myapp"}}
```

If you expose the app via a Gateway (not a Route), use a literal redirect URI instead:

```yaml
    serviceaccounts.openshift.io/oauth-redirecturi.primary: https://myapp.example.com/oauth/callback
```

### 2. ClusterRoleBinding

The ServiceAccount needs `system:auth-delegator` to validate tokens with the API server.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: myapp-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: myapp
  namespace: app-myapp
```

### 3. Session secret

The proxy uses a random secret to sign session cookies. Generate one and store it as a Secret (use External Secrets / Infisical for this, not a plain Secret in git).

```bash
oc create secret generic myapp-proxy-session \
  --from-literal=session_secret="$(openssl rand -base64 32)" \
  -n app-myapp
```

### 4. Proxy sidecar in the Deployment

Add a second container alongside the application container. The proxy binds on `8443` (HTTPS) and forwards to the app on `8080` (plain HTTP).

```yaml
- name: oauth-proxy
  image: quay.io/openshift/origin-oauth-proxy:4.15
  args:
  - --https-address=:8443
  - --provider=openshift
  - --openshift-service-account=myapp
  - --upstream=http://localhost:8080
  - --tls-cert=/etc/tls/private/tls.crt
  - --tls-key=/etc/tls/private/tls.key
  - --cookie-secret-file=/etc/proxy/secrets/session_secret
  ports:
  - containerPort: 8443
    name: https-proxy
  volumeMounts:
  - name: proxy-tls
    mountPath: /etc/tls/private
    readOnly: true
  - name: proxy-session-secret
    mountPath: /etc/proxy/secrets
    readOnly: true
```

The TLS cert (`proxy-tls`) can be the app's existing cert secret. The upstream app container should be changed to listen only on `127.0.0.1` (or a loopback port) so it is not reachable without going through the proxy.

### 5. Service

Point the Service at the proxy port, not the app port:

```yaml
ports:
- name: https-proxy
  port: 8443
  targetPort: https-proxy
```

The app's original port (e.g. `8080`) should either be removed from the Service or kept only as a ClusterIP-internal port if other components need it.

## Restricting access further

By default any authenticated cluster user can access the app. To limit to specific groups or users pass additional flags:

```
--openshift-sar={"namespace":"app-myapp","resource":"services","verb":"get"}
```

This grants access only to users who can `get` Services in the app namespace — i.e. admins. Adjust the SAR to match your RBAC.

## Caveats

- **Token scope** — the proxy requests a token with scope `user:info`. It does not get access to cluster resources on behalf of the user.
- **Cookie lifetime** — default session duration is 168 h (7 days). Override with `--cookie-expire`.
- **Non-browser clients** — clients that cannot follow redirects (e.g. the Toniebox) must use a separate Service/port that bypasses the proxy entirely. In the TeddyCloud case port 443 (Toniebox mTLS) goes through a direct LoadBalancer Service and is unaffected.
- **Image version** — pin the proxy image to the same minor version as your cluster (e.g. `origin-oauth-proxy:4.15` for OCP 4.15) to avoid API incompatibilities.
