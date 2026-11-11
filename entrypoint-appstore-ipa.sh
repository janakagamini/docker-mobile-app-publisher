#!/usr/bin/env bash
set -euo pipefail

echo "====================================================================="
echo "🚀 Track 4: Apple App Store Connect — iOS IPA (Pure REST API)"
echo "====================================================================="

# ------------------------------------------------------------------------------
# 1. Validate required inputs
# ------------------------------------------------------------------------------
ARTIFACT_TO_DOWNLOAD="${APPSTORE_IPA_ARTIFACT_URL:-${APPSTORE_ARTIFACT_URL:-}}"
: "${ARTIFACT_TO_DOWNLOAD:?Error: APPSTORE_IPA_ARTIFACT_URL environment variable is required}"
: "${APPSTORE_ISSUER_ID:?Error: APPSTORE_ISSUER_ID environment variable is required}"
: "${APPSTORE_KEY_ID:?Error: APPSTORE_KEY_ID environment variable is required}"
: "${APPSTORE_PRIVATE_KEY_PATH:?Error: APPSTORE_PRIVATE_KEY_PATH environment variable is required}"

if [ -z "${APPSTORE_APP_ID:-}" ] && [ -z "${APPSTORE_BUNDLE_ID:-}" ]; then
  echo "❌ Either APPSTORE_APP_ID (numeric Apple ID) or APPSTORE_BUNDLE_ID (e.g. com.example.app) is required"
  exit 1
fi

if [ ! -f "$APPSTORE_PRIVATE_KEY_PATH" ]; then
  echo "❌ App Store Connect API private key (.p8) not found at: $APPSTORE_PRIVATE_KEY_PATH"
  exit 1
fi

API_BASE_URL="${APPSTORE_API_BASE_URL:-https://api.appstoreconnect.apple.com}"
PLATFORM="${APPSTORE_PLATFORM:-IOS}"
CURL_VERBOSE_ARGS=()
if [ "${APPSTORE_DEBUG:-false}" = "true" ]; then
  CURL_VERBOSE_ARGS+=(--verbose)
fi

# ------------------------------------------------------------------------------
# Helper: Base64URL encoding (RFC 7515)
# ------------------------------------------------------------------------------
base64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# ------------------------------------------------------------------------------
# Helper: Generate ES256 (P-256 / prime256v1) JWT for App Store Connect API
# Note: openssl dgst -sha256 -sign outputs an ASN.1 DER sequence of (R, S).
#       JWS ES256 (RFC 7515) requires the raw 64-byte concatenation R || S.
# ------------------------------------------------------------------------------
generate_asc_jwt() {
  local key_id="$1"
  local issuer_id="$2"
  local key_file="$3"

  local now exp header payload signing_input der_file r_hex s_hex signature
  now=$(date +%s)
  exp=$((now + 1200)) # Valid for 20 minutes (Apple maximum)

  header=$(jq -cn --arg kid "$key_id" '{alg:"ES256",kid:$kid,typ:"JWT"}' | base64url)
  payload=$(jq -cn \
    --arg iss "$issuer_id" \
    --argjson iat "$now" \
    --argjson exp "$exp" \
    '{iss:$iss,iat:$iat,exp:$exp,aud:"appstoreconnect-v1"}' | base64url)

  signing_input="${header}.${payload}"
  der_file=$(mktemp)

  printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_file" -out "$der_file"

  # Extract R and S hex integers from ASN.1 DER structure and pad each to 64 hex chars (32 bytes)
  mapfile -t rs_hex < <(
    openssl asn1parse -inform DER -in "$der_file" |
      awk -F: '/INTEGER/ {gsub(/[[:space:]]/, "", $NF); print $NF}'
  )
  rm -f "$der_file"

  r_hex=$(printf "%064s" "${rs_hex[0]}" | tr ' ' '0')
  s_hex=$(printf "%064s" "${rs_hex[1]}" | tr ' ' '0')

  # Ensure exact 64 hex chars in case of leading 00 padding from ASN.1
  r_hex="${r_hex: -64}"
  s_hex="${s_hex: -64}"

  signature=$(printf '%s%s' "$r_hex" "$s_hex" | xxd -r -p | base64url)
  printf '%s.%s' "$signing_input" "$signature"
}

# ------------------------------------------------------------------------------
# Helper: Authenticated JSON API call to App Store Connect
# ------------------------------------------------------------------------------
asc_api_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local response_file http_code

  response_file=$(mktemp)
  local curl_args=(
    --silent --show-error --location
    "${CURL_VERBOSE_ARGS[@]}"
    --request "$method"
    --header "Authorization: Bearer ${ASC_JWT}"
    --header "Accept: application/json"
    --output "$response_file"
    --write-out "%{http_code}"
  )

  if [ -n "$body" ]; then
    curl_args+=(--header "Content-Type: application/json" --data "$body")
  fi

  http_code=$(curl "${curl_args[@]}" "$url")

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "❌ App Store Connect API error (${method} ${url} -> HTTP ${http_code}):" >&2
    cat "$response_file" | jq . >&2 || cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

# ------------------------------------------------------------------------------
# 2. Download .ipa from Artifactory
# ------------------------------------------------------------------------------
FILENAME=$(basename "${ARTIFACT_TO_DOWNLOAD%%\?*}")
DOWNLOAD_PATH="/tmp/${FILENAME}"

echo ""
echo "📥 [Step 1/7] Downloading iOS IPA from Artifactory..."
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
# 3. Inspect .ipa metadata (CFBundleShortVersionString & CFBundleVersion)
# ------------------------------------------------------------------------------
echo ""
echo "🔍 [Step 2/7] Resolving bundle version metadata..."
SHORT_VERSION="${APPSTORE_BUNDLE_SHORT_VERSION:-}"
BUILD_VERSION="${APPSTORE_BUNDLE_VERSION:-}"

if [ -z "$SHORT_VERSION" ] || [ -z "$BUILD_VERSION" ]; then
  PLIST_ENTRY=$(unzip -Z1 "$DOWNLOAD_PATH" 'Payload/*.app/Info.plist' 2>/dev/null | head -n 1 || true)
  if [ -n "$PLIST_ENTRY" ]; then
    PLIST_XML=$(unzip -p "$DOWNLOAD_PATH" "$PLIST_ENTRY" | plistutil -f xml)
    SHORT_VERSION="${SHORT_VERSION:-$(printf '%s\n' "$PLIST_XML" | awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}')}"
    BUILD_VERSION="${BUILD_VERSION:-$(printf '%s\n' "$PLIST_XML" | awk '/<key>CFBundleVersion<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit}')}"
  fi
fi

: "${SHORT_VERSION:?Error: Could not determine CFBundleShortVersionString from .ipa; set APPSTORE_BUNDLE_SHORT_VERSION in .env}"
: "${BUILD_VERSION:?Error: Could not determine CFBundleVersion from .ipa; set APPSTORE_BUNDLE_VERSION in .env}"

echo "   CFBundleShortVersionString: ${SHORT_VERSION}"
echo "   CFBundleVersion:            ${BUILD_VERSION}"
echo "   Platform:                   ${PLATFORM}"

# ------------------------------------------------------------------------------
# 4. Generate App Store Connect ES256 JWT (Offline)
# ------------------------------------------------------------------------------
echo ""
echo "🔐 [Step 3/7] Generating App Store Connect ES256 JWT locally..."
ASC_JWT=$(generate_asc_jwt "$APPSTORE_KEY_ID" "$APPSTORE_ISSUER_ID" "$APPSTORE_PRIVATE_KEY_PATH")
echo "✅ Signed ES256 JWT (Key ID: ${APPSTORE_KEY_ID}, Issuer: ${APPSTORE_ISSUER_ID})"

# Optional: Look up numeric APPSTORE_APP_ID by bundleId if not provided directly
if [ -z "${APPSTORE_APP_ID:-}" ]; then
  echo "🔎 Looking up App Store Connect App ID for bundleId '${APPSTORE_BUNDLE_ID}'..."
  APP_LOOKUP_RES=$(asc_api_request "GET" "${API_BASE_URL}/v1/apps?filter\[bundleId\]=${APPSTORE_BUNDLE_ID}")
  APPSTORE_APP_ID=$(printf '%s' "$APP_LOOKUP_RES" | jq -r '.data[0].id // empty')
  if [ -z "$APPSTORE_APP_ID" ]; then
    echo "❌ No App found in App Store Connect for bundleId: ${APPSTORE_BUNDLE_ID}"
    exit 1
  fi
  echo "   Resolved App ID: ${APPSTORE_APP_ID}"
fi

# ------------------------------------------------------------------------------
# 5. Create buildUploads session (POST /v1/buildUploads)
# ------------------------------------------------------------------------------
echo ""
echo "📝 [Step 4/7] Creating buildUpload session on App Store Connect..."
CREATE_UPLOAD_PAYLOAD=$(jq -cn \
  --arg appId "$APPSTORE_APP_ID" \
  --arg shortVer "$SHORT_VERSION" \
  --arg buildVer "$BUILD_VERSION" \
  --arg platform "$PLATFORM" \
  '{
    data: {
      type: "buildUploads",
      attributes: {
        cfBundleShortVersionString: $shortVer,
        cfBundleVersion: $buildVer,
        platform: $platform
      },
      relationships: {
        app: {
          data: {
            type: "apps",
            id: $appId
          }
        }
      }
    }
  }')

CREATE_UPLOAD_RES=$(asc_api_request "POST" "${API_BASE_URL}/v1/buildUploads" "$CREATE_UPLOAD_PAYLOAD")
BUILD_UPLOAD_ID=$(printf '%s' "$CREATE_UPLOAD_RES" | jq -r '.data.id')
echo "✅ Created buildUpload ID: ${BUILD_UPLOAD_ID}"

# ------------------------------------------------------------------------------
# 6. Register .ipa file & retrieve pre-signed uploadOperations
#    (POST /v1/buildUploadFiles)
# ------------------------------------------------------------------------------
echo ""
echo "📦 [Step 5/7] Registering .ipa file & requesting pre-signed upload URLs..."
RESERVE_FILE_PAYLOAD=$(jq -cn \
  --arg uploadId "$BUILD_UPLOAD_ID" \
  --arg fileName "$FILENAME" \
  --argjson fileSize "$FILE_SIZE" \
  '{
    data: {
      type: "buildUploadFiles",
      attributes: {
        assetType: "ASSET",
        fileName: $fileName,
        fileSize: $fileSize,
        uti: "com.apple.ipa"
      },
      relationships: {
        buildUpload: {
          data: {
            type: "buildUploads",
            id: $uploadId
          }
        }
      }
    }
  }')

RESERVE_FILE_RES=$(asc_api_request "POST" "${API_BASE_URL}/v1/buildUploadFiles" "$RESERVE_FILE_PAYLOAD")
BUILD_UPLOAD_FILE_ID=$(printf '%s' "$RESERVE_FILE_RES" | jq -r '.data.id')
OP_COUNT=$(printf '%s' "$RESERVE_FILE_RES" | jq '.data.attributes.uploadOperations | length')
echo "✅ Reserved buildUploadFile ID: ${BUILD_UPLOAD_FILE_ID} (${OP_COUNT} chunk operation(s))"

# Upload each byte chunk returned in uploadOperations[]
for ((i = 0; i < OP_COUNT; i++)); do
  OP_JSON=$(printf '%s' "$RESERVE_FILE_RES" | jq -c ".data.attributes.uploadOperations[$i]")
  OP_METHOD=$(printf '%s' "$OP_JSON" | jq -r '.method')
  OP_URL=$(printf '%s' "$OP_JSON" | jq -r '.url')
  OP_OFFSET=$(printf '%s' "$OP_JSON" | jq -r '.offset')
  OP_LENGTH=$(printf '%s' "$OP_JSON" | jq -r '.length')
  OP_HOST=$(printf '%s' "$OP_URL" | awk -F/ '{print $3}')

  echo "   ⬆️  Uploading chunk $((i + 1))/${OP_COUNT} (offset=${OP_OFFSET}, length=${OP_LENGTH} bytes) -> ${OP_HOST}..."

  # Build dynamic header arguments from uploadOperations[].requestHeaders
  HEADER_ARGS=()
  while IFS= read -r hdr; do
    [ -n "$hdr" ] && HEADER_ARGS+=(--header "$hdr")
  done < <(printf '%s' "$OP_JSON" | jq -r '.requestHeaders[]? | "\(.name): \(.value)"')

  CHUNK_FILE=$(mktemp)
  tail -c +$((OP_OFFSET + 1)) "$DOWNLOAD_PATH" | head -c "$OP_LENGTH" > "$CHUNK_FILE"

  curl --fail --show-error --location \
    "${CURL_VERBOSE_ARGS[@]}" \
    --request "$OP_METHOD" \
    "${HEADER_ARGS[@]}" \
    --upload-file "$CHUNK_FILE" \
    "$OP_URL"

  rm -f "$CHUNK_FILE"
done

# ------------------------------------------------------------------------------
# 7. Commit the uploaded .ipa file (PATCH /v1/buildUploadFiles/{id})
# ------------------------------------------------------------------------------
echo ""
echo "💾 [Step 6/7] Committing buildUploadFile ${BUILD_UPLOAD_FILE_ID}..."
COMMIT_PAYLOAD=$(jq -cn \
  --arg fileId "$BUILD_UPLOAD_FILE_ID" \
  '{
    data: {
      type: "buildUploadFiles",
      id: $fileId,
      attributes: {
        uploaded: true
      }
    }
  }')

asc_api_request "PATCH" "${API_BASE_URL}/v1/buildUploadFiles/${BUILD_UPLOAD_FILE_ID}" "$COMMIT_PAYLOAD" > /dev/null
echo "✅ Upload committed!"

# ------------------------------------------------------------------------------
# 8. Poll buildUpload status until COMPLETE or FAILED (GET /v1/buildUploads/{id})
# ------------------------------------------------------------------------------
echo ""
echo "⏳ [Step 7/7] Polling App Store Connect buildUpload processing status..."
MAX_POLLS="${APPSTORE_MAX_POLLS:-24}" # 24 * 5s = 120 seconds safe timeout
POLL_INTERVAL="${APPSTORE_POLL_INTERVAL:-5}"
POLL_COUNT=0
UPLOAD_STATE="PROCESSING"

while [[ "$UPLOAD_STATE" != "COMPLETE" && "$UPLOAD_STATE" != "FAILED" ]]; do
  POLL_COUNT=$((POLL_COUNT + 1))
  if [ "$POLL_COUNT" -gt "$MAX_POLLS" ]; then
    echo "⚠️  Reached polling timeout ($((MAX_POLLS * POLL_INTERVAL))s) while build is still in state: ${UPLOAD_STATE}."
    echo "   App Store Connect will continue processing asynchronously in the background."
    break
  fi

  sleep "$POLL_INTERVAL"
  STATUS_RES=$(asc_api_request "GET" "${API_BASE_URL}/v1/buildUploads/${BUILD_UPLOAD_ID}")
  UPLOAD_STATE=$(printf '%s' "$STATUS_RES" | jq -r '.data.attributes.state.state // "UNKNOWN"')
  echo "   [Poll ${POLL_COUNT}/${MAX_POLLS}] State: ${UPLOAD_STATE}"
done

if [ "$UPLOAD_STATE" = "FAILED" ]; then
  echo "" >&2
  echo "❌ App Store Connect rejected the uploaded build during post-upload validation:" >&2
  printf '%s\n' "$STATUS_RES" | jq '.data.attributes.state.errors' >&2
  exit 1
elif [ "$UPLOAD_STATE" = "COMPLETE" ]; then
  echo "✅ App Store Connect validation complete (state: COMPLETE)! The build is now available in TestFlight."
  WARNINGS_COUNT=$(printf '%s' "$STATUS_RES" | jq '.data.attributes.state.warnings | length')
  if [ "$WARNINGS_COUNT" -gt 0 ]; then
    echo "⚠️  Validation warnings:"
    printf '%s\n' "$STATUS_RES" | jq '.data.attributes.state.warnings'
  fi
fi

echo ""
echo "🎉 Track 4 (Apple App Store Connect — IPA) completed successfully!"
