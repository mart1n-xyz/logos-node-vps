#!/usr/bin/env python3
"""
Logos Blockchain Node — Web Dashboard
Serves on PORT (default 3001). Proxies to node on NODE_API_PORT (default 8080).
Optional basic auth via DASHBOARD_PASSWORD env var.
"""

import base64
import json
import os
import signal
import subprocess
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

UPDATER_HOST = os.environ.get("UPDATER_HOST", "host.docker.internal")
UPDATER_PORT = int(os.environ.get("UPDATER_PORT", "3002"))

DASHBOARD_PORT = int(os.environ.get("PORT", "3001"))
NODE_API_PORT  = int(os.environ.get("NODE_API_PORT", "8080"))
def _read_version():
    for path in ("/version.txt", "./version.txt"):
        try:
            return Path(path).read_text().strip()
        except OSError:
            pass
    return "unknown"
DATA_DIR    = os.environ.get("DATA_DIR", "/data")
LOG_FILE    = os.path.join(DATA_DIR, "node.log")
CONFIG_FILE = os.path.join(DATA_DIR, "user_config.yaml")
DASHBOARD_HTML = Path(__file__).with_name("dashboard.html")
ASSETS_DIR = Path(__file__).with_name("assets")


def node_get(path):
    """Fetch JSON from the local node API. Returns (data, error_str)."""
    url = f"http://127.0.0.1:{NODE_API_PORT}{path}"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return json.loads(resp.read()), None
    except Exception as exc:
        return None, str(exc)


def tail_log(n=500):
    """Return last n lines of node.log."""
    try:
        with open(LOG_FILE, "r", errors="replace") as f:
            lines = f.readlines()
        return [line.rstrip("\n") for line in lines[-n:]]
    except FileNotFoundError:
        return []
    except Exception as exc:
        return [f"Error reading log: {exc}"]


def read_keys():
    """Extract public keys from user_config.yaml with simple line parsing."""
    try:
        with open(CONFIG_FILE, "r") as f:
            content = f.read()
    except FileNotFoundError:
        return {"note": "Config not yet generated (node still initializing)"}
    except Exception as exc:
        return {"error": str(exc)}

    keys = {}
    in_keys = False
    for line in content.splitlines():
        if "known_keys" in line:
            in_keys = True
            continue
        if in_keys:
            stripped = line.strip()
            if not stripped:
                continue
            # A top-level (non-indented, non-list) key ends the section
            if stripped and not stripped.startswith("-") and not line.startswith(" "):
                in_keys = False
                continue
            if ":" in stripped:
                k, _, v = stripped.partition(":")
                k = k.strip().lstrip("-").strip()
                v = v.strip()
                if k and v:
                    keys[k] = v
    return keys if keys else {"note": "No keys found in config yet"}


def _env_path():
    """Return path to .env file — prefer script dir, fall back to /data/.env."""
    script_env = Path(__file__).with_name(".env")
    if script_env.exists():
        return script_env
    return Path("/data/.env")


def read_password():
    """Read DASHBOARD_PASSWORD from .env; fall back to environment variable."""
    try:
        content = _env_path().read_text()
        for line in content.splitlines():
            line = line.strip()
            if line.startswith("DASHBOARD_PASSWORD="):
                return line[len("DASHBOARD_PASSWORD="):].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return os.environ.get("DASHBOARD_PASSWORD", "")


def write_password(password):
    """Write DASHBOARD_PASSWORD to .env (update existing line or append)."""
    env_file = _env_path()
    new_line = f"DASHBOARD_PASSWORD={password}\n"
    try:
        content = env_file.read_text()
        lines = content.splitlines(keepends=True)
    except FileNotFoundError:
        lines = []
    for i, line in enumerate(lines):
        if line.startswith("DASHBOARD_PASSWORD="):
            lines[i] = new_line
            env_file.write_text("".join(lines))
            return
    lines.append(new_line)
    env_file.write_text("".join(lines))


def read_peers():
    """Return list of bootstrap peer multiaddrs from BOOTSTRAP_PEERS in .env."""
    try:
        content = _env_path().read_text()
    except FileNotFoundError:
        return []
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("BOOTSTRAP_PEERS="):
            value = line[len("BOOTSTRAP_PEERS="):].strip().strip('"').strip("'")
            return [p for p in value.split() if p]
    return []


def write_peers(peers):
    """Write updated BOOTSTRAP_PEERS list back to .env."""
    env_file = _env_path()
    value = " ".join(peers)
    try:
        content = env_file.read_text()
        lines = content.splitlines(keepends=True)
    except FileNotFoundError:
        lines = []
    new_line = f"BOOTSTRAP_PEERS={value}\n"
    found = False
    for i, line in enumerate(lines):
        if line.startswith("BOOTSTRAP_PEERS="):
            lines[i] = new_line
            found = True
            break
    if not found:
        lines.append(new_line)
    env_file.write_text("".join(lines))


def updater_get(path):
    """GET from the host updater service. Returns (data, error_str)."""
    url = f"http://{UPDATER_HOST}:{UPDATER_PORT}{path}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return json.loads(resp.read()), None
    except Exception as exc:
        return None, str(exc)


def updater_post(path):
    """POST to the host updater service (no body needed). Returns (data, error_str)."""
    url = f"http://{UPDATER_HOST}:{UPDATER_PORT}{path}"
    try:
        req = urllib.request.Request(url, data=b"{}", method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()), None
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read()), None
        except Exception:
            return None, f"HTTP {exc.code}"
    except Exception as exc:
        return None, str(exc)


def restart_node():
    """Send SIGTERM to the nomos node process. Returns (restarted, note)."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "nomos"],
            capture_output=True, text=True
        )
        pids = [int(p) for p in result.stdout.split() if p.strip().isdigit()]
        if not pids:
            return False, "process not found — peers saved but node not restarted"
        for pid in pids:
            os.kill(pid, signal.SIGTERM)
        return True, None
    except Exception as exc:
        return False, str(exc)


def check_auth(handler):
    """Return True if auth passes or no password is required."""
    current_password = read_password()
    if not current_password:
        return True
    auth_header = handler.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        _, _, password = decoded.partition(":")
        return password == current_password
    except Exception:
        return False


class DashboardHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # noqa: suppress default access log
        pass

    def _send_auth_challenge(self):
        body = json.dumps({"error": "Unauthorized"}).encode()
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Logos Node Dashboard"')
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_asset(self, filename):
        asset_path = ASSETS_DIR / filename
        try:
            content = asset_path.read_bytes()
        except FileNotFoundError:
            self.send_error(404)
            return
        ext = asset_path.suffix.lower()
        content_type = "image/png" if ext == ".png" else "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _send_html(self):
        try:
            content = DASHBOARD_HTML.read_bytes()
        except FileNotFoundError:
            self.send_error(404, "dashboard.html not found")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        path = self.path.split("?")[0]  # strip query string

        # Health endpoint — no auth required (used by Railway healthcheck)
        if path == "/health":
            self._send_json({"status": "ok"})
            return

        # Static assets — no auth required
        if path.startswith("/assets/"):
            self._send_asset(path[len("/assets/"):])
            return

        if not check_auth(self):
            self._send_auth_challenge()
            return

        if path in ("/", "/index.html"):
            self._send_html()

        elif path == "/api/status":
            info,  err1 = node_get("/cryptarchia/info")
            peers, err2 = node_get("/network/info")
            self._send_json({
                "cryptarchia": info,
                "network": peers,
                "errors": [e for e in [err1, err2] if e],
            })

        elif path == "/api/logs":
            lines = tail_log(500)
            self._send_json({"lines": lines, "count": len(lines)})

        elif path == "/api/keys":
            self._send_json(read_keys())

        elif path == "/api/peers":
            self._send_json({"peers": read_peers()})

        elif path == "/api/version":
            self._send_json({"version": _read_version()})

        elif path == "/api/auth-status":
            self._send_json({"enabled": bool(read_password())})

        elif path == "/api/update/status":
            data, err = updater_get("/update/status")
            if err:
                self._send_json({"error": err}, 502)
            else:
                self._send_json(data)

        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.split("?")[0]

        if not check_auth(self):
            self._send_auth_challenge()
            return

        if path == "/api/peers":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                peers = data.get("peers", [])
            except Exception:
                self._send_json({"error": "invalid JSON"}, 400)
                return
            write_peers(peers)
            restarted, note = restart_node()
            resp = {"ok": True, "restarted": restarted}
            if note:
                resp["note"] = note
            self._send_json(resp)

        elif path == "/api/set-password":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                password = data.get("password", "")
            except Exception:
                self._send_json({"error": "invalid JSON"}, 400)
                return
            write_password(password)
            self._send_json({"ok": True})

        elif path == "/api/update":
            data, err = updater_post("/update")
            if err:
                self._send_json({"ok": False, "error": err}, 502)
            else:
                self._send_json(data)

        else:
            self.send_error(404)


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", DASHBOARD_PORT), DashboardHandler)
    auth_status = "password-protected" if read_password() else "public (no password set)"
    print(f"[dashboard] Listening on :{DASHBOARD_PORT} — {auth_status}", flush=True)
    server.serve_forever()
