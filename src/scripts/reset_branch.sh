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

API_BASE="https://console.neon.tech/api/v2"
AUTH_HEADER="Authorization: Bearer ${NEON_API_KEY}"
CONTENT_TYPE="Content-Type: application/json"
USER_AGENT="User-Agent: neon-circleci-orb"

BRANCH_ID="$PARAM_BRANCH_ID"

urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))" 2>/dev/null \
    || printf '%s' "$1" | jq -sRr @uri
}

if [[ ! "$BRANCH_ID" =~ ^br- ]]; then
  echo "Resolving branch name '$BRANCH_ID' to ID..."
  ENCODED_NAME=$(urlencode "$BRANCH_ID")
  SEARCH_RESPONSE=$(curl -s -X GET \
    "${API_BASE}/projects/${NEON_PROJECT_ID}/branches?search=${ENCODED_NAME}" \
    -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -H "$USER_AGENT")
  RESOLVED_ID=$(echo "$SEARCH_RESPONSE" | jq -r --arg name "$BRANCH_ID" \
    '.branches[] | select(.name == $name or .id == $name) | .id' 2>/dev/null | head -n1)
  if [ -z "$RESOLVED_ID" ]; then
    echo "Error: Branch '$BRANCH_ID' not found."
    exit 1
  fi
  echo "Resolved: $BRANCH_ID -> $RESOLVED_ID"
  BRANCH_ID="$RESOLVED_ID"
fi

PAYLOAD="{}"
if [ -n "$PARAM_PARENT_BRANCH" ]; then
  ENCODED_PARENT=$(urlencode "$PARAM_PARENT_BRANCH")
  PARENT_RESPONSE=$(curl -s -X GET \
    "${API_BASE}/projects/${NEON_PROJECT_ID}/branches?search=${ENCODED_PARENT}" \
    -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -H "$USER_AGENT")
  PARENT_ID=$(echo "$PARENT_RESPONSE" | jq -r --arg name "$PARAM_PARENT_BRANCH" \
    '.branches[] | select(.name == $name or .id == $name) | .id' 2>/dev/null | head -n1)
  if [ -z "$PARENT_ID" ]; then
    echo "Error: Parent branch '$PARAM_PARENT_BRANCH' not found."
    exit 1
  fi
  echo "Parent branch resolved: $PARAM_PARENT_BRANCH -> $PARENT_ID"
  PAYLOAD=$(jq -n --arg pid "$PARENT_ID" '{ parent_id: $pid }')
fi

echo "Resetting branch $BRANCH_ID..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "${API_BASE}/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/reset" \
  -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -H "$USER_AGENT" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  echo "Branch $BRANCH_ID reset successfully."
else
  echo "Error: Reset request returned HTTP $HTTP_CODE"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
  exit 1
fi
