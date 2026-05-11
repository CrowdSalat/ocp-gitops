# External Secrets Operator + Infisical

Red Hat docs: https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift

## What is configured

ESO pulls secrets from Infisical (`eu.infisical.com`, project `ocp`, environment `prod`) and creates Kubernetes `Secret` objects.

Authentication uses a machine identity named `ocp-hetzner` with Universal Auth. The credentials are stored in the `infisical-credentials` Secret in `external-secrets-operator` — **not in git**. Run the bootstrap script to create them:

```bash
./gitops/infra/external-secrets/bootstrap-infisical-credentials-cli.sh
```

To rotate: `oc delete secret infisical-credentials -n external-secrets-operator` then re-run.

## Network policies

The operator creates a `deny-all-traffic` policy by default. Egress rules are configured via `ExternalSecretsConfig` (not via separate `NetworkPolicy` objects). This cluster allows HTTPS egress (port 443) only — IP-based restrictions are impractical since `eu.infisical.com` is behind Cloudflare.

## Caveats

**Infisical EU and US are separate accounts.** `eu.infisical.com` and `app.infisical.com` are independent instances — projects, machine identities, and secrets do not sync between them. Logging in to one does not give access to the other. When running the CLI always pass `--domain https://eu.infisical.com` (or set it permanently with `infisical config set domain https://eu.infisical.com`) to avoid accidentally authenticating against the US instance.

## Adding secrets

Add an `ExternalSecret` referencing the `ClusterSecretStore`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: infisical
    kind: ClusterSecretStore
  target:
    name: my-secret
    creationPolicy: Owner
  data:
  - secretKey: my-key
    remoteRef:
      key: MY_INFISICAL_SECRET_NAME
```
