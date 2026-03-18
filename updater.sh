#!/usr/bin/env python3
"""
Logos Node Updater Service
Listens on 127.0.0.1:3002 (host-only) for update requests from the dashboard container.
On POST /update  : runs git pull && docker compose up -d --build in the background.
On GET  /update/status : returns JSON with current state.
Logs to /opt/logos-node/updater.log
"""

import json
import subprocess
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

INSTALL_DIR  = "/opt/logos-node"
LOG_FILE     = "/opt/logos-node/updater.log"
LISTEN_HOST  = "127.0.0.1"
LISTEN_PORT  = 3002

_state = {
    "in_progress": False,
    "last_run":    None,   # ISO-8601 timestamp
    "last_result": None,   # "ok" | "error"
    "last_output": None,   # truncated stdout+stderr
}
_lock = threading.Lock()


def _log(msg):
    ts   = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] {msg}\n"
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(line)
    except Exception:
        pass
    print(line, end="", flush=True)


def _run_update():
    _log("Update started: git pull && docker compose up -d --build")
    try:
        result = subprocess.run(
            ["bash", "-c",
             f"cd {INSTALL_DIR} && git pull && docker compose up -d --build"],
            capture_output=True, text=True, timeout=600,
        )
        output = (result.stdout + result.stderr).strip()
        ok     = result.returncode == 0
        _log(f"Update finished (rc={result.returncode}): {'ok' if ok else 'error'}")
        # keep last 4000 chars to avoid unbounded memory
        if len(output) > 4000:
            output = "…(truncated)…\n" + output[-4000:]
        with _lock:
            _state["last_run"]    = datetime.now(timezone.utc).isoformat()
            _state["last_result"] = "ok" if ok else "error"
            _state["last_output"] = output
            _state["in_progress"] = False
    except Exception as exc:
        _log(f"Update exception: {exc}")
        with _lock:
            _state["last_run"]    = datetime.now(timezone.utc).isoformat()
            _state["last_result"] = "error"
            _state["last_output"] = str(exc)
            _state["in_progress"] = False


class UpdaterHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # suppress default access log
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] == "/update/status":
            with _lock:
                snapshot = dict(_state)
            self._send_json(snapshot)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.split("?")[0] == "/update":
            with _lock:
                if _state["in_progress"]:
                    self._send_json(
                        {"ok": False, "message": "Update already in progress"}, 409
                    )
                    return
                _state["in_progress"] = True
            threading.Thread(target=_run_update, daemon=True).start()
            self._send_json({"ok": True, "message": "Update started"})
        else:
            self.send_error(404)


if __name__ == "__main__":
    _log(f"Updater listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), UpdaterHandler)
    server.serve_forever()
