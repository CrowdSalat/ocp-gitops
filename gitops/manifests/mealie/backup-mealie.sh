#!/bin/bash
#
# Mealie Backup Script
# Creates a backup of recipes, ingredients, settings, and other data via the Mealie API
#

set -euo pipefail

# Configuration
MEALIE_URL="${MEALIE_URL:-https://mealie.apps.ocp.jharings.de}"
API_TOKEN="${MEALIE_API_TOKEN:-}"
BACKUP_TAG="backup-$(date +%Y-%m-%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-./backups}"

# Validate API token
if [[ -z "$API_TOKEN" ]]; then
  echo "Error: MEALIE_API_TOKEN environment variable is not set"
  echo "Usage: MEALIE_API_TOKEN=your-token $0"
  exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

echo "Creating Mealie backup with tag: $BACKUP_TAG"

# Create backup via API
RESPONSE=$(curl -s -w "\n%{http_code}" -X 'POST' \
  "${MEALIE_URL}/api/backups/export/database" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"tag\": \"${BACKUP_TAG}\",
    \"options\": {
      \"recipes\": true,
      \"settings\": true,
      \"themes\": true,
      \"pages\": true,
      \"notifications\": true,
      \"categories\": true,
      \"tags\": true,
      \"tools\": true
    },
    \"templates\": []
  }")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  echo "✓ Backup created successfully"
  echo "Response: $BODY"

  # Extract filename from response if available (adjust based on actual API response)
  # You may need to parse the JSON response to get the backup filename
  # Example: FILENAME=$(echo "$BODY" | jq -r '.fileName')

  echo ""
  echo "To download the backup, use:"
  echo "curl -H 'Authorization: Bearer \$MEALIE_API_TOKEN' '${MEALIE_URL}/api/backups/<filename>/download' -o '${BACKUP_DIR}/<filename>'"
else
  echo "✗ Backup creation failed with HTTP status: $HTTP_CODE"
  echo "Response: $BODY"
  exit 1
fi
