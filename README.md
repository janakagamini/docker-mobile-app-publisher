# Docker Based Mobile App Publisher

Containerized CD runners that download mobile binaries (`.aab` or `.ipa`) from an Artifactory server and publish them across **5 distinct tracks** using **100% Pure Bash + REST APIs** (`curl`, `openssl`, `jq`),

- A mock artifactory is provided for testing purposes.
- A proxy server is provided to simulate corporate firewalls where all traffic is routed through a local **Squid Egress Proxy with SSL Inspection (`ssl-bump`)**.

---

## 1. The Publishing Tracks

Tracks 1–5 share a single minimal [`Dockerfile`](./Dockerfile) (`debian:bookworm-slim` — zero Node.js, Python, Java, or `npm` packages) using 100% Pure REST APIs. Track 6 uses a dedicated [`Dockerfile.crashlytics`](./Dockerfile.crashlytics) with the standalone Firebase CLI binary (`firebase-tools-linux`) and a headless JRE to upload R8/ProGuard `mapping.txt` files to Firebase Crashlytics:

| Track | Compose Service | Dockerfile / Entrypoint | Target Store / Service | Artifact | Mechanism |
|-------|-----------------|-------------------------|------------------------|----------|-----------|
| **Track 1** | `firebase-aab` | [`Dockerfile`](./Dockerfile) / [`entrypoint-firebase-aab.sh`](./entrypoint-firebase-aab.sh) | Firebase App Distribution | `.aab` | Pure REST (`RS256` JWT -> `oauth2.googleapis.com`) |
| **Track 2** | `firebase-ipa` | [`Dockerfile`](./Dockerfile) / [`entrypoint-firebase-ipa.sh`](./entrypoint-firebase-ipa.sh) | Firebase App Distribution | `.ipa` | Pure REST (`RS256` JWT -> `oauth2.googleapis.com`) |
| **Track 3** | `playstore-aab` | [`Dockerfile`](./Dockerfile) / [`entrypoint-playstore-aab.sh`](./entrypoint-playstore-aab.sh) | Google Play Console | `.aab` | Pure REST (`RS256` JWT -> `oauth2.googleapis.com`) |
| **Track 4** | `appstore-ipa` | [`Dockerfile`](./Dockerfile) / [`entrypoint-appstore-ipa.sh`](./entrypoint-appstore-ipa.sh) | Apple App Store Connect | `.ipa` | Pure REST (Offline `ES256` JWT, no token exchange) |
| **Track 5** | `appgallery-aab` | [`Dockerfile`](./Dockerfile) / [`entrypoint-appgallery-aab.sh`](./entrypoint-appgallery-aab.sh) | Huawei AppGallery Connect | `.aab` / `.apk` | Pure REST (OAuth2 `client_credentials` -> `connect-api.cloud.huawei.com`) |
| **Track 6** | `crashlytics-mapping` (note: Publishing dSYM files is not possible in a linux environment, hence it's excluded) | [`Dockerfile.crashlytics`](./Dockerfile.crashlytics) / [`entrypoint-crashlytics-mapping.sh`](./entrypoint-crashlytics-mapping.sh) | Firebase Crashlytics | `mapping.txt` + XML | Standalone `firebase` CLI binary + pre-cached `crashlytics-buildtools.jar` |

---

## 2. Simulating Corporate Firewall Allowlist (Egress URLs)

### Runtime Egress (When the CD Container Runs)

Because all 5 tracks use pure REST via `curl` and sign their JWTs/digests locally with `openssl`/`sha256sum`, **zero SDK telemetry or package registry URLs are contacted**. Only the domains below are required at runtime (configured in [`proxy/allowed-domains.txt`](./proxy/allowed-domains.txt)):

| # | Domain | Port / Protocol | Used By Tracks | Purpose & REST Endpoints Called | Official Platform Documentation |
|---|--------|-----------------|----------------|---------------------------------|---------------------------------|
| 1 | `oauth2.googleapis.com` | `443` (`HTTPS`) | **Track 1** (`firebase-aab`)<br>**Track 2** (`firebase-ipa`)<br>**Track 3** (`playstore-aab`) | Exchanges the offline-signed Google Service Account `RS256` JWT for a short-lived OAuth2 Bearer token (`POST /token`). | • https://developers.google.com/identity/protocols/oauth2/service-account#httprest |
| 2 | `firebaseappdistribution.googleapis.com` | `443` (`HTTPS`) | **Track 1** (`firebase-aab`)<br>**Track 2** (`firebase-ipa`) | 1. Upload `.aab` or `.ipa` (`POST /upload/v1/projects/{projectNumber}/apps/{appId}/releases:upload`)<br>2. Poll release operation (`GET /v1/{operationName}`)<br>3. Attach release notes (`PATCH /v1/{releaseName}?updateMask=release_notes.text`)<br>4. Distribute to testers/groups (`POST /v1/{releaseName}:distribute`) | • https://firebase.google.com/docs/reference/rest/app-distribution/rest/v1/media/upload<br>• https://firebase.google.com/docs/reference/rest/app-distribution/rest/v1/projects.apps.releases.operations/get<br>• https://firebase.google.com/docs/reference/rest/app-distribution/rest/v1/projects.apps.releases/patch<br>• https://firebase.google.com/docs/reference/rest/app-distribution/rest/v1/projects.apps.releases/distribute |
| 3 | `androidpublisher.googleapis.com` | `443` (`HTTPS`) | **Track 3** (`playstore-aab`) | 1. Create edit session (`POST /androidpublisher/v3/applications/{packageName}/edits`)<br>2. Upload `.aab` (`POST /upload/androidpublisher/v3/applications/{packageName}/edits/{editId}/bundles?uploadType=media`)<br>3. Assign track (`PUT /androidpublisher/v3/applications/{packageName}/edits/{editId}/tracks/{track}`)<br>4. Commit edit (`POST /androidpublisher/v3/applications/{packageName}/edits/{editId}:commit`) | • https://developers.google.com/android-publisher/api-ref/rest/v3/edits/insert<br>• https://developers.google.com/android-publisher/api-ref/rest/v3/edits.bundles/upload<br>• https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks/update<br>• https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit |
| 4 | `api.appstoreconnect.apple.com` | `443` (`HTTPS`) | **Track 4** (`appstore-ipa`) | 1. Create build upload (`POST /v1/buildUploads`)<br>2. Reserve `.ipa` & get pre-signed chunk URLs (`POST /v1/buildUploadFiles`)<br>3. Commit uploaded file (`PATCH /v1/buildUploadFiles/{id}`)<br>4. Poll build upload status (`GET /v1/buildUploads/{id}`) | • https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests<br>• https://developer.apple.com/documentation/appstoreconnectapi/post-v1-builduploads<br>• https://developer.apple.com/documentation/appstoreconnectapi/post-v1-builduploadfiles<br>• https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-builduploadfiles-_id_<br>• https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builduploads-_id_ |
| 5 | `.object-storage.apple.com` *(e.g. `northamerica-1.object-storage.apple.com`)* | `443` (`HTTPS`) | **Track 4** (`appstore-ipa`) | Pre-signed binary chunk storage host returned dynamically in `uploadOperations[].url` (`PUT` raw `.ipa` byte chunks). | • https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect<br>• https://developer.apple.com/documentation/appstoreconnectapi/uploadoperation |
| 6 | `connect-api.cloud.huawei.com` | `443` (`HTTPS`) | **Track 5** (`appgallery-aab`) | 1. Exchange API Client credentials for Bearer token (`POST /api/oauth2/v1/token`)<br>2. Obtain pre-signed OBS upload URL (`GET /api/publish/v2/upload-url/for-obs`)<br>3. Bind uploaded file to app draft (`PUT /api/publish/v2/app-file-info`)<br>4. Submit for review, optional (`POST /api/publish/v2/app-submit`) | • https://developer.huawei.com/consumer/en/doc/development/AppGallery-connect-References/agcapi-obtain_token-0000001158365043<br>• https://developer.huawei.com/consumer/en/doc/development/AppGallery-connect-References/agcapi-upload-url-new-0000001158365047<br>• https://developer.huawei.com/consumer/en/doc/development/AppGallery-connect-References/agcapi-app-file-info-0000001111685202<br>• https://developer.huawei.com/consumer/en/doc/development/AppGallery-connect-References/agcapi-app-submit-0000001158245059 |
| 7 | `.myhuaweicloud.com` *(observed: `nsp-appgallery-agcfs-dra.obs.ap-southeast-3.myhuaweicloud.com` for Singapore/Asia-Pacific distribution; the region varies with the app's release countries)* | `443` (`HTTPS`) | **Track 5** (`appgallery-aab`) | Pre-signed Huawei Cloud OBS storage host returned dynamically in `urlInfo.url` (`PUT` raw `.aab` / `.apk` binary with SigV4 `x-amz-*` headers). | • https://developer.huawei.com/consumer/en/doc/development/AppGallery-connect-Guides/agcapi-upload-file-new-0000001158245057<br>• https://developer.huawei.com/consumer/en/doc/development/AppGallery-connect-References/agcapi-upload-url-new-0000001158365047 |
| 8 | `firebasecrashlyticssymbols.googleapis.com` | `443` (`HTTPS`) | **Track 6** (`crashlytics-mapping`) | Uploads R8/ProGuard `mapping.txt` via `firebase crashlytics:mappingfile:upload` (`PUT /v1/project/-/app/{appId}/upload/java/{mappingFileId}`). | • https://firebase.google.com/docs/crashlytics/get-deobfuscated-reports<br>• https://firebase.google.com/docs/cli#crashlytics_commands |

> **Important Prerequisite for Track 1 (`firebase-aab`)**: Uploading an `.aab` to Firebase App Distribution requires the Firebase project to be linked to Google Play in the Firebase Console (*Project Settings -> Integrations -> Google Play*). The communication between Firebase and Google Play happens entirely server-to-server inside Google's cloud and requires **no additional egress domains** from your corporate firewall.

### Build-Time Egress (Only if building the Docker images inside the corporate network)

* **Tracks 1–5 ([`Dockerfile`](./Dockerfile))**:
  * `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` — to pull `debian:bookworm-slim`
  * `deb.debian.org`, `security.debian.org` — to install `bash`, `curl`, `ca-certificates`, `openssl`, `xxd`, `jq`, `unzip`, `libplist-utils`
* **Track 6 ([`Dockerfile.crashlytics`](./Dockerfile.crashlytics))**:
  * Same Debian base & apt repositories (`default-jre-headless`, `ca-certificates-java`)
  * `github.com`, `objects.githubusercontent.com` — to download the pinned standalone `firebase-tools-linux` binary
  * `dl.google.com` — to pre-cache `firebase-crashlytics-buildtools-3.0.2.jar` at build time so `dl.google.com` is not needed at runtime

---

## 3. HTTPS Interception (SSL Inspection / MITM) Simulation

Our local Squid proxy ([`proxy/Dockerfile`](./proxy/Dockerfile) + [`proxy/squid.conf`](./proxy/squid.conf)) uses `squid-openssl` with `ssl-bump` enabled to simulate a corporate firewall that terminates TLS and dynamically re-signs all `HTTPS` certificates using a private **Corporate Root CA** ([`proxy/certs/corp-root-ca.crt`](./proxy/certs/corp-root-ca.crt)).

Because all 5 tracks use `curl` exclusively for network calls, trusting the corporate proxy CA requires only standard OS trust store registration in [`Dockerfile`](./Dockerfile):
```dockerfile
COPY proxy/certs/corp-root-ca.crt /usr/local/share/ca-certificates/corp-root-ca.crt
RUN update-ca-certificates
```

---

## 4. Setup & Mock Artifactory

### 4.1 Environment & Credentials Configuration
1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```
2. Populate `.env` with your platform application identifiers and release parameters.
3. Create the `credentials` folder in the project root. It is **not** in the repository; the whole folder is excluded by `.gitignore`:
   ```bash
   mkdir -p credentials
   ```
   > Create it yourself **before** running `docker compose`. Otherwise Docker creates it as an empty, root-owned directory for the `./credentials:/credentials:ro` bind mount.
4. Add the credential files for the tracks you plan to run. The file names must match **exactly**, because they are hard-coded in [`docker-compose.yml`](./docker-compose.yml):

   | File | Used by tracks | How to obtain it |
   |------|----------------|------------------|
   | `credentials/service-account.json` | 1 `firebase-aab`, 2 `firebase-ipa`, 3 `playstore-aab`, 6 `crashlytics-mapping` | Google Cloud Console → *IAM & Admin → Service Accounts* → select (or create) the account → *Keys → Add key → Create new key → JSON*. Save the downloaded file under this name without editing it. Give the account the *Firebase App Distribution Admin* role (Tracks 1, 2), the *Firebase Crashlytics Admin* role (Track 6), and invite it in Play Console → *Users and permissions* with release permissions for the app (Track 3). |
   | `credentials/AuthKey.p8` | 4 `appstore-ipa` | App Store Connect → *Users and Access → Integrations → App Store Connect API* → generate a key (role *App Manager* or higher) and download `AuthKey_<KEYID>.p8`. You can only download it once. Rename it to `AuthKey.p8`. Put the Key ID in `APPSTORE_KEY_ID` and the Issuer ID in `APPSTORE_ISSUER_ID` in `.env`. |
   | `credentials/huawei-api-client.json` | 5 `appgallery-aab` | AppGallery Connect → *Users and permissions → API key → Connect API* → create an API client (role *App administrator*). Write its Client ID and Key into a JSON file in the format shown below. You can also leave this file out and set `HUAWEI_CLIENT_ID` / `HUAWEI_CLIENT_SECRET` in `.env` instead. |

   Format of `credentials/huawei-api-client.json`:
   ```json
   {
     "client_id": "1234567890123456789",
     "client_secret": "REPLACE_WITH_HUAWEI_CONNECT_API_CLIENT_SECRET"
   }
   ```

   When you're done, the folder should contain:
   ```
   credentials/
   ├── service-account.json       # Tracks 1, 2, 3, 6
   ├── AuthKey.p8                 # Track 4
   └── huawei-api-client.json     # Track 5
   ```

> [!CAUTION]
> `.env` and the entire `credentials/` folder are excluded by `.gitignore`, along with `*.p8`, `*.p12`, `*.key`, `*.jks` and `*.keystore` anywhere in the repo. Never force-add them (`git add -f`).

### 4.2 Placing Test Binaries in Mock Artifactory
The local `artifactory` Nginx container serves files from the `./mock-artifactory` directory at `http://artifactory.corp.internal/...`. All mobile binaries (`.aab`, `.ipa`, `.apk`, `.zip`, `.dSYM`, etc.) and symbol mapping files are excluded by `.gitignore` so they are never committed to git.

To test publishing, copy your build artifacts into the matching folder structure inside `mock-artifactory/generic-local/`:
* **Android App Bundle (`.aab`)**:
  ```
  mock-artifactory/generic-local/mobile-app-aab/<version>/app-release.aab
  ```
* **iOS Package (`.ipa`)**:
  ```
  mock-artifactory/generic-local/mobile-app-ipa/<version>/app-release.ipa
  ```
* **Android APK (`.apk`)**:
  ```
  mock-artifactory/generic-local/mobile-app/<version>/app-release.apk
  ```
* **Crashlytics Mapping (`mapping.txt` and XML)**:
  ```
  mock-artifactory/generic-local/mobile-app-aab/<version>/mapping.txt
  mock-artifactory/generic-local/mobile-app-aab/<version>/com_google_firebase_crashlytics_mappingfileid.xml
  ```

Update the corresponding `*_ARTIFACT_URL` variables in `.env` to match the version and file name you placed.

---

## 5. Running the Experiments

```bash
# 1. Start the Squid proxy and mock Artifactory
docker compose up -d proxy artifactory

# 2. Run Track 1: Firebase App Distribution (Android AAB)
docker compose run --rm firebase-aab

# 3. Run Track 2: Firebase App Distribution (iOS IPA)
docker compose run --rm firebase-ipa

# 4. Run Track 3: Google Play Console (Android AAB)
docker compose run --rm playstore-aab

# 5. Run Track 4: Apple App Store Connect (iOS IPA)
docker compose run --rm appstore-ipa

# 6. Run Track 5: Huawei AppGallery Connect (Android AAB / APK)
docker compose run --rm appgallery-aab

# 7. Run Track 6: Firebase Crashlytics Mapping Upload (Standalone Firebase CLI)
docker compose run --rm crashlytics-mapping
```

To inspect allowed (`TCP_TUNNEL/200`, `TCP_MISS/200`) and blocked (`TCP_DENIED/403`) URLs in real time (including full decrypted HTTPS paths via `ssl-bump`):
```bash
docker compose exec proxy tail -f /var/log/squid/access.log
```