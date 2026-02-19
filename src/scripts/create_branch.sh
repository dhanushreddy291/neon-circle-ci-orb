#!/bin/bash
set -euo pipefail

# ==============================================================================
# Neon Branch – Create (or reuse) a branch, then export connection variables.
#
# Phases:
#   1. Validate required inputs (API key, project ID)
#   2. Resolve branch name (explicit or auto-generated)
#   3. Find an existing branch or create a new one
#   4. Fetch endpoint & password, export connection env vars
#   5. Optionally export Neon Auth URL and Data API URL
#   6. Print summary
# ==============================================================================

# ── Global constants ─────────────────────────────────────────────────────────

API_BASE="https://console.neon.tech/api/v2"

# ── Utility helpers ──────────────────────────────────────────────────────────

# Print an error message and exit.
die() { echo "Error: $1" >&2; exit 1; }

# Return 0 for common truthy strings (true/1/yes/on), 1 otherwise.
is_truthy() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [[ "$v" == "true" || "$v" == "1" || "$v" == "yes" || "$v" == "on" ]]
}

# URL-encode a string (Python preferred, jq fallback).
urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))" 2>/dev/null \
    || printf '%s' "$1" | jq -sRr @uri
}

# ── Neon API helpers ─────────────────────────────────────────────────────────

# Low-level curl wrapper. Appends the HTTP status code on a trailing line.
_neon_curl() {
  local method="$1" url="$2" body="${3:-}"
  local -a args=( -s -w "\n%{http_code}" -X "$method" "$url"
    -H "Authorization: Bearer ${NEON_API_KEY}"
    -H "Content-Type: application/json"
    -H "User-Agent: neon-circleci-orb" )
  [[ -n "$body" ]] && args+=( -d "$body" )
  curl "${args[@]}"
}

# Split a raw response (body + trailing HTTP code) into REPLY_BODY / REPLY_CODE.
_split_response() {
  local raw="$1"
  REPLY_CODE=$(echo "$raw" | tail -n1)
  REPLY_BODY=$(echo "$raw" | sed '$d')
}

# Call the Neon API and fail immediately on HTTP >= 400.
neon_api() {
  local method="$1" endpoint="$2" body="${3:-}"
  local raw
  raw=$(_neon_curl "$method" "${API_BASE}${endpoint}" "$body")
  _split_response "$raw"

  if [[ "$REPLY_CODE" -ge 400 ]]; then
    echo "Error: API $method $endpoint returned HTTP $REPLY_CODE" >&2
    echo "$REPLY_BODY" | jq . 2>/dev/null >&2 || echo "$REPLY_BODY" >&2
    return 1
  fi
  echo "$REPLY_BODY"
}

# Call the Neon API without failing — caller inspects REPLY_CODE / REPLY_BODY.
neon_api_soft() {
  local method="$1" endpoint="$2" body="${3:-}"
  local raw
  raw=$(_neon_curl "$method" "${API_BASE}${endpoint}" "$body")
  _split_response "$raw"
}

# Search branches and return the ID matching a given name (or name/id).
resolve_branch_id() {
  local name="$1" match_id_too="${2:-false}"
  local encoded filter response
  encoded=$(urlencode "$name")
  response=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches?search=${encoded}")

  if is_truthy "$match_id_too"; then
    filter='.branches[] | select(.name == $n or .id == $n) | .id'
  else
    filter='.branches[] | select(.name == $n) | .id'
  fi
  echo "$response" | jq -r --arg n "$name" "$filter" 2>/dev/null | head -n1
}

# ── Phase 1: Validate inputs ────────────────────────────────────────────────

validate_inputs() {
  NEON_API_KEY="${!PARAM_API_KEY:-}"
  NEON_PROJECT_ID="${!PARAM_PROJECT_ID:-}"
  [[ -n "$NEON_API_KEY" ]]     || die "Neon API key is not set (expected in \$$PARAM_API_KEY)."
  [[ -n "$NEON_PROJECT_ID" ]]  || die "Neon Project ID is not set (expected in \$$PARAM_PROJECT_ID)."
}

# ── Phase 2: Resolve branch name ────────────────────────────────────────────

resolve_branch_name() {
  BRANCH_NAME="$PARAM_BRANCH_NAME"
  if [[ -z "$BRANCH_NAME" ]]; then
    BRANCH_NAME="${CIRCLE_PIPELINE_NUM:-${CIRCLE_BUILD_NUM:-}}"
    [[ -n "$BRANCH_NAME" ]] || BRANCH_NAME="local-$(date -u +%Y%m%d%H%M%S)"
    [[ -z "${CIRCLE_NODE_INDEX:-}" ]] || BRANCH_NAME="${BRANCH_NAME}-${CIRCLE_NODE_INDEX}"
  fi
  echo "Branch name: $BRANCH_NAME"
}

# ── Phase 3: Find or create the branch ──────────────────────────────────────

find_or_create_branch() {
  local existing_id
  existing_id=$(resolve_branch_id "$BRANCH_NAME")

  if [[ -n "$existing_id" ]]; then
    echo "Branch '$BRANCH_NAME' already exists (ID: $existing_id). Reusing."
    BRANCH_ID="$existing_id"
    BRANCH_CREATED="false"
    return
  fi

  BRANCH_CREATED="true"
  local parent_id="" expires_at="" payload create_response

  # Resolve optional parent branch.
  if [[ -n "$PARAM_PARENT_BRANCH" ]]; then
    parent_id=$(resolve_branch_id "$PARAM_PARENT_BRANCH" true)
    [[ -n "$parent_id" ]] || die "Parent branch '$PARAM_PARENT_BRANCH' not found."
    echo "Parent branch resolved: $PARAM_PARENT_BRANCH -> $parent_id"
  fi

  # Compute expiry timestamp from TTL.
  if [[ "$PARAM_TTL_SECONDS" -gt 0 ]] 2>/dev/null; then
    expires_at=$(date -u -d "+${PARAM_TTL_SECONDS} seconds" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
      || date -u -v+"${PARAM_TTL_SECONDS}"S "+%Y-%m-%dT%H:%M:%SZ")
    echo "Branch TTL: ${PARAM_TTL_SECONDS}s (expires at $expires_at)"
  fi

  # Build the JSON payload with optional fields.
  payload=$(jq -n \
    --arg name        "$BRANCH_NAME" \
    --arg parent_id   "$parent_id" \
    --arg expires_at  "$expires_at" \
    --arg schema_only "$PARAM_SCHEMA_ONLY" \
    '{
      branch: { name: $name },
      endpoints: [{ type: "read_write" }]
    }
    | if $parent_id   != "" then .branch.parent_id   = $parent_id            else . end
    | if $expires_at   != "" then .branch.expires_at   = $expires_at          else . end
    | if $schema_only == "true" then .branch.init_source = "schema-only"      else . end')

  echo "Creating branch..."
  create_response=$(neon_api POST "/projects/${NEON_PROJECT_ID}/branches" "$payload")

  BRANCH_ID=$(echo "$create_response" | jq -r '.branch.id')
  [[ -n "$BRANCH_ID" && "$BRANCH_ID" != "null" ]] \
    || { echo "$create_response" | jq . ; die "Failed to extract branch ID from response."; }
  echo "Branch created: $BRANCH_ID"
}

# ── Phase 4: Fetch endpoint & password, export connection env vars ───────────

export_connection_env() {
  local endpoints_json endpoint_host endpoint_id endpoint_host_pooled
  local db_password encoded_password database_url database_url_pooled

  endpoints_json=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/endpoints")
  endpoint_host=$(echo "$endpoints_json" | jq -r '.endpoints[0].host')
  endpoint_id=$(echo "$endpoints_json"   | jq -r '.endpoints[0].id')
  [[ -n "$endpoint_host" && "$endpoint_host" != "null" ]] \
    || die "No endpoint found for branch $BRANCH_ID."

  endpoint_host_pooled="${endpoint_host//${endpoint_id}/${endpoint_id}-pooler}"

  # Retrieve or reuse the database password.
  db_password="$PARAM_PASSWORD"
  if [[ -z "$db_password" ]]; then
    echo "Retrieving password for role '$PARAM_ROLE'..."
    local pw_json
    pw_json=$(neon_api GET "/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}/roles/${PARAM_ROLE}/reveal_password")
    db_password=$(echo "$pw_json" | jq -r '.password')
    [[ -n "$db_password" && "$db_password" != "null" ]] \
      || die "Could not retrieve password for role '$PARAM_ROLE'. If password storage is disabled, pass the 'password' parameter explicitly."
  fi

  encoded_password=$(urlencode "$db_password")
  database_url="postgresql://${PARAM_ROLE}:${encoded_password}@${endpoint_host}/${PARAM_DATABASE}?sslmode=require"
  database_url_pooled="postgresql://${PARAM_ROLE}:${encoded_password}@${endpoint_host_pooled}/${PARAM_DATABASE}?sslmode=require"

  # Persist variables for subsequent CircleCI steps.
  {
    echo "export DATABASE_URL=\"${database_url}\""
    echo "export DATABASE_URL_POOLED=\"${database_url_pooled}\""
    echo "export PGHOST=\"${endpoint_host}\""
    echo "export PGHOST_POOLED=\"${endpoint_host_pooled}\""
    echo "export PGUSER=\"${PARAM_ROLE}\""
    echo "export PGPASSWORD=\"${db_password}\""
    echo "export PGDATABASE=\"${PARAM_DATABASE}\""
    echo "export NEON_BRANCH_ID=\"${BRANCH_ID}\""
  } >> "$BASH_ENV"

  echo ""
  echo "Exported: DATABASE_URL, DATABASE_URL_POOLED, PGHOST, PGHOST_POOLED, PGUSER, PGPASSWORD, PGDATABASE, NEON_BRANCH_ID"

  # Store for the summary.
  _ENDPOINT_HOST="$endpoint_host"
}

# ── Phase 5: Optionally export Neon Auth URL / Data API URL ─────────────────

# Generic helper: fetch an optional feature URL from a soft API call.
# Usage: fetch_optional_url <label> <env_var> <endpoint> <jq_selector> [fallback_endpoint]
fetch_optional_url() {
  local label="$1" env_var="$2" endpoint="$3" jq_sel="$4" fallback="${5:-}"

  echo "Retrieving ${label}..."
  neon_api_soft GET "$endpoint"

  # Retry with a fallback endpoint on 404 (e.g. data-api vs data_api).
  if [[ "$REPLY_CODE" == "404" && -n "$fallback" ]]; then
    neon_api_soft GET "$fallback"
  fi

  if [[ "$REPLY_CODE" == "200" ]]; then
    local url
    url=$(echo "$REPLY_BODY" | jq -r "$jq_sel" 2>/dev/null || true)
    if [[ -n "$url" ]]; then
      echo "export ${env_var}=\"${url}\"" >> "$BASH_ENV"
      echo "${label}: enabled (exported ${env_var})"
    else
      echo "${label}: enabled, but no URL returned by API."
    fi
  elif [[ "$REPLY_CODE" == "404" ]]; then
    echo "${label}: not enabled for this branch (HTTP 404)."
  else
    local msg
    msg=$(echo "$REPLY_BODY" | jq -r '.message // empty' 2>/dev/null || true)
    echo "Warning: ${label} lookup failed (HTTP $REPLY_CODE)${msg:+: $msg}."
  fi
}

export_optional_urls() {
  local branch_base="/projects/${NEON_PROJECT_ID}/branches/${BRANCH_ID}"

  if is_truthy "$PARAM_GET_AUTH"; then
    fetch_optional_url "Neon Auth" "NEON_AUTH_URL" \
      "${branch_base}/auth" \
      '.base_url // .auth_url // .url // empty'
  fi

  if is_truthy "$PARAM_GET_DATA_API"; then
    fetch_optional_url "Neon Data API" "NEON_DATA_API_URL" \
      "${branch_base}/data-api/${PARAM_DATABASE}" \
      '.url // .data_api_url // .data_api.url // empty' \
      "${branch_base}/data_api/${PARAM_DATABASE}"
  fi
}

# ── Phase 6: Print summary ──────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "=== Neon Branch Ready ==="
  echo "Branch:   $BRANCH_NAME ($BRANCH_ID)"
  echo "Host:     ${_ENDPOINT_HOST}"
  echo "Database: $PARAM_DATABASE"
  echo "Role:     $PARAM_ROLE"
  echo "Created:  $BRANCH_CREATED"
  echo "========================="
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_inputs
  resolve_branch_name
  find_or_create_branch
  export_connection_env
  export_optional_urls
  print_summary
}

main
