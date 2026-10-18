#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BetterDisplay local licence server (plain HTTP on 127.0.0.1:8543).

The patched Paddle.framework sends its licence calls here.  We answer with
the Paddle v3.2 JSON envelope, signed with HMAC-SHA256 using the API key
that BetterDisplay itself embeds.  No TLS, no certificate, no internet.

Endpoints (matched by suffix):
    POST /.../license/activate
    POST /.../license/verify
    POST /.../license/activations
    POST /.../license/deactivate
    POST /.../product/data
    GET  /status

Every request + response is appended to bd_keygen_server.log.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")


def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as exc:
        log("config error: %r" % (exc,))
        return {}


def log(line):
    stamp = time.strftime("%H:%M:%S")
    print("[%s] %s" % (stamp, line), flush=True)


def compact_json(value):
    """Same shape as NSJSONSerialization + NSJSONWritingSortedKeys."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def signed_envelope(response, cfg):
    api_key = str(cfg.get("api_key", "")).encode("utf-8")
    raw = compact_json(response)
    signature = base64.b64encode(
        hmac.new(api_key, raw, hashlib.sha256).digest()).decode("ascii")
    return {
        "success": True,
        "response": response,
        "signature": signature,
    }


def activation_object(cfg):
    return {
        "product_id": str(cfg.get("product_id", "762421")),
        "activation_id": str(cfg.get("activation_id", "123456")),
        "type": str(cfg.get("license_type", "activation_license")),
        "expires": False,
    }


def activation_list(cfg, license_key):
    return [{
        "activation_id": str(cfg.get("activation_id", "123456")),
        "activation_date": time.strftime("%Y-%m-%d %H:%M:%S"),
        "activation_email": str(cfg.get("activation_email", "panda@example.com")),
        "license_key": license_key or "BETTER-DISPLAY-KEYGEN-0001",
        "product_id": str(cfg.get("product_id", "762421")),
        "type": str(cfg.get("license_type", "activation_license")),
    }]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # we have our own log

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length", "0") or 0)
            return self.rfile.read(n) if n else b""
        except Exception:
            return b""

    def _send(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        cfg = load_config()
        parsed = urlparse(self.path)
        raw = self._read_body() if self.command == "POST" else b""
        form = {}
        try:
            form = {k: v[-1] for k, v in parse_qs(
                raw.decode("utf-8", "replace"), keep_blank_values=True).items()}
        except Exception:
            pass

        log("%s %s body=%s" % (self.command, parsed.path,
                               raw.decode("utf-8", "replace")[:500]))

        if parsed.path == "/status":
            self._send({"status": "ok", "server": "bdkeygen",
                        "port": int(cfg.get("port", 8543))})
            return

        response = {}
        if parsed.path.endswith("license/activate"):
            response = activation_object(cfg)
        elif parsed.path.endswith("license/verify"):
            response = activation_object(cfg)
        elif parsed.path.endswith("license/activations"):
            response = activation_list(cfg, form.get("license_key"))
        elif parsed.path.endswith("license/deactivate"):
            response = {}
        elif parsed.path.endswith("product/data"):
            # The SDK can fall back to the product configuration.  A minimal
            # successful envelope is enough and avoids network retries.
            response = {}
        else:
            response = {}

        envelope = signed_envelope(response, cfg)
        log("  -> %s" % json.dumps(envelope, ensure_ascii=False)[:600])
        self._send(envelope)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_DELETE(self):
        self._handle()


def main():
    cfg = load_config()
    port = int(os.environ.get("BDKEYGEN_PORT", cfg.get("port", 8543)))
    log("=== bdkeygen server starting on 127.0.0.1:%d ===" % port)
    ThreadingHTTPServer.allow_reuse_address = True
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log("ready. config: %s" % CONFIG_PATH)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("stopped.")


if __name__ == "__main__":
    main()
