#!/usr/bin/env bash
# Bootstrap Cloudflare DNS API token for cert-manager DNS-01 challenge.
#
# What this script does:
#   1. Opens the Cloudflare API tokens page in your browser
#   2. Prompts you to paste the token (Zone:DNS:Edit scoped to DOMAIN)
#   3. Logs you in to Infisical via browser (same as bootstrap-infisical-credentials-cli.sh)
#   4. Creates the /cert-manager folder in Infisical if it doesn't exist
#   5. Saves the token to Infisical project "ocp", env "prod", path /cert-manager
#
# Prerequisites: infisical CLI, curl, jq
# Optional: xdg-open (Linux) or open (macOS) for automatic browser opening
set -euo pipefail

DOMAIN="${DOMAIN:-jharings.de}"
INFISICAL_HOST="${INFISICAL_HOST:-https://eu.infisical.com}"
export INFISICAL_DOMAIN="${INFISICAL_HOST}"
INFISICAL_PROJECT="ocp"
INFISICAL_ENV="prod"
INFISICAL_SECRET_NAME="CLOUDFLARE_API_TOKEN"
INFISICAL_PATH="/"

CF_TOKEN_URL="https://dash.cloudflare.com/profile/api-tokens"

# ── Step 1: Guide the user to create a Cloudflare token ──────────────────────
echo
echo "==> Cloudflare API token setup"
echo "    You need a token with these permissions:"
echo "      Zone › DNS › Edit   (for zone: ${DOMAIN})"
echo "    Suggested token name: cert-manager-${DOMAIN}"
echo
echo "    Opening Cloudflare API tokens page..."

if command -v xdg-open &>/dev/null; then
  xdg-open "${CF_TOKEN_URL}" 2>/dev/null || true
elif command -v open &>/dev/null; then
  open "${CF_TOKEN_URL}" || true
else
  echo "    ↳ Please open manually: ${CF_TOKEN_URL}"
fi

echo
echo "    Create the token in the browser, then come back here."
echo
read -rsp "Paste the Cloudflare API token: " CF_API_TOKEN
echo

ZONE_SUMMARY="${DOMAIN}"

# ── Step 4: Infisical login ────────────────────────────────────────────────────
echo
echo "==> Logging in to Infisical (browser will open)..."
infisical login --domain "${INFISICAL_HOST}"
INFISICAL_TOKEN=$(infisical user get token --plain)

infisical_api_get() {
  curl -fsSL \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    "${INFISICAL_HOST}/api${1}"
}
infisical_api_post() {
  curl -fsSL \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "${2}" \
    "${INFISICAL_HOST}/api${1}"
}
infisical_api_patch() {
  curl -fsSL \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    -H "Content-Type: application/json" \
    -X PATCH -d "${2}" \
    "${INFISICAL_HOST}/api${1}"
}

# ── Step 5: Look up the Infisical project ID ──────────────────────────────────
echo "==> Looking up Infisical project '${INFISICAL_PROJECT}'..."
PROJECT_ID=$(infisical_api_get "/v1/workspace" \
  | jq -r --arg name "${INFISICAL_PROJECT}" \
    '.workspaces[] | select(.name == $name) | .id // empty')

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: Infisical project '${INFISICAL_PROJECT}' not found." >&2
  exit 1
fi
echo "    Project ID: ${PROJECT_ID}"

# ── Step 6: Ensure the target folder exists (skip for root) ──────────────────
FOLDER_NAME="${INFISICAL_PATH#/}"  # strip leading slash; empty string means root
if [[ -n "${FOLDER_NAME}" ]]; then
  echo "==> Ensuring folder '${INFISICAL_PATH}' exists..."
  FOLDER_CHECK=$(infisical_api_get \
    "/v1/folders?workspaceId=${PROJECT_ID}&environment=${INFISICAL_ENV}&path=/")
  FOLDER_ID=$(echo "${FOLDER_CHECK}" \
    | jq -r --arg name "${FOLDER_NAME}" \
      '.folders[] | select(.name == $name) | .id // empty')

  if [[ -z "${FOLDER_ID}" ]]; then
    echo "    Not found — creating..."
    infisical_api_post "/v1/folders" \
      "{\"workspaceId\":\"${PROJECT_ID}\",\"environment\":\"${INFISICAL_ENV}\",\"name\":\"${FOLDER_NAME}\",\"path\":\"/\"}" \
      >/dev/null
    echo "    Created."
  else
    echo "    Already exists (${FOLDER_ID})."
  fi
else
  echo "==> Using root path — no folder creation needed."
fi

# ── Step 7: Upsert the secret via API ────────────────────────────────────────
echo "==> Saving ${INFISICAL_SECRET_NAME} to Infisical..."

SECRET_HTTP=$(curl -sS \
  -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
  -o /dev/null -w "%{http_code}" \
  "${INFISICAL_HOST}/api/v3/secrets/raw/${INFISICAL_SECRET_NAME}?workspaceId=${PROJECT_ID}&environment=${INFISICAL_ENV}&secretPath=${INFISICAL_PATH}")

SECRET_PAYLOAD=$(jq -n \
  --arg wid  "${PROJECT_ID}" \
  --arg env  "${INFISICAL_ENV}" \
  --arg path "${INFISICAL_PATH}" \
  --arg val  "${CF_API_TOKEN}" \
  '{workspaceId:$wid, environment:$env, secretPath:$path, secretValue:$val}')

if [[ "${SECRET_HTTP}" == "200" ]]; then
  echo "    Secret exists — updating..."
  infisical_api_patch \
    "/v3/secrets/raw/${INFISICAL_SECRET_NAME}" \
    "${SECRET_PAYLOAD}" >/dev/null
else
  echo "    Secret not found — creating..."
  infisical_api_post \
    "/v3/secrets/raw/${INFISICAL_SECRET_NAME}" \
    "${SECRET_PAYLOAD}" >/dev/null
fi
echo "    Saved."

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────────────────────"
echo "  Cloudflare zone:     ${ZONE_SUMMARY}"
echo "  Infisical project:   ${INFISICAL_PROJECT} (${PROJECT_ID})"
echo "  Infisical secret:    ${INFISICAL_PATH%/}/${INFISICAL_SECRET_NAME}"
echo "─────────────────────────────────────────────────────────"
echo
echo "Next steps:"
echo "  1. Commit and apply gitops/infra/cert-manager/ to the cluster."
echo "  2. The ExternalSecret will pull the token into namespace openshift-cert-manager."
echo "  3. Create a ClusterIssuer referencing the cloudflare-api-token Secret."
