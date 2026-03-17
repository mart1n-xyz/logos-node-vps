#!/usr/bin/env bash
# entrypoint.sh — Logos Blockchain node startup script for Railway
#
# First run:  generates keys + user_config.yaml via `init`, then starts node.
# Later runs: skips init and starts directly from the existing config.
#
# Environment variables (all optional — see railway.toml for defaults):
#   BOOTSTRAP_PEERS     Space-separated multiaddrs for the devnet bootstrap peers.
#   API_PORT            TCP port for the node's HTTP API (default: 8080).
#   DATA_DIR            Directory for config + chain state (default: /data).
#   DASHBOARD_PASSWORD  If set, enables basic auth on the web dashboard.
#   NODE_API_PORT       Same as API_PORT — used by dashboard.py (default: 8080).

set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
API_PORT="${API_PORT:-8080}"
CONFIG_FILE="${DATA_DIR}/user_config.yaml"
LOG_FILE="${DATA_DIR}/node.log"

# LOG_MAX_BYTES = 10 MiB
LOG_MAX_BYTES=$((10 * 1024 * 1024))

# Ensure the data directory exists (volume may not be pre-populated)
mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"

# ── Log rotation ───────────────────────────────────────────────────────────────
# Truncate the log file on startup if it exceeds 10 MiB to avoid runaway growth.
if [[ -f "${LOG_FILE}" ]]; then
    LOG_SIZE=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)
    if (( LOG_SIZE > LOG_MAX_BYTES )); then
        echo "[entrypoint] Log file is ${LOG_SIZE} bytes — truncating before start."
        : > "${LOG_FILE}"
    fi
fi

# ── Graceful shutdown ──────────────────────────────────────────────────────────
_shutdown() {
    echo "[entrypoint] Caught SIGTERM — shutting down..."
    if [[ -n "${DASHBOARD_PID:-}" ]]; then
        kill -TERM "${DASHBOARD_PID}" 2>/dev/null || true
    fi
    kill -TERM "${NODE_PID}" 2>/dev/null || true
    wait "${NODE_PID}" 2>/dev/null || true
    echo "[entrypoint] Node stopped."
    exit 0
}

# ── First-run initialisation ───────────────────────────────────────────────────
# The `init` command generates user_config.yaml with fresh keys in the cwd.
# It uses `-p` flags for bootstrap peer multiaddrs.
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[entrypoint] No config found — running first-time initialisation..."

    if [[ -z "${BOOTSTRAP_PEERS:-}" ]]; then
        echo "[entrypoint] WARNING: BOOTSTRAP_PEERS is not set. Node may not be able to join the network."
    fi

    # Build -p flags (one per peer)
    PEER_FLAGS=()
    for peer in ${BOOTSTRAP_PEERS:-}; do
        PEER_FLAGS+=(-p "${peer}")
    done

    logos-blockchain-node init \
        "${PEER_FLAGS[@]+"${PEER_FLAGS[@]}"}"

    # Patch api_port in generated config if non-default
    if [[ "${API_PORT}" != "8080" ]] && [[ -f "${CONFIG_FILE}" ]]; then
        sed -i "s/^api_port:.*/api_port: ${API_PORT}/" "${CONFIG_FILE}"
    fi

    echo "[entrypoint] Initialisation complete. Config written to ${CONFIG_FILE}."
    echo "[entrypoint] Node keys:"
    grep -A3 known_keys "${CONFIG_FILE}" || true
else
    echo "[entrypoint] Existing config found at ${CONFIG_FILE} — skipping init."
fi

# ── Start the dashboard ────────────────────────────────────────────────────────
DASHBOARD_PY="$(dirname "$(readlink -f "$0")")/dashboard.py"
# Fallback: look alongside the entrypoint in common locations
if [[ ! -f "${DASHBOARD_PY}" ]]; then
    DASHBOARD_PY="/app/dashboard.py"
fi

if [[ -f "${DASHBOARD_PY}" ]]; then
    export NODE_API_PORT="${API_PORT}"
    python3 "${DASHBOARD_PY}" &
    DASHBOARD_PID=$!
    echo "[entrypoint] Dashboard started (PID ${DASHBOARD_PID})."
else
    echo "[entrypoint] WARNING: dashboard.py not found — skipping dashboard."
    DASHBOARD_PID=""
fi

# ── Start the node ─────────────────────────────────────────────────────────────
echo "[entrypoint] Starting Logos Blockchain node..."
echo "[entrypoint]   Data dir : ${DATA_DIR}"
echo "[entrypoint]   Config   : ${CONFIG_FILE}"
echo "[entrypoint]   Circuits : ${LOGOS_BLOCKCHAIN_CIRCUITS}"
echo "[entrypoint]   Log file : ${LOG_FILE}"

# Pipe node stdout+stderr through tee so output appears in Railway logs AND
# is captured to a rotating file that the dashboard can tail.
logos-blockchain-node "${CONFIG_FILE}" 2>&1 | tee -a "${LOG_FILE}" &

# tee sits between the node and our wait; grab the node's PID via $!
# tee exits when its input closes (node exits), so we wait on the tee PID.
NODE_PID=$!
echo "[entrypoint] Node started (PID ${NODE_PID})."

trap '_shutdown' SIGTERM SIGINT

# Wait for the node/tee pipeline; propagate its exit code
wait "${NODE_PID}"
EXIT_CODE=$?
echo "[entrypoint] Node exited with code ${EXIT_CODE}."
exit "${EXIT_CODE}"
