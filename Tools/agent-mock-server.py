#!/usr/bin/env python3
"""Mock noop-agent backend for app development (handoff contract).

Pure stdlib: ThreadingHTTPServer for REST + a hand-rolled RFC6455 WebSocket endpoint at /ws.
Run:  python Tools/agent-mock-server.py [port]     (default 8080)

Pairing accepts ANY 6-digit code. Sending a chat message streams a canned reply over the
WebSocket (tool chip + deltas + done), which exercises the app's full streaming path.

Step-2 surfaces are seeded: /today (brief, health, due, events, weather), /tasks, /inbox,
/approvals, /settings, /integrations, /memories. Mutations (complete a task, re-file a mail,
decide an approval, edit settings/memories) broadcast the matching socket event so the app's
live-update paths get exercised too.
"""

import base64
import hashlib
import json
import struct
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "mock-token-123"
DEVICE_ID = "mock-device-0001"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

ws_clients = []          # list of raw sockets holding open WS connections
ws_lock = threading.Lock()
messages = []            # chat history, oldest first
tasks = []
inbox_items = []
approvals = []
memories = []
integrations = []
settings = {}
state_lock = threading.Lock()


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def iso_in(**delta):
    return (datetime.now(timezone.utc) + timedelta(**delta)).isoformat().replace("+00:00", "Z")


def seed_state():
    messages.append({
        "id": str(uuid.uuid4()), "role": "assistant", "channel": "chat",
        "createdAt": now_iso(),
        "text": "Mock server is running. Pair with any 6-digit code, then send me a message "
                "and watch the reply stream in.", "tools": [],
    })
    tasks.extend([
        {"id": str(uuid.uuid4()), "title": "Submit problem set 4", "source": "brightspace",
         "dueAt": iso_in(hours=5), "priority": "high", "status": "open"},
        {"id": str(uuid.uuid4()), "title": "Book dentist appointment", "source": "manual",
         "dueAt": iso_in(days=2), "priority": "normal", "status": "open"},
        {"id": str(uuid.uuid4()), "title": "Read chapter 9 for econ", "source": "agent",
         "dueAt": iso_in(days=-1), "priority": "normal", "status": "open"},
        {"id": str(uuid.uuid4()), "title": "Renew gym membership", "source": "email",
         "dueAt": iso_in(days=9), "priority": "low", "status": "open"},
    ])
    inbox_items.extend([
        {"id": str(uuid.uuid4()), "from": "Prof. Alvarez", "subject": "Extension granted",
         "summary": "Your extension request for problem set 4 was approved — new deadline is "
                    "tonight. I've already created a task for it.",
         "receivedAt": iso_in(hours=-2), "category": "action"},
        {"id": str(uuid.uuid4()), "from": "WHOOP", "subject": "Your weekly performance report",
         "summary": "Recovery averaged 68% this week, up 6 points. Sleep consistency is your "
                    "biggest lever right now.",
         "receivedAt": iso_in(hours=-6), "category": "fyi"},
        {"id": str(uuid.uuid4()), "from": "Amazon", "subject": "Your order has shipped",
         "summary": "Package arriving Thursday.",
         "receivedAt": iso_in(hours=-9), "category": "ignore"},
    ])
    approvals.append({
        "id": str(uuid.uuid4()), "action": "send_email",
        "summary": "Reply to Prof. Alvarez confirming you'll submit tonight.",
        "reason": "She granted the extension and a quick confirmation keeps the thread clean.",
        "payload": "Thanks professor — I'll have problem set 4 in by tonight.",
        "status": "pending", "createdAt": iso_in(hours=-1),
    })
    memories.extend([
        {"id": str(uuid.uuid4()), "text": "Prefers a 350 kcal daily deficit on weekdays.",
         "source": "manual", "pinned": True},
        {"id": str(uuid.uuid4()), "text": "Gym sessions are usually 18:00–19:30.",
         "source": "agent", "pinned": False},
    ])
    integrations.extend([
        {"provider": "whoop", "status": "ok", "lastSyncAt": iso_in(minutes=-12)},
        {"provider": "gmail", "status": "ok", "lastSyncAt": iso_in(minutes=-40)},
        {"provider": "brightspace", "status": "needs_auth",
         "connectUrl": "https://example.com/connect/brightspace"},
        {"provider": "google_calendar", "status": "failing",
         "lastSyncAt": iso_in(days=-2)},
    ])
    settings.update({
        "quietHours": {"start": "23:30", "end": "07:00"},
        "levels": {"school": "sound", "email": "silent", "health": "call",
                   "markets": "brief", "reminders": "sound"},
        "watchlist": [{"symbol": "AAPL", "movePct": 3.0}, {"symbol": "NVDA", "movePct": 5.0}],
        "icalUrl": "",
    })


def today_payload():
    return {
        "brief": {
            "script": "Morning. Recovery is 72% after 7.4 h of sleep — a green day. "
                      "Problem set 4 is due tonight; the extension is confirmed. "
                      "Best run window is 16:00–18:00 before the rain.",
            "audioUrl": None,
            "createdAt": now_iso(),
        },
        "health": {"recovery": 72, "hrvMs": 88, "rhr": 54, "sleepHours": 7.4,
                   "sleepPerformance": 91, "strain": 8.2, "kcalBurned": 1450},
        "nutrition": {"kcalIn": 980},
        "due": [
            {"id": str(uuid.uuid4()), "course": "ECON 201", "title": "Problem set 4",
             "dueAt": iso_in(hours=5), "type": "assignment"},
            {"id": str(uuid.uuid4()), "course": "BIO 210", "title": "Lab report draft",
             "dueAt": iso_in(days=1, hours=2), "type": "assignment"},
        ],
        "events": [
            {"id": str(uuid.uuid4()), "title": "Linear algebra lecture",
             "startAt": iso_in(hours=2), "endAt": iso_in(hours=3), "location": "Room 204"},
            {"id": str(uuid.uuid4()), "title": "Gym", "startAt": iso_in(hours=9),
             "endAt": iso_in(hours=10, minutes=30), "location": None},
        ],
        "weather": {"summary": "Cloudy, rain after 19:00", "tempC": 14,
                    "bestRunWindow": "16:00–18:00"},
    }


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
            self._json({"ok": True, "version": "0.2.0-mock"})
            return
        if not self._authorized():
            return
        if p == "/conversations/default/messages":
            self._json({"messages": messages, "nextBefore": None})
        elif p == "/today":
            self._json(today_payload())
        elif p == "/tasks":
            with state_lock:
                self._json({"tasks": list(tasks)})
        elif p == "/inbox":
            with state_lock:
                self._json({"items": list(inbox_items)})
        elif p == "/approvals":
            with state_lock:
                pending = [a for a in approvals if a.get("status") == "pending"]
            self._json({"approvals": pending})
        elif p == "/settings":
            with state_lock:
                self._json(dict(settings))
        elif p == "/integrations":
            with state_lock:
                self._json({"integrations": list(integrations)})
        elif p == "/activity":
            self._json({"runs": [], "nextBefore": None})
        elif p == "/memories":
            with state_lock:
                self._json({"memories": list(memories)})
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
        elif p == "/tasks":
            body = self._body()
            task = {"id": str(uuid.uuid4()), "title": str(body.get("title", "")),
                    "source": "manual", "dueAt": body.get("dueAt"),
                    "priority": body.get("priority") or "normal", "status": "open"}
            with state_lock:
                tasks.append(task)
            self._json(task, status=201)
            ws_broadcast({"type": "task.updated", "data": task})
        elif p.startswith("/approvals/") and p.endswith("/decision"):
            approval_id = p.split("/")[2]
            body = self._body()
            decision = body.get("decision", "approve")
            with state_lock:
                found = next((a for a in approvals if a["id"] == approval_id), None)
                if found:
                    found["status"] = {"approve": "approved", "edit": "approved",
                                       "reject": "rejected"}.get(decision, "approved")
                    if decision == "edit" and body.get("payload"):
                        found["payload"] = body["payload"]
            if found:
                self._json(found)
            else:
                self._json({"error": "not found"}, status=404)
        elif p == "/memories":
            body = self._body()
            memory = {"id": str(uuid.uuid4()), "text": str(body.get("text", "")),
                      "source": "manual", "pinned": False}
            with state_lock:
                memories.insert(0, memory)
            self._json(memory, status=201)
        elif p == "/auth-requests":
            body = self._body()
            self._json({"id": str(uuid.uuid4()), "site": body.get("site"),
                        "reason": "Mock login flow",
                        "liveViewUrl": "https://example.com/mock-novnc",
                        "expiresAt": iso_in(minutes=10), "status": "pending"}, status=201)
        elif p == "/devices":
            self._json({"ok": True})
        else:
            self._json({"error": f"no mock route for POST {p}"}, status=404)

    def do_PATCH(self):
        p = self._path()
        if not self._authorized():
            return
        body = self._body()
        if p.startswith("/tasks/"):
            task_id = p.split("/")[2]
            with state_lock:
                found = next((t for t in tasks if t["id"] == task_id), None)
                if found:
                    if "status" in body:
                        found["status"] = body["status"]
                    if "snoozeUntil" in body:
                        found["snoozedUntil"] = body["snoozeUntil"]
                    if "priority" in body:
                        found["priority"] = body["priority"]
                    if "title" in body:
                        found["title"] = body["title"]
            if found:
                self._json(found)
                ws_broadcast({"type": "task.updated", "data": found})
            else:
                self._json({"error": "not found"}, status=404)
        elif p.startswith("/inbox/"):
            mail_id = p.split("/")[2]
            with state_lock:
                found = next((m for m in inbox_items if m["id"] == mail_id), None)
                if found:
                    if body.get("makeTask"):
                        task = {"id": str(uuid.uuid4()),
                                "title": found.get("subject") or "Email follow-up",
                                "source": "email", "dueAt": iso_in(days=1),
                                "priority": "normal", "status": "open"}
                        tasks.append(task)
                        found["taskId"] = task["id"]
                        ws_broadcast({"type": "task.updated", "data": task})
                    if "category" in body:
                        found["category"] = body["category"]
            if found:
                self._json(found)
                ws_broadcast({"type": "inbox.updated", "data": {"id": mail_id}})
            else:
                self._json({"error": "not found"}, status=404)
        elif p.startswith("/memories/"):
            memory_id = p.split("/")[2]
            with state_lock:
                found = next((m for m in memories if m["id"] == memory_id), None)
                if found:
                    if "text" in body and body["text"] is not None:
                        found["text"] = body["text"]
                    if "pinned" in body and body["pinned"] is not None:
                        found["pinned"] = body["pinned"]
            if found:
                self._json(found)
            else:
                self._json({"error": "not found"}, status=404)
        else:
            self._json({"error": f"no mock route for PATCH {p}"}, status=404)

    def do_PUT(self):
        p = self._path()
        if not self._authorized():
            return
        if p == "/settings":
            body = self._body()
            with state_lock:
                settings.clear()
                settings.update(body)
                self._json(dict(settings))
        else:
            self._json({"error": f"no mock route for PUT {p}"}, status=404)

    def do_DELETE(self):
        p = self._path()
        if not self._authorized():
            return
        if p.startswith("/memories/"):
            memory_id = p.split("/")[2]
            with state_lock:
                before = len(memories)
                memories[:] = [m for m in memories if m["id"] != memory_id]
            if len(memories) < before:
                self._json({"ok": True})
            else:
                self._json({"error": "not found"}, status=404)
        else:
            self._json({"error": f"no mock route for DELETE {p}"}, status=404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    seed_state()
    print(f"mock noop-agent on http://127.0.0.1:{port}  (any 6-digit code pairs)")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
