# Logos Blockchain Node — VPS Deploy

Run a [Logos Blockchain](https://github.com/logos-co/nomos-node) devnet node on any Ubuntu 24.04 VPS (Hetzner, Netcup, DigitalOcean, etc.) using Docker Compose.

---

## Quick start — one SSH command

```bash
curl -fsSL https://raw.githubusercontent.com/mart1n-xyz/logos-node-vps/main/setup.sh | sudo bash
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

```bash
ufw allow 3000/udp   # p2p (UDP/QUIC)
ufw allow 3001/tcp   # web dashboard
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
| `DASHBOARD_PASSWORD` | *(empty)* | If set, enables HTTP basic auth (username: `admin`) |
| `DOMAIN` | *(empty)* | Your domain name — only needed for the optional Caddy HTTPS setup |

All variables live in `.env` (created from `.env.example` during setup).

---

## Web dashboard

Once the node is running, open `http://<your-server-ip>:3001` in a browser:

- **Node Status** — mode, current slot, block height, chain tip hash
- **Network / Peers** — connected peer count and connection count
- **Wallet Keys** — your node's public keys (for the faucet)
- **Node Logs** — last 500 lines, auto-scrolling, color-coded for errors and warnings
- **Auto-refresh** every 10 seconds

### Dashboard API endpoints

| Endpoint | Description |
|---|---|
| `GET /` | HTML dashboard |
| `GET /api/status` | JSON: cryptarchia/info + network/info |
| `GET /api/logs` | Last 500 log lines as JSON |
| `GET /api/keys` | Node public keys from `user_config.yaml` |

### Password protection

Set `DASHBOARD_PASSWORD` in `.env` to enable HTTP basic auth:

- Username: `admin`
- Password: whatever you set

Leave it empty for public access (fine for a devnet node).

---

## Auto-deploy (personal fork)

Push to `main` → GitHub Actions SSHes into your VPS and redeploys automatically.

1. **Fork** this repo on GitHub.
2. In your fork, go to **Settings → Secrets and variables → Actions** and add three repository secrets:
   - `VPS_HOST` — your server's IP address or hostname
   - `VPS_USER` — SSH username (e.g. `root` or `ubuntu`)
   - `SSH_PRIVATE_KEY` — contents of your private key (e.g. `~/.ssh/id_ed25519`)
3. Make sure `/opt/logos-node` on your VPS is a clone of your fork (the `setup.sh` script does this automatically).
4. Push any commit to `main` — the workflow in `.github/workflows/deploy.yml` will SSH in and run:
   ```
   git pull
   GIT_SHA=$(git rev-parse HEAD) docker compose up -d --build
   ```

The dashboard's **Overview** tab shows the current deployed commit SHA. If your fork falls behind the upstream repo, the dashboard displays an amber "Update available" notice with the current and latest SHAs.

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

Visit the Logos faucet (link in the [official docs](https://github.com/logos-co/nomos-node)) and paste your node's public key. You can find your public key in the **Wallet Keys** card on the dashboard, or in `/var/lib/docker/volumes/logos-node-vps_logos-data/_data/user_config.yaml` on the host.

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
├── setup.sh            # One-shot installer for Ubuntu 24.04
└── assets/
    └── logo.png
```

---

## Tested on

- Ubuntu 24.04 LTS — Hetzner CX22
- Ubuntu 24.04 LTS — Netcup VPS 1000

Minimum recommended specs: **2 vCPU / 4 GB RAM / 40 GB SSD**

---

## License

MIT
