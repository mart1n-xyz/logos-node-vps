#!/usr/bin/env bash
# entrypoint.sh — Logos Blockchain node startup script for Railway
#
# First run:  generates keys + user_config.yaml via `init`, then starts node.
# Later runs: keeps existing keys but re-applies BOOTSTRAP_PEERS / API_PORT
#             to user_config.yaml so .env changes propagate without manual edits.
#
# Environment variables (all optional — see railway.toml for defaults):
#   BOOTSTRAP_PEERS     Space-separated multiaddrs for the testnet bootstrap peers.
#   API_PORT            TCP port for the node's HTTP API (default: 8080).
#   DATA_DIR            Directory for config + chain state (default: /data).
#   DASHBOARD_PASSWORD  If set, enables basic auth on the web dashboard.
#   NODE_API_PORT       Same as API_PORT — used by dashboard.py (default: 8080).
#   STATE_RESET         If "1", wipe chain state (state/ + node.log + timestamped
#                       snapshot dirs) before start. user_config.yaml is preserved.
#                       Useful after node upgrades that change the on-disk format.

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

# ── Optional state reset ───────────────────────────────────────────────────────
# When STATE_RESET=1, wipe chain DB + node log + timestamped recovery snapshots
# but keep user_config.yaml (so wallet keys / node_key survive).
if [[ "${STATE_RESET:-0}" == "1" ]]; then
    echo "[entrypoint] STATE_RESET=1 — wiping chain state. Keys in user_config.yaml are preserved."
    rm -rf "${DATA_DIR}/state" "${LOG_FILE}"
    # Date-stamped snapshot dirs ("<unix-ts>.YYYY-MM-DD-HH") can accumulate to
    # tens of GB; clean them too.
    find "${DATA_DIR}" -maxdepth 1 -type d -regex '.*/[0-9]+\.[0-9-]+' -print -exec rm -rf {} + || true
fi

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

    echo "[entrypoint] Initialisation complete. Config written to ${CONFIG_FILE}."
    echo "[entrypoint] Node keys:"
    grep -A3 known_keys "${CONFIG_FILE}" || true
else
    echo "[entrypoint] Existing config found at ${CONFIG_FILE} — keeping keys, re-applying settings from environment."
fi

# ── Re-apply env-driven settings to user_config.yaml ───────────────────────────
# Runs on every start so changes to BOOTSTRAP_PEERS / API_PORT in .env take effect
# without requiring a manual reinit. user_config.yaml ships keys + plenty of other
# tuning knobs; we only touch the two fields that the operator owns via env.
patch_config() {
    python3 - "$CONFIG_FILE" <<'PYEOF'
import os
import re
import sys

path = sys.argv[1]
with open(path) as f:
    txt = f.read()

original = txt
changes = []

bootstrap_peers = os.environ.get("BOOTSTRAP_PEERS", "").split()
if bootstrap_peers:
    # network.backend.initial_peers — list under 4-space indent
    initial_peers_block = "".join(f"    - {p}\n" for p in bootstrap_peers)
    pattern = re.compile(r"(    initial_peers:\n)((?:    - .+\n)*)")
    m = pattern.search(txt)
    if m:
        new = txt[:m.start()] + m.group(1) + initial_peers_block + txt[m.end():]
        if new != txt:
            txt = new
            changes.append(f"initial_peers ({len(bootstrap_peers)} peers)")
    else:
        print("[patch_config] WARN: initial_peers block not found")

    # cryptarchia.network.bootstrap.ibd.peers — list of bare peer IDs, 8-space indent
    ibd_peers = []
    for ma in bootstrap_peers:
        # extract /p2p/<peer_id>
        m2 = re.search(r"/p2p/(\S+)$", ma)
        if m2:
            ibd_peers.append(m2.group(1))
    if ibd_peers:
        ibd_block = "".join(f"        - {p}\n" for p in ibd_peers)
        pattern2 = re.compile(r"(        peers:\n)((?:        - \S+\n)+)")
        m3 = pattern2.search(txt)
        if m3:
            new = txt[:m3.start()] + m3.group(1) + ibd_block + txt[m3.end():]
            if new != txt:
                txt = new
                changes.append(f"ibd.peers ({len(ibd_peers)} peers)")
        else:
            print("[patch_config] WARN: cryptarchia ibd peers block not found")

api_port = os.environ.get("API_PORT", "").strip()
if api_port:
    # Top-level api.backend.listen_address: 0.0.0.0:<port>
    pattern3 = re.compile(r"(listen_address: 0\.0\.0\.0:)\d+")
    new = pattern3.sub(rf"\g<1>{api_port}", txt)
    if new != txt:
        txt = new
        changes.append(f"api listen_address (:{api_port})")

if txt != original:
    with open(path, "w") as f:
        f.write(txt)
    print("[patch_config] Updated:", ", ".join(changes))
else:
    print("[patch_config] No changes needed.")
PYEOF
}

patch_config || echo "[entrypoint] WARN: patch_config failed — continuing with existing config."

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
