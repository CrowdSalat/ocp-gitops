#!/usr/bin/env bash
# Patch the default IngressController to use the cert-manager-issued wildcard TLS secret.
# Run once after the Certificate ingress-wildcard in openshift-ingress is Ready.
set -euo pipefail

oc patch ingresscontroller default -n openshift-ingress-operator \
  --type=merge \
  -p '{"spec":{"defaultCertificate":{"name":"ingress-wildcard-tls"}}}'

echo "Patched. Waiting for router rollout..."
oc rollout status deployment/router-default -n openshift-ingress --timeout=120s
echo "Done. IngressController is now using ingress-wildcard-tls."
