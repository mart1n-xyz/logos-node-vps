#!/usr/bin/env python3
"""
Logos Blockchain Node — Web Dashboard
Serves on PORT (default 3001). Proxies to node on NODE_API_PORT (default 8080).
Optional basic auth via DASHBOARD_PASSWORD env var.
"""

import base64
import json
import os
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

DASHBOARD_PORT = int(os.environ.get("PORT", "3001"))
NODE_API_PORT  = int(os.environ.get("NODE_API_PORT", "8080"))
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "")
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


def check_auth(handler):
    """Return True if auth passes or no password is required."""
    if not DASHBOARD_PASSWORD:
        return True
    auth_header = handler.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        _, _, password = decoded.partition(":")
        return password == DASHBOARD_PASSWORD
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

        else:
            self.send_error(404)


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", DASHBOARD_PORT), DashboardHandler)
    auth_status = "password-protected" if DASHBOARD_PASSWORD else "public (no password set)"
    print(f"[dashboard] Listening on :{DASHBOARD_PORT} — {auth_status}", flush=True)
    server.serve_forever()
