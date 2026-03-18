#!/usr/bin/env bash
# setup.sh — One-shot installer for Logos Blockchain Node on Ubuntu 24.04 / Debian 12+
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mart1n-xyz/logos-node-vps/main/setup.sh | bash
#   # or, after cloning:
#   sudo bash setup.sh
#
# Idempotent: safe to re-run. Existing .env and chain data are preserved.

set -euo pipefail

REPO_URL="https://github.com/mart1n-xyz/logos-node-vps.git"
INSTALL_DIR="/opt/logos-node"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${GREEN}[setup]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[setup]${RESET} $*"; }
err()     { echo -e "${RED}[setup] ERROR:${RESET} $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (or with sudo)."
fi

# ── Install Docker if missing ─────────────────────────────────────────────────
install_docker() {
    info "Installing Docker..."
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release

    # Detect distro (ubuntu or debian)
    DISTRO=$(. /etc/os-release && echo "${ID}")
    if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" ]]; then
        err "Unsupported distro: $DISTRO. Only Ubuntu and Debian are supported."
    fi

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO} \
$(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    info "Docker installed."
}

if ! command -v docker &>/dev/null; then
    install_docker
else
    info "Docker already installed: $(docker --version)"
fi

# Verify docker compose plugin (v2)
if ! docker compose version &>/dev/null; then
    info "Installing docker-compose-plugin..."
    apt-get update -qq
    apt-get install -y docker-compose-plugin
fi
info "Docker Compose: $(docker compose version)"

# ── Clone or update repo ──────────────────────────────────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    info "Repo already exists at ${INSTALL_DIR} — pulling latest..."
    git -C "${INSTALL_DIR}" pull --ff-only
else
    info "Cloning repo to ${INSTALL_DIR}..."
    git clone "${REPO_URL}" "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}"

# ── Create .env from example if it doesn't exist ─────────────────────────────
if [[ ! -f .env ]]; then
    cp .env.example .env
    warn ".env created from .env.example — review and edit it before going live:"
    warn "  nano ${INSTALL_DIR}/.env"
else
    info ".env already exists — skipping copy."
fi

# ── Install / update the updater service ─────────────────────────────────────
info "Installing logos-node-updater systemd service..."
chmod +x "${INSTALL_DIR}/updater.sh"
cp "${INSTALL_DIR}/logos-node-updater.service" /etc/systemd/system/logos-node-updater.service
systemctl daemon-reload
systemctl enable logos-node-updater
systemctl restart logos-node-updater
info "Updater service running on 127.0.0.1:3002"

# ── Build and start ───────────────────────────────────────────────────────────
info "Building image and starting node (this may take a few minutes on first run)..."
docker compose up -d --build

# ── Done ──────────────────────────────────────────────────────────────────────
HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}✓ Logos Blockchain Node is running!${RESET}"
echo ""
echo -e "  Dashboard : ${BOLD}http://${HOST_IP}:3001${RESET}"
echo ""
echo "  View logs :"
echo "    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
echo ""
echo "  Stop node :"
echo "    docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
echo ""
echo -e "${YELLOW}Tip:${RESET} If your firewall is active, open UDP/3000 (p2p) and TCP/3001 (dashboard):"
echo "  ufw allow 3000/udp && ufw allow 3001/tcp"
