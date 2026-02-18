#!/bin/bash
set -euo pipefail

NEON_API_KEY="${!PARAM_API_KEY:-}"
NEON_PROJECT_ID="${!PARAM_PROJECT_ID:-}"

if [ -z "$NEON_API_KEY" ]; then
  echo "Error: Neon API key is not set. Please set \
$NEON_API_KEY in CircleCI project settings."
  exit 1
fi

if [ -z "$NEON_PROJECT_ID" ]; then
  echo "Error: Neon Project ID is not set. Please set \
$NEON_PROJECT_ID in CircleCI project settings."
  exit 1
fi

API_BASE="https://console.neon.tech/api/v2"
AUTH_HEADER="Authorization: Bearer ${NEON_API_KEY}"
CONTENT_TYPE="Content-Type: application/json"
USER_AGENT="User-Agent: neon-circleci-orb"

neon_api() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local url="${API_BASE}${endpoint}"
  local response
  local http_code
  local body_response

  if [ -n "$body" ]; then
    response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
      -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -H "$USER_AGENT" -d "$body")
  else
    response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
      -H "$AUTH_HEADER" -H "$CONTENT_TYPE" -H "$USER_AGENT")
  fi

  http_code=$(echo "$response" | tail -n1)
  body_response=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    echo "Error: API request $method $endpoint returned HTTP $http_code" >&2
    echo "$body_response" | jq . 2>/dev/null >&2 || echo "$body_response" >&2
    return 1
  fi

  echo "$body_response"
}

# URL-encode a string using Python or jq as a fallback
urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))" 2>/dev/null \
    || printf '%s' "$1" | jq -sRr @uri
}

BRANCH_NAME="$PARAM_BRANCH_NAME"
if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME="${CIRCLE_PIPELINE_NUM:-0}"
  if [ -n "${CIRCLE_NODE_INDEX:-}" ]; then
    BRANCH_NAME="${BRANCH_NAME}-${CIRCLE_NODE_INDEX}"
  fi
fi

echo "Branch name: $BRANCH_NAME"

ENCODED_BRANCH_NAME=$(urlencode "$BRANCH_NAME")
EXISTING=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches?search=${ENCODED_BRANCH_NAME}")
EXISTING_BRANCH=$(echo "$EXISTING" | jq -r --arg name "$BRANCH_NAME" \
  '.branches[] | select(.name == $name) | .id' 2>/dev/null | head -n1)

BRANCH_CREATED="true"
if [ -n "$EXISTING_BRANCH" ]; then
  echo "Branch '$BRANCH_NAME' already exists (ID: $EXISTING_BRANCH). Reusing."
  BRANCH_ID="$EXISTING_BRANCH"
  BRANCH_CREATED="false"
else
  PARENT_ID=""
  if [ -n "$PARAM_PARENT_BRANCH" ]; then
    ENCODED_PARENT=$(urlencode "$PARAM_PARENT_BRANCH")
    PARENT_RESPONSE=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches?search=${ENCODED_PARENT}")
    PARENT_ID=$(echo "$PARENT_RESPONSE" | jq -r --arg name "$PARAM_PARENT_BRANCH" \
      '.branches[] | select(.name == $name or .id == $name) | .id' 2>/dev/null | head -n1)
    if [ -z "$PARENT_ID" ]; then
      echo "Error: Parent branch '$PARAM_PARENT_BRANCH' not found."
      exit 1
    fi
    echo "Parent branch resolved: $PARAM_PARENT_BRANCH -> $PARENT_ID"
  fi

  EXPIRES_AT=""
  if [ "$PARAM_TTL_SECONDS" -gt 0 ] 2>/dev/null; then
    EXPIRES_AT=$(date -u -d "+${PARAM_TTL_SECONDS} seconds" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
      || date -u -v+${PARAM_TTL_SECONDS}S "+%Y-%m-%dT%H:%M:%SZ")
    echo "Branch TTL: ${PARAM_TTL_SECONDS}s (expires at $EXPIRES_AT)"
  fi

  PAYLOAD=$(jq -n \
    --arg name "$BRANCH_NAME" \
    --arg parent_id "$PARENT_ID" \
    --arg expires_at "$EXPIRES_AT" \
    --arg schema_only "$PARAM_SCHEMA_ONLY" \
    '{
      branch: {
        name: $name
      },
      endpoints: [
        { type: "read_write" }
      ]
    }
    | if $parent_id != "" then .branch.parent_id = $parent_id else . end
    | if $expires_at != "" then .branch.expires_at = $expires_at else . end
    | if $schema_only == "true" then .branch.init_source = "schema-only" else . end
    ')

  echo "Creating branch..."
  CREATE_RESPONSE=$(neon_api POST "/projects/${NEON_PROJECT_ID}/branches" "$PAYLOAD")

  BRANCH_ID=$(echo "$CREATE_RESPONSE" | jq -r '.branch.id')
  if [ -z "$BRANCH_ID" ] || [ "$BRANCH_ID" = "null" ]; then
    echo "Error: Failed to extract branch ID from response."
    echo "$CREATE_RESPONSE" | jq .
    exit 1
  fi

  echo "Branch created: $BRANCH_ID"
fi

ENDPOINTS_RESPONSE=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/endpoints")
ENDPOINT_HOST=$(echo "$ENDPOINTS_RESPONSE" | jq -r '.endpoints[0].host')
ENDPOINT_ID=$(echo "$ENDPOINTS_RESPONSE" | jq -r '.endpoints[0].id')

if [ -z "$ENDPOINT_HOST" ] || [ "$ENDPOINT_HOST" = "null" ]; then
  echo "Error: No endpoint found for branch $BRANCH_ID."
  exit 1
fi

ENDPOINT_HOST_POOLED=$(echo "$ENDPOINT_HOST" | sed "s/${ENDPOINT_ID}/${ENDPOINT_ID}-pooler/")

DB_PASSWORD="$PARAM_PASSWORD"
if [ -z "$DB_PASSWORD" ]; then
  echo "Retrieving password for role '$PARAM_ROLE'..."
  PASSWORD_RESPONSE=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/roles/${PARAM_ROLE}/reveal_password")
  DB_PASSWORD=$(echo "$PASSWORD_RESPONSE" | jq -r '.password')
  if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "null" ]; then
    echo "Error: Could not retrieve password for role '$PARAM_ROLE'."
    echo "If password storage is disabled, pass the 'password' parameter explicitly."
    exit 1
  fi
fi

ENCODED_PASSWORD=$(urlencode "$DB_PASSWORD")
DATABASE_URL="postgresql://${PARAM_ROLE}:${ENCODED_PASSWORD}@${ENDPOINT_HOST}/${PARAM_DATABASE}?sslmode=require"
DATABASE_URL_POOLED="postgresql://${PARAM_ROLE}:${ENCODED_PASSWORD}@${ENDPOINT_HOST_POOLED}/${PARAM_DATABASE}?sslmode=require"

{
  echo "export DATABASE_URL=\"${DATABASE_URL}\""
  echo "export DATABASE_URL_POOLED=\"${DATABASE_URL_POOLED}\""
  echo "export PGHOST=\"${ENDPOINT_HOST}\""
  echo "export PGHOST_POOLED=\"${ENDPOINT_HOST_POOLED}\""
  echo "export PGUSER=\"${PARAM_ROLE}\""
  echo "export PGPASSWORD=\"${DB_PASSWORD}\""
  echo "export PGDATABASE=\"${PARAM_DATABASE}\""
  echo "export NEON_BRANCH_ID=\"${BRANCH_ID}\""
} >> "$BASH_ENV"

echo ""
echo "Exported: DATABASE_URL, DATABASE_URL_POOLED, PGHOST, PGHOST_POOLED, PGUSER, PGPASSWORD, PGDATABASE, NEON_BRANCH_ID"

if [ "$PARAM_GET_AUTH" = "true" ]; then
  echo "Retrieving Neon Auth URL..."
  AUTH_RESPONSE=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/neon_auth" 2>/dev/null || true)
  AUTH_URL=$(echo "$AUTH_RESPONSE" | jq -r '.base_url // empty' 2>/dev/null || true)
  if [ -n "$AUTH_URL" ]; then
    echo "export NEON_AUTH_URL=\"${AUTH_URL}\"" >> "$BASH_ENV"
    echo "Exported: NEON_AUTH_URL"
  else
    echo "Warning: Neon Auth is not enabled for this branch. Skipping NEON_AUTH_URL."
  fi
fi

if [ "$PARAM_GET_DATA_API" = "true" ]; then
  echo "Retrieving Neon Data API URL..."
  DATA_API_RESPONSE=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/data_api/${PARAM_DATABASE}" 2>/dev/null || true)
  DATA_API_URL=$(echo "$DATA_API_RESPONSE" | jq -r '.url // empty' 2>/dev/null || true)
  if [ -n "$DATA_API_URL" ]; then
    echo "export NEON_DATA_API_URL=\"${DATA_API_URL}\"" >> "$BASH_ENV"
    echo "Exported: NEON_DATA_API_URL"
  else
    echo "Warning: Data API is not enabled for this branch. Skipping NEON_DATA_API_URL."
  fi
fi

echo ""
echo "=== Neon Branch Ready ==="
echo "Branch:   $BRANCH_NAME ($BRANCH_ID)"
echo "Host:     $ENDPOINT_HOST"
echo "Database: $PARAM_DATABASE"
echo "Role:     $PARAM_ROLE"
echo "Created:  $BRANCH_CREATED"
echo "========================="
