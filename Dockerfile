# Logos Blockchain Node — Railway Dockerfile
# Update NODE_VERSION and CIRCUITS_VERSION when new releases are published.

ARG NODE_VERSION=0.2.1
ARG CIRCUITS_VERSION=0.4.1

# ── Download stage ────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS downloader

ARG NODE_VERSION
ARG CIRCUITS_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /download

# Download node binary tarball
# Asset naming: logos-blockchain-node-linux-x86_64-v{version}.tar.gz
# If naming differs, adjust the URL (some releases may omit the `v` prefix).
RUN curl -fsSL \
    "https://github.com/logos-co/nomos-node/releases/download/${NODE_VERSION}/logos-blockchain-node-linux-x86_64-${NODE_VERSION}.tar.gz" \
    -o node.tar.gz \
    && tar -xzf node.tar.gz \
    && find . -name 'logos-blockchain-node' -type f -exec mv {} /download/logos-blockchain-node \; \
    && chmod +x /download/logos-blockchain-node

# Download ZK circuits tarball
RUN curl -fsSL \
    "https://github.com/logos-co/nomos-node/releases/download/${NODE_VERSION}/logos-blockchain-circuits-v${CIRCUITS_VERSION}-linux-x86_64.tar.gz" \
    -o circuits.tar.gz \
    && tar -xzf circuits.tar.gz

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM ubuntu:24.04

ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

ARG CIRCUITS_VERSION

# Install runtime dependencies (glibc 2.39 is provided by ubuntu:24.04)
# python3 is used by the web dashboard (stdlib only, no pip required)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Install the node binary
COPY --from=downloader /download/logos-blockchain-node /usr/local/bin/logos-blockchain-node

# Install circuits to a well-known location
RUN mkdir -p /opt/logos-blockchain/circuits
COPY --from=downloader /download/logos-blockchain-circuits-v${CIRCUITS_VERSION}-linux-x86_64/ \
    /opt/logos-blockchain/circuits/

# Tell the node where the circuits live
ENV LOGOS_BLOCKCHAIN_CIRCUITS=/opt/logos-blockchain/circuits

# Default bootstrap peers — override via BOOTSTRAP_PEERS in .env
ENV BOOTSTRAP_PEERS="/ip4/65.109.51.37/udp/3000/quic-v1/p2p/12D3KooWL7a8LBbLRYnabptHPFBCmAs49Y7cVMqvzuSdd43tAJk8 /ip4/65.109.51.37/udp/3001/quic-v1/p2p/12D3KooWPLeAcachoUm68NXGD7tmNziZkVeMmeBS5NofyukuMRJh /ip4/65.109.51.37/udp/3002/quic-v1/p2p/12D3KooWKFNe4gS5DcCcRUVGdMjZp3fUWu6q6gG5R846Ui1pccHD /ip4/65.109.51.37/udp/3003/quic-v1/p2p/12D3KooWAnriLgXyQnGTYz1zPWPkQL3rthTKYLzuAP7MMnbgsxzR"

# Persistent data directory (mounted as a Railway volume)
# Volume mount handled by Railway — do not use VOLUME directive
WORKDIR /data

# Copy entrypoint and dashboard
COPY entrypoint.sh  /usr/local/bin/entrypoint.sh
COPY dashboard.py   /usr/local/bin/dashboard.py
COPY dashboard.html /usr/local/bin/dashboard.html
COPY assets/        /usr/local/bin/assets/
RUN chmod +x /usr/local/bin/entrypoint.sh

# p2p (UDP/QUIC), node HTTP API (internal), and web dashboard
EXPOSE 3000/udp
EXPOSE 8080/tcp
EXPOSE 3001/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
