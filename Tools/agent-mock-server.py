#!/usr/bin/env python3
"""Mock noop-agent backend for app development (handoff contract).

Pure stdlib: ThreadingHTTPServer for REST + a hand-rolled RFC6455 WebSocket endpoint at /ws.
Run:  python Tools/agent-mock-server.py [port]     (default 8080)

Pairing accepts ANY 6-digit code. Sending a chat message streams a canned reply over the
WebSocket (tool chip + deltas + done), which exercises the app's full streaming path.
"""

import base64
import hashlib
import json
import struct
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "mock-token-123"
DEVICE_ID = "mock-device-0001"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

ws_clients = []          # list of raw sockets holding open WS connections
ws_lock = threading.Lock()
messages = []            # chat history, oldest first


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def seed_messages():
    messages.append({
        "id": str(uuid.uuid4()), "role": "assistant", "channel": "chat",
        "createdAt": now_iso(),
        "text": "Mock server is running. Pair with any 6-digit code, then send me a message "
                "and watch the reply stream in.", "tools": [],
    })


# ---------------------------------------------------------------- WebSocket


def ws_send(sock, obj):
    """Send one text frame (server->client frames are unmasked)."""
    payload = json.dumps(obj).encode()
    header = bytearray([0x81])  # FIN + text opcode
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    with ws_lock:
        try:
            sock.sendall(bytes(header) + payload)
        except OSError:
            pass


def ws_broadcast(obj):
    with ws_lock:
        clients = list(ws_clients)
    for c in clients:
        ws_send(c, obj)


def ws_read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def ws_serve(sock):
    """Read frames until close; replies to ping, exits on close. Clients send masked frames."""
    with ws_lock:
        ws_clients.append(sock)
    try:
        while True:
            b1, b2 = ws_read_exact(sock, 2)
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", ws_read_exact(sock, 2))[0]
            elif length == 127:
                length = struct.unpack(">Q", ws_read_exact(sock, 8))[0]
            mask = ws_read_exact(sock, 4) if masked else b"\x00" * 4
            payload = bytearray(ws_read_exact(sock, length))
            for i in range(length):
                payload[i] ^= mask[i % 4]
            if opcode == 8:      # close
                break
            if opcode == 9:      # ping -> pong
                header = bytearray([0x8A])
                header.append(len(payload))
                sock.sendall(bytes(header) + bytes(payload))
    except (ConnectionError, OSError):
        pass
    finally:
        with ws_lock:
            if sock in ws_clients:
                ws_clients.remove(sock)
        try:
            sock.close()
        except OSError:
            pass


def stream_reply(user_text):
    """The canned assistant reply, streamed like the real agent does."""
    msg_id = str(uuid.uuid4())
    time.sleep(0.4)
    ws_broadcast({"type": "tool.started",
                  "data": {"messageId": msg_id, "name": "mock_tool",
                           "label": "Checked mock server"}})
    time.sleep(0.6)
    reply = (f"You said: “{user_text}”. This reply is streaming from the mock backend in "
             f"chunks, exactly like the real agent will — tool chip first, then text deltas, "
             f"then a final message.")
    for word in reply.split(" "):
        ws_broadcast({"type": "message.delta",
                      "data": {"messageId": msg_id, "text": word + " "}})
        time.sleep(0.05)
    ws_broadcast({"type": "tool.finished",
                  "data": {"messageId": msg_id, "name": "mock_tool",
                           "label": "Checked mock server"}})
    msg = {"id": msg_id, "role": "assistant", "channel": "chat", "createdAt": now_iso(),
           "text": reply.strip(),
           "tools": [{"name": "mock_tool", "label": "Checked mock server"}]}
    messages.append(msg)
    ws_broadcast({"type": "message.done", "data": msg})


# ---------------------------------------------------------------- HTTP


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _authorized(self):
        if self.headers.get("Authorization") == f"Bearer {TOKEN}":
            return True
        self._json({"error": "unauthorized"}, status=401)
        return False

    def _path(self):
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    # -- WebSocket upgrade

    def _websocket(self):
        if "token=" not in self.path:
            self._json({"error": "token required"}, status=401)
            return
        key = self.headers.get("Sec-WebSocket-Key")
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        # Hand the raw socket to the WS loop; it owns the connection from here on.
        self.close_connection = True
        ws_serve(self.connection)

    # -- routes

    def do_GET(self):
        p = self._path()
        if p == "/ws":
            self._websocket()
            return
        if p == "/health":
            self._json({"ok": True, "version": "0.1.0-mock"})
            return
        if not self._authorized():
            return
        if p == "/conversations/default/messages":
            self._json({"messages": messages, "nextBefore": None})
        elif p == "/today":
            self._json({"brief": None, "health": None, "nutrition": {"kcalIn": 0},
                        "due": [], "events": [], "weather": None})
        elif p == "/tasks":
            self._json({"tasks": []})
        elif p == "/inbox":
            self._json({"action": [], "fyi": [], "ignored": []})
        elif p == "/approvals":
            self._json({"approvals": []})
        elif p == "/settings":
            self._json({"quietHours": {"start": "23:30", "end": "07:00"},
                        "levels": {"school": "sound", "email": "silent", "health": "call",
                                   "markets": "brief", "reminders": "sound"},
                        "watchlist": [], "icalUrl": ""})
        elif p == "/integrations":
            self._json({"integrations": []})
        elif p == "/activity":
            self._json({"runs": [], "nextBefore": None})
        elif p == "/memories":
            self._json([])
        else:
            self._json({"error": f"no mock route for GET {p}"}, status=404)

    def do_POST(self):
        p = self._path()
        if p == "/auth/pair":
            body = self._body()
            code = str(body.get("code", ""))
            if len(code) == 6 and code.isdigit():
                self._json({"deviceId": DEVICE_ID, "token": TOKEN})
            else:
                self._json({"error": "invalid code"}, status=403)
            return
        if not self._authorized():
            return
        if p == "/conversations/default/messages":
            body = self._body()
            text = str(body.get("text", ""))
            messages.append({"id": str(uuid.uuid4()), "role": "user", "channel": "chat",
                             "createdAt": now_iso(), "text": text, "tools": []})
            msg_id = str(uuid.uuid4())
            self._json({"messageId": msg_id})
            threading.Thread(target=stream_reply, args=(text,), daemon=True).start()
        elif p == "/devices":
            self._json({"ok": True})
        else:
            self._json({"error": f"no mock route for POST {p}"}, status=404)

    def do_PATCH(self):
        self._json({"error": f"no mock route for PATCH {self._path()}"}, status=404)

    def do_PUT(self):
        self._json({"error": f"no mock route for PUT {self._path()}"}, status=404)

    def do_DELETE(self):
        self._json({"error": f"no mock route for DELETE {self._path()}"}, status=404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    seed_messages()
    print(f"mock noop-agent on http://127.0.0.1:{port}  (any 6-digit code pairs)")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
