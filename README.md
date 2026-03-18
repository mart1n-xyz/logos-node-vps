# Logos Blockchain Node — VPS Deploy

Run a [Logos Blockchain](https://github.com/logos-co/nomos-node) devnet node on any Ubuntu 24.04 or Debian VPS (Hetzner, Netcup, DigitalOcean, etc.) using Docker Compose.

---

## Quick start — one SSH command

```bash
curl -fsSL https://raw.githubusercontent.com/mart1n-xyz/logos-node-vps/master/setup.sh | sudo bash
```

This will:
1. Install Docker (if missing)
2. Clone this repo to `/opt/logos-node`
3. Copy `.env.example` → `.env`
4. Build the image and start the node
5. Print your dashboard URL

> **After the script finishes**, open `http://<your-server-ip>:3001` to see the dashboard.

---

## Manual setup

```bash
# 1. Clone the repo
git clone https://github.com/mart1n-xyz/logos-node-vps.git /opt/logos-node
cd /opt/logos-node

# 2. Create your env file
cp .env.example .env
# Edit .env if needed (DASHBOARD_PASSWORD, etc.)

# 3. Build and start
docker compose up -d --build

# 4. Check logs
docker compose logs -f
```

### Firewall

Open the required ports before starting:

**Ubuntu (ufw):**
```bash
ufw allow 3000/udp   # p2p (UDP/QUIC)
ufw allow 3001/tcp   # web dashboard
```

**Debian (iptables — no ufw by default):**
```bash
iptables -A INPUT -p udp --dport 3000 -j ACCEPT   # p2p (UDP/QUIC)
iptables -A INPUT -p tcp --dport 3001 -j ACCEPT   # web dashboard
iptables -A INPUT -p tcp --dport 3002 -i eth0 -j DROP  # block updater externally (see below)
```

Port 8080 (node HTTP API) is **internal only** and should not be exposed.

---

## docker-compose usage

```bash
# Start (detached)
docker compose up -d --build

# View logs
docker compose logs -f

# Stop
docker compose down

# Restart
docker compose restart logos-node

# Rebuild after updating NODE_VERSION / CIRCUITS_VERSION
docker compose up -d --build
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `BOOTSTRAP_PEERS` | *(v0.2.1 peers — see below)* | Space-separated multiaddrs to join the network |
| `API_PORT` | `8080` | Node internal HTTP API port (do not expose publicly) |
| `NODE_API_PORT` | `8080` | Same as `API_PORT` — used by `dashboard.py` |
| `DATA_DIR` | `/data` | Container path for config and chain state |
| `PORT` | `3001` | Web dashboard port |
| `DASHBOARD_PASSWORD` | *(empty)* | If set, enables HTTP basic auth (username: `admin`). Can also be set from the dashboard Settings tab without SSH. |
| `DOMAIN` | *(empty)* | Your domain name — only needed for the optional Caddy HTTPS setup |

All variables live in `.env` (created from `.env.example` during setup).

---

## Web dashboard

Once the node is running, open `http://<your-server-ip>:3001` in a browser:

- **Node Status** — mode, current slot, block height, chain tip hash
- **Network / Peers** — connected peer count and connection count
- **Wallet Keys** — your node's public keys (for the faucet)
- **Node Logs** — last 500 lines, auto-scrolling, color-coded for errors and warnings
- **Settings** — manage bootstrap peers, password protection, and software updates without SSH
- **Auto-refresh** every 10 seconds

### Dashboard Settings

The **Settings** tab lets you manage node configuration from the browser:

- **Bootstrap peers editor** — edit the peer multiaddrs directly in the UI, save, and restart the node without SSH
- **Password protection** — enable or disable dashboard HTTP basic auth from the browser (no SSH or `.env` editing needed)
- **Software Update** — shows your current version vs. the latest release and lets you update with one click

### Dashboard API endpoints

| Endpoint | Description |
|---|---|
| `GET /` | HTML dashboard |
| `GET /api/status` | JSON: cryptarchia/info + network/info |
| `GET /api/logs` | Last 500 log lines as JSON |
| `GET /api/keys` | Node public keys from `user_config.yaml` |

### Password protection

Enable HTTP basic auth by either:
- Setting `DASHBOARD_PASSWORD` in `.env`, or
- Using the **Settings** tab in the dashboard (no SSH needed)

Username is always `admin`. Leave it empty for public access (fine for a devnet node).

---

## Updating

The easiest way to update is from the **Settings** tab in the dashboard — the **Software Update** card shows your current version alongside the latest release and lets you trigger an update with one click.

If you prefer to update manually over SSH:

```bash
cd /opt/logos-node && git pull && docker compose up -d --build
```

---

## Optional: HTTPS with Caddy

The `docker-compose.yml` includes a commented-out Caddy service that adds automatic HTTPS via Let's Encrypt.

1. Point a DNS A record at your server IP (e.g., `node.example.com → 1.2.3.4`).
2. Add your domain to `.env`:
   ```
   DOMAIN=node.example.com
   ```
3. Open ports 80 and 443 on your firewall:
   ```bash
   ufw allow 80/tcp && ufw allow 443/tcp
   ```
4. Uncomment the `caddy` service and the `caddy-data`/`caddy-config` volumes in `docker-compose.yml`.
5. Restart:
   ```bash
   docker compose up -d
   ```

Caddy will obtain and auto-renew your TLS certificate. Dashboard will be available at `https://node.example.com`.

---

## Bootstrap peers

Default peers for **v0.2.1**:

```
/ip4/65.109.51.37/udp/3000/quic-v1/p2p/12D3KooWL7a8LBbLRYnabptHPFBCmAs49Y7cVMqvzuSdd43tAJk8
/ip4/65.109.51.37/udp/3001/quic-v1/p2p/12D3KooWPLeAcachoUm68NXGD7tmNziZkVeMmeBS5NofyukuMRJh
/ip4/65.109.51.37/udp/3002/quic-v1/p2p/12D3KooWKFNe4gS5DcCcRUVGdMjZp3fUWu6q6gG5R846Ui1pccHD
/ip4/65.109.51.37/udp/3003/quic-v1/p2p/12D3KooWAnriLgXyQnGTYz1zPWPkQL3rthTKYLzuAP7MMnbgsxzR
```

These are pre-filled in `.env.example`. Update `BOOTSTRAP_PEERS` in `.env` when a new release is published.

---

## Getting devnet tokens

1. Copy one of your public keys from the **Wallet Keys** card in the dashboard.
2. Visit the faucet at **https://devnet.blockchain.logos.co/web/faucet/**
3. You'll need credentials from the Logos team — request them in the [Logos Discord](https://discord.com/channels/973324189794697286/1468535289604735038).
4. Paste your key and request funds.
5. Once your node is synced, the balance will appear next to the key in the **Wallet Keys** card.

---

## Updating to a new release

1. Update `BOOTSTRAP_PEERS` in `.env` with the peers from the new release notes.
2. Edit `docker-compose.yml` and bump `NODE_VERSION` (and `CIRCUITS_VERSION` if circuits were re-released):
   ```yaml
   args:
     NODE_VERSION: "0.2.2"
     CIRCUITS_VERSION: "0.4.1"
   ```
3. Rebuild and restart:
   ```bash
   cd /opt/logos-node
   git pull
   docker compose up -d --build
   ```

Chain state in the `logos-data` volume is preserved across rebuilds.

> **Tip**: If `CIRCUITS_VERSION` differs from `NODE_VERSION` in a release, set them independently in `docker-compose.yml` under `build.args`.

---

## Self-update service

The `logos-node-updater` is a lightweight systemd service installed automatically by `setup.sh`. It listens on `0.0.0.0:3002` — required so the Docker container can reach it via the host gateway. Port 3002 is **not** in Docker's `ports:` mapping, so it is not publicly exposed through Docker.

However, on Debian (no ufw by default), you should block it at the network level:

```bash
iptables -A INPUT -p tcp --dport 3002 -i eth0 -j DROP
```

On Ubuntu with ufw active, port 3002 is blocked by default unless you explicitly open it.

The dashboard proxies update requests to it, so the browser-based update button works without any additional configuration.

Useful commands:

```bash
systemctl status logos-node-updater   # Check service health
journalctl -u logos-node-updater -f   # Follow logs
```

---

## Repository structure

```
.
├── Dockerfile          # Multi-stage build: downloads binary + circuits from GitHub Releases
├── entrypoint.sh       # First-run init, log capture, graceful shutdown
├── dashboard.py        # Python stdlib HTTP server (status, logs, keys, optional auth)
├── dashboard.html      # Dark-themed single-page dashboard with auto-refresh
├── docker-compose.yml  # Service definition with named volume and optional Caddy
├── Caddyfile           # Caddy reverse proxy config for automatic HTTPS
├── .env.example        # All environment variables with defaults and comments
├── setup.sh            # One-shot installer for Ubuntu 24.04 / Debian
├── updater.sh          # Self-update script run by the updater service (git pull + rebuild)
├── logos-node-updater.service  # systemd unit for the updater service
├── version.txt         # Current release version, shown in the dashboard Overview tab
└── assets/
    └── logo.png
```

---

## Tested on

- Ubuntu 24.04 LTS — Hetzner CX22
- Ubuntu 24.04 LTS — Netcup VPS 1000
- Debian Trixie (13) — Hetzner CX22

Minimum recommended specs: **2 vCPU / 4 GB RAM / 40 GB SSD**

---

## License

MIT
