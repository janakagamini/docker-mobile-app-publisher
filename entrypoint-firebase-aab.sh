#!/usr/bin/env bash
set -euo pipefail

echo "====================================================================="
echo "🚀 Track 1: Firebase App Distribution — Android AAB (Pure REST API)"
echo "====================================================================="

# ------------------------------------------------------------------------------
# 1. Validate required inputs
# ------------------------------------------------------------------------------
ARTIFACT_TO_DOWNLOAD="${FIREBASE_AAB_ARTIFACT_URL:-${ARTIFACT_URL:-}}"
APP_ID="${FIREBASE_AAB_APP_ID:-${FIREBASE_APP_ID:-}}"

: "${ARTIFACT_TO_DOWNLOAD:?Error: FIREBASE_AAB_ARTIFACT_URL environment variable is required}"
: "${APP_ID:?Error: FIREBASE_AAB_APP_ID environment variable is required}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?Error: GOOGLE_APPLICATION_CREDENTIALS environment variable is required}"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo "❌ Service account key file not found at: $GOOGLE_APPLICATION_CREDENTIALS"
  exit 1
fi

FILENAME=$(basename "${ARTIFACT_TO_DOWNLOAD%%\?*}")
EXT="${FILENAME##*.}"
if [[ "$EXT" != "aab" && "$EXT" != "apk" ]]; then
  echo "❌ Expected .aab (or .apk) artifact for Firebase Android track, got: ${FILENAME}"
  exit 1
fi

# Extract project number from Firebase App ID (format: 1:<project_number>:android:<hash>)
PROJECT_NUMBER=$(printf '%s' "$APP_ID" | cut -d: -f2)
if [ -z "$PROJECT_NUMBER" ]; then
  echo "❌ Invalid FIREBASE_AAB_APP_ID format: $APP_ID (expected 1:<project_number>:android:<hash>)"
  exit 1
fi

CURL_VERBOSE_ARGS=()
if [ "${FIREBASE_DEBUG:-false}" = "true" ]; then
  CURL_VERBOSE_ARGS+=(--verbose)
fi

# ------------------------------------------------------------------------------
# Helper: Base64URL encoding (RFC 7515)
# ------------------------------------------------------------------------------
base64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# ------------------------------------------------------------------------------
# Helper: Generate RS256 JWT from Google Service Account JSON (Offline)
# ------------------------------------------------------------------------------
generate_google_jwt() {
  local cred_file="$1"
  local scope="$2"
  local client_email private_key now exp header payload signing_input key_file signature

  client_email=$(jq -r '.client_email' "$cred_file")
  private_key=$(jq -r '.private_key' "$cred_file")
  now=$(date +%s)
  exp=$((now + 3600))

  header=$(jq -cn '{alg:"RS256",typ:"JWT"}' | base64url)
  payload=$(jq -cn \
    --arg iss "$client_email" \
    --arg scope "$scope" \
    --arg aud "https://oauth2.googleapis.com/token" \
    --argjson iat "$now" \
    --argjson exp "$exp" \
    '{iss:$iss,scope:$scope,aud:$aud,iat:$iat,exp:$exp}' | base64url)

  signing_input="${header}.${payload}"
  key_file=$(mktemp)
  printf '%s\n' "$private_key" > "$key_file"
  signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_file" | base64url)
  rm -f "$key_file"

  printf '%s.%s' "$signing_input" "$signature"
}

# ------------------------------------------------------------------------------
# Helper: REST API request with HTTP status check
# ------------------------------------------------------------------------------
api_request() {
  local method="$1"
  local url="$2"
  shift 2

  local response_file http_code
  response_file=$(mktemp)
  http_code=$(curl --silent --show-error --location \
    "${CURL_VERBOSE_ARGS[@]}" \
    --request "$method" \
    --output "$response_file" \
    --write-out "%{http_code}" \
    "$@" \
    "$url")

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "" >&2
    echo "❌ Firebase REST API Error ($method $url -> HTTP $http_code):" >&2
    jq . "$response_file" >&2 2>/dev/null || cat "$response_file" >&2
    echo "" >&2
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

# ------------------------------------------------------------------------------
# 2. Download .aab binary from Artifactory
# ------------------------------------------------------------------------------
DOWNLOAD_PATH="/tmp/${FILENAME}"

echo ""
echo "📥 [Step 1/5] Downloading Android AAB from Artifactory..."
echo "   URL:   ${ARTIFACT_TO_DOWNLOAD}"
echo "   Dest:  ${DOWNLOAD_PATH}"
echo "   Proxy: ${HTTPS_PROXY:-none}"
echo "---------------------------------------------------------------------"

curl --fail --show-error --location \
  "${CURL_VERBOSE_ARGS[@]}" \
  ${ARTIFACTORY_AUTH_HEADER:+-H "$ARTIFACTORY_AUTH_HEADER"} \
  --output "$DOWNLOAD_PATH" \
  "$ARTIFACT_TO_DOWNLOAD"

FILE_SIZE=$(wc -c < "$DOWNLOAD_PATH" | tr -d ' ')
echo "✅ Downloaded ${FILENAME} (${FILE_SIZE} bytes)"

# ------------------------------------------------------------------------------
# 3. Authenticate with Google OAuth2 (https://oauth2.googleapis.com/token)
# ------------------------------------------------------------------------------
echo ""
echo "🔐 [Step 2/5] Signing Service Account RS256 JWT & requesting OAuth2 token..."
JWT_ASSERTION=$(generate_google_jwt "$GOOGLE_APPLICATION_CREDENTIALS" "https://www.googleapis.com/auth/cloud-platform")

TOKEN_JSON=$(api_request POST "https://oauth2.googleapis.com/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "assertion=${JWT_ASSERTION}")

ACCESS_TOKEN=$(printf '%s' "$TOKEN_JSON" | jq -r '.access_token // empty')
if [ -z "$ACCESS_TOKEN" ]; then
  echo "❌ Failed to obtain OAuth2 access_token"
  exit 1
fi
echo "✅ Obtained OAuth2 bearer token"

# ------------------------------------------------------------------------------
# 4. Upload AAB to Firebase App Distribution v1 REST API
# ------------------------------------------------------------------------------
API_BASE="https://firebaseappdistribution.googleapis.com"
APP_RESOURCE="projects/${PROJECT_NUMBER}/apps/${APP_ID}"

echo ""
echo "📦 [Step 3/5] Uploading ${FILENAME} to Firebase App Distribution..."
echo "   App Resource: ${APP_RESOURCE}"
UPLOAD_OP_JSON=$(api_request POST "${API_BASE}/upload/v1/${APP_RESOURCE}/releases:upload" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "X-Goog-Upload-Protocol: raw" \
  -H "X-Goog-Upload-File-Name: ${FILENAME}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"${DOWNLOAD_PATH}")

OP_NAME=$(printf '%s' "$UPLOAD_OP_JSON" | jq -r '.name')
echo "✅ Upload initiated (operation: ${OP_NAME})"

# ------------------------------------------------------------------------------
# 5. Poll long-running release operation until processing completes
# ------------------------------------------------------------------------------
echo ""
echo "⏳ [Step 4/5] Polling release processing status..."
OP_DONE=$(printf '%s' "$UPLOAD_OP_JSON" | jq -r '.done // false')
OP_RESPONSE="$UPLOAD_OP_JSON"
MAX_POLLS=30
POLL_COUNT=0

while [ "$OP_DONE" != "true" ]; do
  POLL_COUNT=$((POLL_COUNT + 1))
  if [ "$POLL_COUNT" -gt "$MAX_POLLS" ]; then
    echo "❌ Timed out waiting for Firebase release processing operation: ${OP_NAME}"
    exit 1
  fi
  sleep 2
  OP_RESPONSE=$(api_request GET "${API_BASE}/v1/${OP_NAME}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")
  OP_DONE=$(printf '%s' "$OP_RESPONSE" | jq -r '.done // false')
done

OP_ERROR=$(printf '%s' "$OP_RESPONSE" | jq -r '.error.message // empty')
if [ -n "$OP_ERROR" ]; then
  echo "❌ Firebase release processing failed: ${OP_ERROR}"
  printf '%s\n' "$OP_RESPONSE" | jq . >&2
  exit 1
fi

UPLOAD_RESULT=$(printf '%s' "$OP_RESPONSE" | jq -r '.response.result // "SUCCESS"')
RELEASE_NAME=$(printf '%s' "$OP_RESPONSE" | jq -r '.response.release.name')
DISPLAY_VERSION=$(printf '%s' "$OP_RESPONSE" | jq -r '.response.release.displayVersion // "?"')
BUILD_VERSION=$(printf '%s' "$OP_RESPONSE" | jq -r '.response.release.buildVersion // "?"')
echo "✅ Release ready: ${RELEASE_NAME} (v${DISPLAY_VERSION} / build ${BUILD_VERSION}, status: ${UPLOAD_RESULT})"

# ------------------------------------------------------------------------------
# 6. Attach release notes & distribute to testers/groups (optional)
# ------------------------------------------------------------------------------
echo ""
echo "📝 [Step 5/5] Updating release notes & distributing to testers..."

if [ -n "${RELEASE_NOTES:-}" ]; then
  NOTES_PAYLOAD=$(jq -cn --arg name "$RELEASE_NAME" --arg notes "$RELEASE_NOTES" \
    '{name:$name, releaseNotes:{text:$notes}}')
  api_request PATCH "${API_BASE}/v1/${RELEASE_NAME}?updateMask=release_notes.text" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$NOTES_PAYLOAD" > /dev/null
  echo "   ✅ Attached release notes"
else
  echo "   ℹ️  No RELEASE_NOTES specified; skipping release notes update"
fi

if [ -n "${TESTERS:-}" ] || [ -n "${TESTER_GROUPS:-}" ]; then
  DIST_PAYLOAD=$(jq -cn \
    --arg testers "${TESTERS:-}" \
    --arg groups "${TESTER_GROUPS:-}" \
    '{
      testerEmails: ($testers | if length > 0 then split(",") | map(gsub("^\\s+|\\s+$"; "")) else [] end),
      groupAliases: ($groups | if length > 0 then split(",") | map(gsub("^\\s+|\\s+$"; "")) else [] end)
    }')
  api_request POST "${API_BASE}/v1/${RELEASE_NAME}:distribute" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$DIST_PAYLOAD" > /dev/null
  echo "   ✅ Distributed release to testers/groups"
else
  echo "   ℹ️  No TESTERS or TESTER_GROUPS specified; skipping distribution step"
fi

echo ""
echo "🎉 Track 1 (Firebase App Distribution — AAB) completed successfully!"
