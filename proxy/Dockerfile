FROM debian:bookworm-slim

# Install squid-openssl (which includes --with-openssl and security_file_certgen for ssl-bump)
RUN apt-get update && \
    apt-get install -y --no-install-recommends squid-openssl ca-certificates openssl && \
    rm -rf /var/lib/apt/lists/*

# Initialize the dynamic SSL certificate storage DB used by ssl-bump
RUN mkdir -p /var/lib/squid /var/log/squid && \
    /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB && \
    chown -R proxy:proxy /var/lib/squid /var/log/squid

EXPOSE 3128

CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
