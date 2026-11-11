# Base image: minimal Debian Linux (100% Pure Bash + CLI — no Node.js, Python, or Java needed)
FROM debian:bookworm-slim

# 1. Install CLI dependencies for all 5 Pure REST tracks:
#    - bash, curl, ca-certificates: HTTP/REST requests & TLS validation
#    - openssl, xxd: Offline RS256 (Google OAuth2) & ES256 (Apple App Store Connect) JWT signing
#    - jq: JSON payload construction & response parsing
#    - unzip, libplist-utils: .ipa Payload/*.app/Info.plist metadata inspection
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      curl \
      ca-certificates \
      openssl \
      xxd \
      jq \
      unzip \
      libplist-utils && \
    rm -rf /var/lib/apt/lists/*

# 2. Trust the Corporate Root CA for HTTPS Interception (SSL Inspection / MITM)
COPY proxy/certs/corp-root-ca.crt /usr/local/share/ca-certificates/corp-root-ca.crt
RUN update-ca-certificates

# 3. Copy the 5 track entrypoint scripts
COPY entrypoint-firebase-aab.sh \
     entrypoint-firebase-ipa.sh \
     entrypoint-playstore-aab.sh \
     entrypoint-appstore-ipa.sh \
     entrypoint-appgallery-aab.sh \
     /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint-*.sh

WORKDIR /workspace
