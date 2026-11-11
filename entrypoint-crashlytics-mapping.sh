#!/usr/bin/env bash
set -euo pipefail

echo "====================================================================="
echo "🔥 Track 6: Firebase Crashlytics — R8/ProGuard Mapping Upload (Firebase CLI)"
echo "====================================================================="

# ------------------------------------------------------------------------------
# 1. Validate required inputs
# ------------------------------------------------------------------------------
MAPPING_FILE_URL="${CRASHLYTICS_MAPPING_FILE_URL:-${PLAYSTORE_MAPPING_FILE_URL:-}}"
RESOURCE_FILE_URL="${CRASHLYTICS_RESOURCE_FILE_URL:-${PLAYSTORE_MAPPING_RESOURCE_URL:-}}"
APP_ID="${CRASHLYTICS_APP_ID:-${FIREBASE_AAB_APP_ID:-${FIREBASE_APP_ID:-}}}"

: "${MAPPING_FILE_URL:?Error: CRASHLYTICS_MAPPING_FILE_URL environment variable is required}"
: "${RESOURCE_FILE_URL:?Error: CRASHLYTICS_RESOURCE_FILE_URL environment variable is required}"
: "${APP_ID:?Error: CRASHLYTICS_APP_ID (or FIREBASE_AAB_APP_ID) environment variable is required}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?Error: GOOGLE_APPLICATION_CREDENTIALS environment variable is required}"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo "❌ Service account key file not found at: $GOOGLE_APPLICATION_CREDENTIALS"
  exit 1
fi

CURL_VERBOSE_ARGS=()
FIREBASE_DEBUG_ARGS=()
if [ "${CRASHLYTICS_DEBUG:-${FIREBASE_DEBUG:-false}}" = "true" ]; then
  CURL_VERBOSE_ARGS+=(--verbose)
  FIREBASE_DEBUG_ARGS+=(--debug)
fi

# ------------------------------------------------------------------------------
# 2. Configure JVM Proxy Options for crashlytics-buildtools.jar
#    `firebase crashlytics:mappingfile:upload` spawns `java -jar crashlytics-buildtools-*.jar`.
#    Because Java ignores HTTPS_PROXY/HTTP_PROXY environment variables by default,
#    we translate HTTPS_PROXY into JAVA_TOOL_OPTIONS (-Dhttps.proxyHost / -Dhttps.proxyPort).
# ------------------------------------------------------------------------------
PROXY_URL="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
if [ -n "$PROXY_URL" ]; then
  PROXY_HOST_PORT="${PROXY_URL#*://}"
  PROXY_HOST_PORT="${PROXY_HOST_PORT%%/*}"
  PROXY_HOST="${PROXY_HOST_PORT%%:*}"
  PROXY_PORT="${PROXY_HOST_PORT##*:}"
  if [ "$PROXY_HOST" = "$PROXY_PORT" ]; then
    PROXY_PORT="3128"
  fi
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=${PROXY_PORT} -Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=${PROXY_PORT}"
fi

# ------------------------------------------------------------------------------
# 3. Download mapping.txt and resource XML from Artifactory
# ------------------------------------------------------------------------------
MAPPING_PATH="/tmp/mapping.txt"
RESOURCE_XML_PATH="/tmp/com_google_firebase_crashlytics_mappingfileid.xml"

echo ""
echo "📥 [Step 1/2] Downloading mapping.txt and resource XML from Artifactory..."
echo "   Mapping URL:  ${MAPPING_FILE_URL}"
echo "   Resource URL: ${RESOURCE_FILE_URL}"
echo "   Proxy:        ${PROXY_URL:-none}"
echo "---------------------------------------------------------------------"

curl --fail --show-error --location \
  "${CURL_VERBOSE_ARGS[@]}" \
  ${ARTIFACTORY_AUTH_HEADER:+-H "$ARTIFACTORY_AUTH_HEADER"} \
  --output "$MAPPING_PATH" \
  "$MAPPING_FILE_URL"

curl --fail --show-error --location \
  "${CURL_VERBOSE_ARGS[@]}" \
  ${ARTIFACTORY_AUTH_HEADER:+-H "$ARTIFACTORY_AUTH_HEADER"} \
  --output "$RESOURCE_XML_PATH" \
  "$RESOURCE_FILE_URL"

MAPPING_SIZE=$(wc -c < "$MAPPING_PATH" | tr -d ' ')
RESOURCE_SIZE=$(wc -c < "$RESOURCE_XML_PATH" | tr -d ' ')
echo "✅ Downloaded mapping.txt (${MAPPING_SIZE} bytes) and resource XML (${RESOURCE_SIZE} bytes)"

# ------------------------------------------------------------------------------
# 4. Upload mapping.txt via Standalone Firebase CLI
# ------------------------------------------------------------------------------
echo ""
echo "🚀 [Step 2/2] Uploading mapping.txt to Firebase Crashlytics via Firebase CLI..."
echo "   App ID:       ${APP_ID}"
echo "   JVM Options:  ${JAVA_TOOL_OPTIONS:-none}"
echo "---------------------------------------------------------------------"

firebase crashlytics:mappingfile:upload "$MAPPING_PATH" \
  --app="$APP_ID" \
  --resource-file="$RESOURCE_XML_PATH" \
  "${FIREBASE_DEBUG_ARGS[@]}"

echo ""
echo "🎉 Track 6 (Firebase Crashlytics — Mapping File Upload) completed successfully!"
