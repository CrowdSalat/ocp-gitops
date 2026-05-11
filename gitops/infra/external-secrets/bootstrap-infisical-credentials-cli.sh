#!/usr/bin/env bash
# Same as bootstrap-infisical-credentials.sh but uses the Infisical CLI for
# browser-based login instead of requiring a manually created personal token.
#
# Machine identity management itself is API-only (the CLI has no commands for
# it), so after the browser login the session JWT is extracted from the CLI and
# reused for all subsequent API calls.
#
# Prerequisites: infisical CLI, curl, jq, oc (logged in to the cluster)
set -euo pipefail

INFISICAL_HOST="${INFISICAL_HOST:-https://eu.infisical.com}"
export INFISICAL_DOMAIN="${INFISICAL_HOST}"
IDENTITY_NAME="ocp-hetzner"
PROJECT_NAME="ocp"
K8S_NS="external-secrets-operator"
K8S_SECRET="infisical-credentials"

# ---------- early exit ----------
if oc get secret "${K8S_SECRET}" -n "${K8S_NS}" &>/dev/null; then
  echo "Secret '${K8S_SECRET}' already exists in '${K8S_NS}' — nothing to do."
  echo "To rotate: oc delete secret ${K8S_SECRET} -n ${K8S_NS} && re-run."
  exit 0
fi

# ---------- login ----------
infisical login --domain "${INFISICAL_HOST}"
INFISICAL_TOKEN=$(infisical user get token --plain)

api_get() {
  curl -fsSL \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    "${INFISICAL_HOST}/api${1}"
}
api_post() {
  curl -fsSL \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "${2}" \
    "${INFISICAL_HOST}/api${1}"
}

# ---------- org (read from JWT, no API call needed) ----------
ORG_ID=$(echo "${INFISICAL_TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.organizationId')
echo "Org ID: ${ORG_ID}"

# ---------- project ----------
echo "Checking project '${PROJECT_NAME}'..."
PROJECT_ID=$(api_get "/v1/workspace" \
  | jq -r --arg name "${PROJECT_NAME}" \
    '.workspaces[] | select(.name == $name) | .id')

if [[ -z "${PROJECT_ID}" ]]; then
  echo "  Not found — creating..."
  PROJECT_ID=$(api_post "/v2/workspace" \
    "{\"projectName\":\"${PROJECT_NAME}\",\"type\":\"secret-manager\"}" \
    | jq -r '.project.id')
fi
echo "  → ${PROJECT_ID}"

# ---------- machine identity ----------
echo "Checking machine identity '${IDENTITY_NAME}'..."
IDENTITY_ID=$(api_get "/v1/identities?orgId=${ORG_ID}" \
  | jq -r --arg name "${IDENTITY_NAME}" \
    '.identities[] | select(.identity.name == $name) | .identity.id // empty')

if [[ -z "${IDENTITY_ID}" ]]; then
  echo "  Creating..."
  IDENTITY_ID=$(api_post "/v1/identities" \
    "{\"name\":\"${IDENTITY_NAME}\",\"organizationId\":\"${ORG_ID}\",\"role\":\"no-access\"}" \
    | jq -r '.identity.id')
fi
echo "  → ${IDENTITY_ID}"

# ---------- project membership ----------
echo "Checking project membership..."
IS_MEMBER=$(api_get "/v1/projects/${PROJECT_ID}/memberships/identities?identityName=${IDENTITY_NAME}" \
  | jq -r '.identityMemberships | length')

if [[ "${IS_MEMBER}" == "0" ]]; then
  echo "  Adding to project with 'viewer' role..."
  api_post "/v1/projects/${PROJECT_ID}/memberships/identities/${IDENTITY_ID}" \
    '{"role":"viewer"}' >/dev/null
else
  echo "  Already a member."
fi

# ---------- universal auth ----------
echo "Checking Universal Auth..."
UA_JSON=$(api_get "/v1/auth/universal-auth/identities/${IDENTITY_ID}" 2>/dev/null || echo "{}")
if echo "${UA_JSON}" | jq -e '.identityUniversalAuth' &>/dev/null; then
  CLIENT_ID=$(echo "${UA_JSON}" | jq -r '.identityUniversalAuth.clientId')
  echo "  Already attached. Client ID: ${CLIENT_ID}"
else
  echo "  Attaching..."
  CLIENT_ID=$(api_post "/v1/auth/universal-auth/identities/${IDENTITY_ID}" '{}' \
    | jq -r '.identityUniversalAuth.clientId')
  echo "  Client ID: ${CLIENT_ID}"
fi

# ---------- client secret ----------
echo "Creating client secret..."
CLIENT_SECRET=$(api_post \
  "/v1/auth/universal-auth/identities/${IDENTITY_ID}/client-secrets" \
  '{"description":"ocp-hetzner ESO","numUsesLimit":0,"ttl":0}' \
  | jq -r '.clientSecret')

# ---------- k8s secret ----------
echo "Applying Kubernetes Secret..."
oc create secret generic "${K8S_SECRET}" \
  --namespace "${K8S_NS}" \
  --from-literal=clientId="${CLIENT_ID}" \
  --from-literal=clientSecret="${CLIENT_SECRET}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Done."
