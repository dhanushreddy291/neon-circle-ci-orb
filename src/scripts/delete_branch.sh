#!/bin/bash
set -euo pipefail

NEON_API_KEY="${!PARAM_API_KEY:-}"
NEON_PROJECT_ID="${!PARAM_PROJECT_ID:-}"

if [ -z "$NEON_API_KEY" ]; then
  echo "Error: Neon API key is not set (expected in \$$PARAM_API_KEY)."
  exit 1
fi

if [ -z "$NEON_PROJECT_ID" ]; then
  echo "Error: Neon Project ID is not set (expected in \$$PARAM_PROJECT_ID)."
  exit 1
fi

BRANCH_ID="${PARAM_BRANCH_ID:-${NEON_BRANCH_ID:-}}"
if [ -z "$BRANCH_ID" ]; then
  echo "Error: No branch ID provided and NEON_BRANCH_ID is not set."
  echo "Either pass the 'branch_id' parameter or run 'create_branch' first."
  exit 1
fi

API_BASE="https://console.neon.tech/api/v2"
AUTH_HEADER="Authorization: Bearer ${NEON_API_KEY}"

echo "Deleting branch: $BRANCH_ID ..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
  "${API_BASE}/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}" \
  -H "$AUTH_HEADER" \
  -H "Content-Type: application/json" \
  -H "User-Agent: neon-circleci-orb")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  echo "Branch $BRANCH_ID deleted successfully."
elif [[ "$HTTP_CODE" -eq 404 ]]; then
  echo "Branch $BRANCH_ID not found (already deleted or expired via TTL). Skipping."
else
  echo "Warning: Delete request returned HTTP $HTTP_CODE."
  exit 1
fi
