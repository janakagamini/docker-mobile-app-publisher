#!/usr/bin/env bash
set -euo pipefail

echo "====================================================================="
echo "🚀 Track 5: Huawei AppGallery Connect — Android AAB/APK (Pure REST)"
echo "====================================================================="

# ------------------------------------------------------------------------------
# 1. Validate required inputs & resolve API Client credentials
# ------------------------------------------------------------------------------
ARTIFACT_TO_DOWNLOAD="${HUAWEI_AAB_ARTIFACT_URL:-${HUAWEI_ARTIFACT_URL:-}}"
APP_ID="${HUAWEI_APP_ID:-}"
CLIENT_ID="${HUAWEI_CLIENT_ID:-}"
CLIENT_SECRET="${HUAWEI_CLIENT_SECRET:-}"
CREDENTIALS_FILE="${HUAWEI_CREDENTIALS_FILE:-/credentials/huawei-api-client.json}"

# Optional: Load client_id and client_secret from JSON file if not set in env
if [[ ( -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ) && -f "$CREDENTIALS_FILE" ]]; then
  CLIENT_ID="${CLIENT_ID:-$(jq -r '.client_id // empty' "$CREDENTIALS_FILE")}"
  CLIENT_SECRET="${CLIENT_SECRET:-$(jq -r '.client_secret // empty' "$CREDENTIALS_FILE")}"
fi

: "${ARTIFACT_TO_DOWNLOAD:?Error: HUAWEI_AAB_ARTIFACT_URL environment variable is required}"
: "${APP_ID:?Error: HUAWEI_APP_ID environment variable is required}"
: "${CLIENT_ID:?Error: HUAWEI_CLIENT_ID environment variable (or $CREDENTIALS_FILE) is required}"
: "${CLIENT_SECRET:?Error: HUAWEI_CLIENT_SECRET environment variable (or $CREDENTIALS_FILE) is required}"

FILENAME=$(basename "${ARTIFACT_TO_DOWNLOAD%%\?*}")
EXT=$(printf '%s' "${FILENAME##*.}" | tr '[:upper:]' '[:lower:]')
if [[ "$EXT" != "aab" && "$EXT" != "apk" && "$EXT" != "app" ]]; then
  echo "❌ Unsupported file extension: .${EXT} (expected .aab, .apk, or HarmonyOS .app)" >&2
  exit 1
fi

# Base URL options:
# - Global (default): https://connect-api.cloud.huawei.com
# - Europe (Germany): https://connect-api-dr.cloud.huawei.com
# - Asia (Singapore): https://connect-api-ce.cloud.huawei.com
# - Russia:           https://connect-api-ru.cloud.huawei.com
API_BASE_URL="${HUAWEI_API_BASE_URL:-https://connect-api.cloud.huawei.com}"
RELEASE_TYPE="${HUAWEI_RELEASE_TYPE:-1}" # 1 = formal release (entire network), 3 = phased release
SUBMIT_FOR_REVIEW="${HUAWEI_SUBMIT_FOR_REVIEW:-false}"
RELEASE_NOTES="${RELEASE_NOTES:-}"

CURL_VERBOSE_ARGS=()
if [ "${HUAWEI_DEBUG:-false}" = "true" ]; then
  CURL_VERBOSE_ARGS+=(--verbose)
fi

# ------------------------------------------------------------------------------
# Helper: REST API request with HTTP status & Huawei AGC ret.code check
# ------------------------------------------------------------------------------
agc_api_request() {
  local method="$1"
  local url="$2"
  shift 2

  local response_file http_code ret_code
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
    echo "❌ Huawei AppGallery Connect API Error ($method $url -> HTTP $http_code):" >&2
    jq . "$response_file" >&2 2>/dev/null || cat "$response_file" >&2
    echo "" >&2
    rm -f "$response_file"
    return 1
  fi

  # Huawei AGC v2 endpoints return HTTP 200 with {"ret": {"code": 0, "msg": "success"}}
  ret_code=$(jq -r '.ret.code // 0' "$response_file" 2>/dev/null || printf '0')
  if [[ "$ret_code" != "0" ]]; then
    echo "" >&2
    echo "❌ Huawei AppGallery Connect API Logical Error ($method $url -> ret.code=$ret_code):" >&2
    jq . "$response_file" >&2 2>/dev/null || cat "$response_file" >&2
    echo "" >&2
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

# ------------------------------------------------------------------------------
# 2. Download .aab (or .apk) binary from Artifactory & compute SHA-256
# ------------------------------------------------------------------------------
DOWNLOAD_PATH="/tmp/${FILENAME}"

echo ""
echo "📥 [Step 1/6] Downloading Android package from Artifactory..."
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
FILE_SHA256=$(sha256sum "$DOWNLOAD_PATH" | awk '{print $1}')
echo "✅ Downloaded ${FILENAME} (${FILE_SIZE} bytes)"
echo "   SHA-256: ${FILE_SHA256}"

# ------------------------------------------------------------------------------
# 3. Exchange API Client Credentials for OAuth2 Bearer Token
#    (POST /api/oauth2/v1/token)
# ------------------------------------------------------------------------------
echo ""
echo "🔐 [Step 2/6] Requesting OAuth2 token from Huawei AppGallery Connect..."
echo "   Endpoint: ${API_BASE_URL}/api/oauth2/v1/token"

AUTH_PAYLOAD=$(jq -cn \
  --arg cid "$CLIENT_ID" \
  --arg csec "$CLIENT_SECRET" \
  '{
    grant_type: "client_credentials",
    client_id: $cid,
    client_secret: $csec
  }')

TOKEN_JSON=$(agc_api_request POST "${API_BASE_URL}/api/oauth2/v1/token" \
  -H "Content-Type: application/json" \
  --data "$AUTH_PAYLOAD")

ACCESS_TOKEN=$(printf '%s' "$TOKEN_JSON" | jq -r '.access_token // empty')
EXPIRES_IN=$(printf '%s' "$TOKEN_JSON" | jq -r '.expires_in // "?"')
if [ -z "$ACCESS_TOKEN" ]; then
  echo "❌ Failed to obtain Huawei OAuth2 access_token:" >&2
  printf '%s\n' "$TOKEN_JSON" | jq . >&2
  exit 1
fi
echo "✅ Obtained Huawei OAuth2 bearer token (expires_in: ${EXPIRES_IN}s)"

# ------------------------------------------------------------------------------
# 4. Obtain Pre-Signed OBS Upload URL
#    (GET /api/publish/v2/upload-url/for-obs)
# ------------------------------------------------------------------------------
echo ""
echo "🔗 [Step 3/6] Requesting pre-signed Huawei Cloud OBS upload URL..."
UPLOAD_URL_ENDPOINT="${API_BASE_URL}/api/publish/v2/upload-url/for-obs?appId=${APP_ID}&fileName=${FILENAME}&contentLength=${FILE_SIZE}&sha256=${FILE_SHA256}&suffix=${EXT}&releaseType=${RELEASE_TYPE}"

OBS_INIT_JSON=$(agc_api_request GET "$UPLOAD_URL_ENDPOINT" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "client_id: ${CLIENT_ID}" \
  -H "Content-Type: application/json")

OBS_UPLOAD_URL=$(printf '%s' "$OBS_INIT_JSON" | jq -r '.urlInfo.url // empty')
OBS_METHOD=$(printf '%s' "$OBS_INIT_JSON" | jq -r '.urlInfo.method // "PUT"')
OBS_OBJECT_ID=$(printf '%s' "$OBS_INIT_JSON" | jq -r '.urlInfo.objectId // .objectId // empty')

if [ -z "$OBS_UPLOAD_URL" ]; then
  echo "❌ Failed to retrieve urlInfo.url from Huawei upload-url/for-obs response:" >&2
  printf '%s\n' "$OBS_INIT_JSON" | jq . >&2
  exit 1
fi

# Fallback: if objectId is not a separate field, extract path from urlInfo.url
if [ -z "$OBS_OBJECT_ID" ]; then
  OBS_OBJECT_ID=$(printf '%s' "$OBS_UPLOAD_URL" | sed -E 's|^https?://[^/]+/([^?]+).*|\1|')
fi

OBS_HOST=$(printf '%s' "$OBS_UPLOAD_URL" | awk -F/ '{print $3}')
echo "✅ Received pre-signed OBS upload URL"
echo "   Storage Host: ${OBS_HOST}"
echo "   HTTP Method:  ${OBS_METHOD}"
echo "   Object ID:    ${OBS_OBJECT_ID}"

# ------------------------------------------------------------------------------
# 5. Upload Binary to Huawei Cloud OBS
#    (PUT <urlInfo.url> with exact SigV4 headers from urlInfo.headers)
# ------------------------------------------------------------------------------
echo ""
echo "📦 [Step 4/6] Uploading ${FILENAME} (${FILE_SIZE} bytes) to Huawei Cloud OBS (${OBS_HOST})..."

OBS_HEADER_ARGS=()
while IFS= read -r hdr; do
  [ -n "$hdr" ] && OBS_HEADER_ARGS+=(--header "$hdr")
done < <(printf '%s' "$OBS_INIT_JSON" | jq -r '.urlInfo.headers // {} | to_entries[] | "\(.key): \(.value)"')

curl --fail --show-error --location \
  "${CURL_VERBOSE_ARGS[@]}" \
  --request "$OBS_METHOD" \
  "${OBS_HEADER_ARGS[@]}" \
  --data-binary @"${DOWNLOAD_PATH}" \
  "$OBS_UPLOAD_URL"

echo "✅ Uploaded ${FILENAME} to Huawei Cloud OBS"

# ------------------------------------------------------------------------------
# 6. Bind Uploaded Package to App Version Draft
#    (PUT /api/publish/v2/app-file-info)
# ------------------------------------------------------------------------------
echo ""
echo "📝 [Step 5/6] Updating App File Information in AppGallery Connect (appId=${APP_ID})..."

# fileType: 5 = APK / AAB / HarmonyOS APP package
FILE_INFO_PAYLOAD=$(jq -cn \
  --arg fname "$FILENAME" \
  --arg dest "$OBS_OBJECT_ID" \
  '{
    fileType: 5,
    files: [
      {
        fileName: $fname,
        fileDestUrl: $dest
      }
    ]
  }')

agc_api_request PUT "${API_BASE_URL}/api/publish/v2/app-file-info?appId=${APP_ID}&releaseType=${RELEASE_TYPE}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "client_id: ${CLIENT_ID}" \
  -H "Content-Type: application/json" \
  --data "$FILE_INFO_PAYLOAD" > /dev/null

echo "✅ Bound ${FILENAME} (objectId=${OBS_OBJECT_ID}) to app draft!"

# ------------------------------------------------------------------------------
# 7. Submit App Version for Review (Optional: HUAWEI_SUBMIT_FOR_REVIEW=true)
#    (POST /api/publish/v2/app-submit)
# ------------------------------------------------------------------------------
echo ""
if [ "$SUBMIT_FOR_REVIEW" = "true" ]; then
  echo "🚀 [Step 6/6] Submitting release for Huawei AppGallery review..."
  SUBMIT_URL="${API_BASE_URL}/api/publish/v2/app-submit?appId=${APP_ID}&releaseType=${RELEASE_TYPE}"
  if [ -n "$RELEASE_NOTES" ]; then
    ENCODED_REMARK=$(jq -rn --arg r "$RELEASE_NOTES" '$r | @uri')
    SUBMIT_URL="${SUBMIT_URL}&remark=${ENCODED_REMARK}"
  fi

  agc_api_request POST "$SUBMIT_URL" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "client_id: ${CLIENT_ID}" \
    -H "Content-Type: application/json" \
    --data '{}' > /dev/null
  echo "✅ Submitted appId ${APP_ID} for AppGallery review!"
else
  echo "ℹ️  [Step 6/6] Skipping final review submission (HUAWEI_SUBMIT_FOR_REVIEW=${SUBMIT_FOR_REVIEW})."
  echo "   The uploaded package is saved as a draft in AppGallery Connect."
fi

echo ""
echo "🎉 Track 5 (Huawei AppGallery Connect — ${EXT^^}) completed successfully!"
