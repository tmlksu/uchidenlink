#!/usr/bin/env python3
"""Minimal mock relay for uchidenlink iOS Phase 0a verification (stdlib only).

Speaks just enough of docs/PROTOCOL.md for the foreground path:
  - accepts a WebSocket connection on ws://0.0.0.0:8765/v1/session
  - immediately on connect: sends `hello` (unregistered, account ""),
    like the real relay (session.go writeHello)
  - on `sip_account`: replies `hello` (registered) + `registration ok`
  - 2 s later: sends `incoming` (callId "mock-call-1", from "1001", pt 0)
  - on `answer`: replies `answered`; binary RTP frames are echoed back
  - on `reject` / `hangup`: replies `ended`
  - on `ping`: replies `pong`

Phase 2 additions (all optional):
  - on `dial`: `ringing` then (1 s) `answered`
  - after answer: sends a paced 20 ms PCMU stream (440 Hz tone) instead of
    echoing, with an injectable network model:
      --stall-every SEC --stall-ms MS  hold packets for MS every SEC seconds and
                                       release them as a burst (what TCP does)
      --jitter-ms MS                   random per-packet delay 0..MS, order kept
  - --drop-at SEC: abruptly close the socket SEC seconds into the call once;
    the reconnect (same X-Device-Id) gets hello.call state=active (RESUME)
  - --no-incoming: do not send the automatic incoming call
  - --relay-version V (default 0.3.0) so the app sends call_stats; logged here
  - --echo: echo RTP back (Phase 0a behaviour) instead of the tone stream

Usage: python3 mock_relay.py [port] [options]
"""
import argparse
import math
import random
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def read_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def read_http_headers(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("closed during handshake")
        buf += chunk
        if len(buf) > 65536:
            raise ConnectionError("headers too large")
    return buf.decode("latin1")


SEND_LOCK = threading.RLock()


def send_frame(conn, opcode, payload):
    with SEND_LOCK:
        _send_frame(conn, opcode, payload)


def _send_frame(conn, opcode, payload):
    header = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    conn.sendall(bytes(header) + payload)


def send_text(conn, obj):
    data = json.dumps(obj).encode()
    send_frame(conn, 0x1, data)
    log(f">>> {data.decode()}")


def recv_frame(conn):
    b0, b1 = read_exact(conn, 2)
    opcode = b0 & 0x0F
    masked = b1 & 0x80
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(conn, 8))[0]
    mask = read_exact(conn, 4) if masked else b"\x00" * 4
    payload = bytearray(read_exact(conn, length)) if length else bytearray()
    for i in range(length):
        payload[i] ^= mask[i % 4]
    return opcode, bytes(payload)


OPTS = None
# device id -> {"conn": socket, "lock": Lock, "call": dict|None, "dropped": bool}
DEVICES = {}
DEV_LOCK = threading.Lock()


def ulaw(sample):
    BIAS, CLIP = 0x84, 32635
    sign = 0x80 if sample < 0 else 0
    if sample < 0:
        sample = -sample
    sample = min(sample, CLIP) + BIAS
    exp = 7
    mask = 0x4000
    while exp > 0 and not (sample & mask):
        exp -= 1
        mask >>= 1
    mant = (sample >> (exp + 3)) & 0x0F
    return ~(sign | (exp << 4) | mant) & 0xFF


def tone_stream(dev, call):
    """Paced 20 ms RTP with the configured network model."""
    seq = random.randint(0, 65535)
    ts = random.randint(0, 2**32 - 1)
    ssrc = random.randint(0, 2**32 - 1)
    phase = 0.0
    start = time.monotonic()
    n = 0
    held = []
    next_stall = start + OPTS.stall_every if OPTS.stall_every else None
    stall_until = None
    while call.get("active"):
        n += 1
        target = start + n * 0.020
        now = time.monotonic()
        if target > now:
            time.sleep(target - now)
        payload = bytearray(160)
        for i in range(160):
            payload[i] = ulaw(int(8000 * math.sin(phase)))
            phase += 2 * math.pi * 440 / 8000
        pkt = struct.pack(">BBHII", 0x80, 0, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc) + bytes(payload)
        seq += 1
        ts += 160
        now = time.monotonic()
        if next_stall and now >= next_stall and stall_until is None:
            stall_until = now + OPTS.stall_ms / 1000.0
            next_stall += OPTS.stall_every
        if stall_until is not None:
            held.append(pkt)
            if now < stall_until:
                continue
            stall_until = None
            out = held
            held = []
        else:
            out = [pkt]
        for p in out:
            if OPTS.jitter_ms:
                time.sleep(random.uniform(0, OPTS.jitter_ms) / 1000.0 / max(1, len(out)))
            c = dev.get("conn")
            if c is None:
                continue  # disconnected: packets are lost (relay would buffer briefly)
            try:
                with dev["lock"]:
                    send_frame(c, 0x2, p)
            except Exception:
                pass


def start_call_media(dev, call):
    call["active"] = True
    call["state"] = "active"
    call["answeredAt"] = time.monotonic()
    if not OPTS.echo:
        threading.Thread(target=tone_stream, args=(dev, call), daemon=True).start()
    if OPTS.drop_at and not dev.get("dropped"):
        def drop():
            time.sleep(OPTS.drop_at)
            if call.get("active") and dev.get("conn") is not None:
                dev["dropped"] = True
                log(f"--drop-at: closing socket {OPTS.drop_at}s into the call (RESUME test)")
                try:
                    dev["conn"].shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass
        threading.Thread(target=drop, daemon=True).start()


def send_hello(conn, account, registered, call=None):
    # Mirrors relay session.go writeHello: relayVersion / extension /
    # account (same value) / registered / call (CallInfo or null) /
    # serverTime (unix seconds).
    info = None
    if call and call.get("state"):
        info = {"callId": call["callId"], "direction": call["direction"], "state": call["state"],
                "from": call.get("from", ""), "display": "", "pt": 0, "startedAt": 0}
    send_text(conn, {"t": "hello", "relayVersion": OPTS.relay_version,
                     "extension": account, "account": account,
                     "registered": registered, "call": info,
                     "serverTime": int(time.time())})


def handle_client(conn, addr):
    log(f"connection from {addr}")
    try:
        headers = read_http_headers(conn)
        key = None
        device = "anon"
        for line in headers.split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
            if line.lower().startswith("x-device-id:"):
                device = line.split(":", 1)[1].strip()
        if not key:
            log("no Sec-WebSocket-Key; closing")
            conn.close()
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        conn.sendall((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode())
        log("websocket open")

        # The real relay sends hello immediately on connect, before any
        # client message; the app waits for it before sending sip_account.
        with DEV_LOCK:
            dev = DEVICES.setdefault(device, {"lock": threading.Lock(), "call": None, "account": ""})
            dev["conn"] = conn
        send_hello(conn, dev["account"], bool(dev["account"]), dev["call"])

        state = {"incoming_sent": False, "answered": False}

        def send_incoming_later():
            time.sleep(2.0)
            try:
                dev["call"] = {"callId": "mock-call-1", "direction": "in", "state": "ringing", "from": "1001"}
                send_text(conn, {"t": "incoming", "callId": "mock-call-1",
                                 "from": "1001", "display": "Mock Caller", "pt": 0})
                state["incoming_sent"] = True
            except Exception as e:
                log(f"incoming send failed: {e}")

        while True:
            opcode, payload = recv_frame(conn)
            if opcode == 0x8:  # close
                log("close frame; bye")
                try:
                    send_frame(conn, 0x8, b"")
                except Exception:
                    pass
                break
            if opcode == 0x9:  # ping -> pong
                send_frame(conn, 0xA, payload)
                continue
            if opcode == 0x2:  # binary (RTP)
                if OPTS.echo:
                    with dev["lock"]:
                        send_frame(conn, 0x2, payload)
                continue
            if opcode != 0x1:
                continue
            text = payload.decode("utf-8", "replace")
            log(f"<<< {text}")
            try:
                msg = json.loads(text)
            except Exception:
                continue
            t = msg.get("t")
            if t == "sip_account":
                user = msg.get("user", "")
                first = not dev["account"]
                dev["account"] = user
                send_hello(conn, user, True, dev["call"])
                send_text(conn, {"t": "registration", "ok": True, "detail": "mock"})
                if first and not OPTS.no_incoming:
                    threading.Thread(target=send_incoming_later, daemon=True).start()
            elif t == "ping":
                send_text(conn, {"t": "pong", "ts": msg.get("ts", 0)})
            elif t == "answer":
                state["answered"] = True
                send_text(conn, {"t": "answered", "callId": msg.get("callId", ""), "pt": 0})
                if dev["call"]:
                    start_call_media(dev, dev["call"])
            elif t == "dial":
                call = {"callId": f"mock-out-{int(time.time())}", "direction": "out", "state": "ringing", "from": msg.get("to", "")}
                dev["call"] = call
                send_text(conn, {"t": "ringing", "callId": call["callId"], "early": False})

                def answer_later(call=call):
                    time.sleep(1.0)
                    if dev["call"] is call:
                        with dev["lock"]:
                            send_text(dev["conn"], {"t": "answered", "callId": call["callId"], "pt": 0})
                        start_call_media(dev, call)
                threading.Thread(target=answer_later, daemon=True).start()
            elif t in ("reject", "hangup"):
                if dev["call"]:
                    dev["call"]["active"] = False
                    dev["call"] = None
                send_text(conn, {"t": "ended", "callId": msg.get("callId", ""),
                                 "reason": "reject" if t == "reject" else "bye",
                                 "code": 486 if t == "reject" else 200})
            elif t == "call_stats":
                log("call_stats received (logged above)")
    except Exception as e:
        log(f"client {addr} ended: {e}")
    finally:
        with DEV_LOCK:
            for d in DEVICES.values():
                if d.get("conn") is conn:
                    d["conn"] = None
        try:
            conn.close()
        except Exception:
            pass


def main():
    global OPTS
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?", type=int, default=8765)
    ap.add_argument("--no-incoming", action="store_true")
    ap.add_argument("--relay-version", default="0.3.0")
    ap.add_argument("--stall-every", type=float, default=0)
    ap.add_argument("--stall-ms", type=float, default=0)
    ap.add_argument("--jitter-ms", type=float, default=0)
    ap.add_argument("--drop-at", type=float, default=0)
    ap.add_argument("--echo", action="store_true")
    OPTS = ap.parse_args()
    port = OPTS.port
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", port))
    server.listen(5)
    log(f"mock relay listening on 0.0.0.0:{port}")
    while True:
        conn, addr = server.accept()
        threading.Thread(target=handle_client, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
