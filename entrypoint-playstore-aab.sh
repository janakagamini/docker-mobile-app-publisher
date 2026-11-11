#!/usr/bin/env bash
set -euo pipefail

echo "====================================================================="
echo "🚀 Track 3: Google Play Console — Android AAB (Pure REST API)"
echo "====================================================================="

# ------------------------------------------------------------------------------
# 1. Validate required inputs
# ------------------------------------------------------------------------------
ARTIFACT_TO_DOWNLOAD="${PLAYSTORE_AAB_ARTIFACT_URL:-${PLAY_ARTIFACT_URL:-}}"
PACKAGE_NAME="${PLAYSTORE_PACKAGE_NAME:-${PLAY_PACKAGE_NAME:-}}"

: "${ARTIFACT_TO_DOWNLOAD:?Error: PLAYSTORE_AAB_ARTIFACT_URL environment variable is required}"
: "${PACKAGE_NAME:?Error: PLAYSTORE_PACKAGE_NAME environment variable is required}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?Error: GOOGLE_APPLICATION_CREDENTIALS environment variable is required}"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo "❌ Service account key file not found at: $GOOGLE_APPLICATION_CREDENTIALS"
  exit 1
fi

TRACK="${PLAYSTORE_TRACK:-${PLAY_TRACK:-internal}}"
RELEASE_STATUS="${PLAYSTORE_RELEASE_STATUS:-${PLAY_RELEASE_STATUS:-draft}}"
RELEASE_NOTES_LANG="${PLAYSTORE_RELEASE_NOTES_LANG:-${PLAY_RELEASE_NOTES_LANG:-en-US}}"
RELEASE_NOTES="${RELEASE_NOTES:-}"

CURL_VERBOSE_ARGS=()
if [ "${PLAYSTORE_DEBUG:-${PLAY_DEBUG:-false}}" = "true" ]; then
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
    echo "❌ Google Play REST API Error ($method $url -> HTTP $http_code):" >&2
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
FILENAME=$(basename "${ARTIFACT_TO_DOWNLOAD%%\?*}")
DOWNLOAD_PATH="/tmp/${FILENAME}"

echo ""
echo "📥 [Step 1/6] Downloading Android AAB from Artifactory..."
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
# 3. Sign Service Account JWT locally & exchange for OAuth2 token
# ------------------------------------------------------------------------------
echo ""
echo "🔐 [Step 2/6] Signing Service Account RS256 JWT & requesting OAuth2 token..."
JWT_ASSERTION=$(generate_google_jwt "$GOOGLE_APPLICATION_CREDENTIALS" "https://www.googleapis.com/auth/androidpublisher")

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

BASE_API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}"
UPLOAD_API="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${PACKAGE_NAME}"

# ------------------------------------------------------------------------------
# 4. Create a new Edit session
# ------------------------------------------------------------------------------
echo ""
echo "📝 [Step 3/6] Creating new edit session for ${PACKAGE_NAME}..."
EDIT_JSON=$(api_request POST "${BASE_API}/edits" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{}')

EDIT_ID=$(printf '%s' "$EDIT_JSON" | jq -r '.id')
echo "✅ Created edit ID: ${EDIT_ID}"

# ------------------------------------------------------------------------------
# 5. Upload .aab (or .apk) binary
# ------------------------------------------------------------------------------
echo ""
EXT="${FILENAME##*.}"
if [ "$EXT" = "aab" ]; then
  echo "📦 [Step 4/6] Uploading Android App Bundle (${FILENAME})..."
  UPLOAD_JSON=$(api_request POST "${UPLOAD_API}/edits/${EDIT_ID}/bundles?uploadType=media" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${DOWNLOAD_PATH}")
elif [ "$EXT" = "apk" ]; then
  echo "📦 [Step 4/6] Uploading APK (${FILENAME})..."
  UPLOAD_JSON=$(api_request POST "${UPLOAD_API}/edits/${EDIT_ID}/apks?uploadType=media" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary @"${DOWNLOAD_PATH}")
else
  echo "❌ Unsupported file extension: .${EXT} (expected .aab or .apk)" >&2
  exit 1
fi

VERSION_CODE=$(printf '%s' "$UPLOAD_JSON" | jq -r '.versionCode')
echo "✅ Uploaded binary: versionCode=${VERSION_CODE}"

# ------------------------------------------------------------------------------
# 6. Assign versionCode to target track
# ------------------------------------------------------------------------------
echo ""
echo "🛤️  [Step 5/6] Assigning versionCode ${VERSION_CODE} to track \"${TRACK}\" (status: \"${RELEASE_STATUS}\")..."
TRACK_PAYLOAD=$(jq -cn \
  --arg track "$TRACK" \
  --arg status "$RELEASE_STATUS" \
  --arg vc "$VERSION_CODE" \
  --arg notes "$RELEASE_NOTES" \
  --arg lang "$RELEASE_NOTES_LANG" \
  '{
    track: $track,
    releases: [
      ({
        status: $status,
        versionCodes: [$vc]
      } + (if ($notes | length) > 0 then {releaseNotes: [{language: $lang, text: $notes}]} else {} end))
    ]
  }')

api_request PUT "${BASE_API}/edits/${EDIT_ID}/tracks/${TRACK}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$TRACK_PAYLOAD" > /dev/null
echo "✅ Track \"${TRACK}\" updated"

# ------------------------------------------------------------------------------
# 7. Commit Edit
# ------------------------------------------------------------------------------
echo ""
echo "💾 [Step 6/6] Committing edit ${EDIT_ID}..."
api_request POST "${BASE_API}/edits/${EDIT_ID}:commit" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{}' > /dev/null
echo "✅ Edit ${EDIT_ID} committed!"

echo ""
echo "🎉 Track 3 (Google Play Console — AAB) completed successfully!"
