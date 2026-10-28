#!/usr/bin/env python3
"""End-to-end protocol check for asteorite's network transports.

Speaks the 1.7.10 (protocol 5) wire format directly: status ping, login,
chat echo, keepalive echo and a movement packet. Used to prove that the
io_uring transport and the blocking transport behave identically.

Usage:
  python3 tools/transport_e2e.py --port 25599 [--transport uring|blocking]
                                  [--expect-kick-after N]
Exit code 0 = every check passed.
"""
import argparse
import json
import socket
import struct
import sys
import time

FAILURES = []
CHECKS = 0


def check(cond, label, detail=""):
    global CHECKS
    CHECKS += 1
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label} {detail}")
        FAILURES.append(label)


def enc_varint(n: int) -> bytes:
    if n < 0:
        n &= 0xFFFFFFFF
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += struct.pack("B", b | 0x80)
        else:
            return out + struct.pack("B", b)


def enc_string(s: str) -> bytes:
    b = s.encode("utf8")
    return enc_varint(len(b)) + b


class Client:
    def __init__(self, host: str, port: int, timeout: float = 20.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = bytearray()
        self.frames = []

    def send_frame(self, pid: int, body: bytes = b""):
        head = enc_varint(pid) + body
        self.sock.sendall(enc_varint(len(head)) + head)

    def _need(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("eof")
            self.buf.extend(chunk)
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def read_frame(self):
        """Read one frame -> (packet_id, body)."""
        def rv() -> int:
            n = 0
            shift = 0
            while True:
                v = self._need(1)[0]
                n |= (v & 0x7F) << shift
                if not (v & 0x80):
                    return n
                shift += 7

        ln = rv()
        raw = self._need(ln)
        off = 0
        pid = 0
        shift = 0
        while True:
            v = raw[off]
            off += 1
            pid |= (v & 0x7F) << shift
            if not (v & 0x80):
                break
            shift += 7
        body = raw[off:]
        self.frames.append((pid, body))
        return pid, body

    def drain(self, seconds: float, until=None):
        """Read frames for `seconds` (or until `until(pid, body)` is true)."""
        end = time.time() + seconds
        self.sock.settimeout(0.25)
        while time.time() < end:
            try:
                pid, body = self.read_frame()
            except socket.timeout:
                continue
            except EOFError:
                return
            if until and until(pid, body):
                return pid, body
        return None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def status_ping(host: str, port: int) -> dict:
    c = Client(host, port)
    hs = enc_varint(5) + enc_string(host) + struct.pack(">H", port) + enc_varint(1)
    c.send_frame(0x00, hs)
    c.send_frame(0x00, b"")
    pid, body = c.read_frame()
    if pid != 0x00:
        c.close()
        raise RuntimeError(f"status: unexpected packet {pid:#x}")
    # body: string json
    n = body[0]
    info = json.loads(body[1 : 1 + n].decode("utf8"))
    # 0x01 ping -> 0x01 pong echo. Regression guard: async transports
    # used to close on the finished path before the queued pong went
    # out, so the server list showed the MOTD with red-X "(no connection)"
    # bars. The pong must arrive AND the server must then close.
    import time as _time

    payload = struct.pack(">q", int(_time.time() * 1000))
    c.send_frame(0x01, payload)
    c.sock.settimeout(10)
    try:
        ppid, pbody = c.read_frame()
    except (socket.timeout, EOFError, ConnectionError, OSError) as e:
        c.close()
        raise RuntimeError(f"status pong never arrived ({e!r})")
    if ppid != 0x01 or pbody != payload:
        c.close()
        raise RuntimeError(f"status pong mangled: pid={ppid:#x} body={pbody!r}")
    # server closes after the pong (flush-then-close, no leak)
    c.sock.settimeout(5)
    try:
        c.read_frame()
        c.close()
        raise RuntimeError("status conn stayed open after pong")
    except (EOFError, ConnectionError, OSError):
        c.close()
    except socket.timeout:
        c.close()
        raise RuntimeError("status conn stayed open after pong (read timed out)")
    return info


def play_login(host: str, port: int, name: str, view: int = 4):
    c = Client(host, port)
    hs = enc_varint(5) + enc_string(host) + struct.pack(">H", port) + enc_varint(2)
    c.send_frame(0x00, hs)
    c.send_frame(0x00, enc_string(name))
    return c


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=25599)
    ap.add_argument("--name", default="E2E")
    ap.add_argument("--transport", default="?")
    ap.add_argument("--chat", default="hello from the transport e2e")
    args = ap.parse_args()

    print(f"transport e2e: {args.transport} on {args.host}:{args.port}")

    # 1. status ping
    st = status_ping(args.host, args.port)
    check("1.7.10" in json.dumps(st), "status ping reports 1.7.10", json.dumps(st)[:120])
    check(st.get("players", {}).get("max", 0) > 0, "status ping has a player cap")

    # 2. login
    c = play_login(args.host, args.port, args.name)
    seen = {}
    deadline = time.time() + 25
    while time.time() < deadline:
        try:
            pid, body = c.read_frame()
        except socket.timeout:
            break
        seen.setdefault(pid, 0)
        seen[pid] += 1
        if pid == 0x08:  # Player Position and Look
            break
        if pid == 0x40:
            print(f"  FAIL login rejected: {body[:200]!r}")
            FAILURES.append("login rejected")
            c.close()
            return 1
    check(0x01 in seen, "join game (0x01) received", str(sorted(seen)))
    check(0x08 in seen, "player position and look (0x08) received", str(sorted(seen)))
    check(0x39 in seen, "player abilities (0x39) received", str(sorted(seen)))
    check(0x38 in seen, "player list (0x38) received", str(sorted(seen)))

    # 3. client settings + chat echo
    # NOTE: the first 0x02 may be the join notice ("<name> joined"), which
    # flushes on whatever tick follows login — keep reading until the echo
    # itself arrives (or the deadline), so fast/slow bursts don't flake.
    c.send_frame(0x15, enc_string("en_US") + bytes((4, 1, 0, 1, 0, 127, 0)))
    c.send_frame(0x01, enc_string(args.chat))
    got_chat = False
    chat_body = b""
    end = time.time() + 10
    while time.time() < end and not got_chat:
        try:
            pid, body = c.read_frame()
        except socket.timeout:
            continue
        if pid == 0x02:
            n0 = body[0]
            raw0 = body[1 : 1 + n0].decode("utf8", "replace")
            try:
                parsed0 = json.loads(raw0)
            except Exception:
                parsed0 = {}
            if args.chat in parsed0.get("text", "") or args.chat in parsed0.get("translate", ""):
                got_chat = True
                chat_body = body
    check(got_chat, "chat echo (0x02) received")
    if got_chat:
        n = chat_body[0]
        raw = chat_body[1 : 1 + n].decode("utf8")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {}
        check(args.chat in parsed.get("text", "") or args.chat in parsed.get("translate", ""),
              "chat echo carries the message", raw[:160])

    # 4. movement
    # 1.7.10 quirk: 0x06 carries x, stance, y, z (the stance double).
    c.send_frame(0x06, struct.pack(">ddddff", 8.5, 65.0, 64.0, 8.5, 0.0, 0.0) + b"\x01")
    time.sleep(0.4)

    # 5. keepalive echo (the server kicks if the echo is missing)
    ka = 0
    end = time.time() + 20
    got_ka = False
    while time.time() < end and not got_ka:
        try:
            pid, body = c.read_frame()
        except socket.timeout:
            continue
        if pid == 0x00 and len(body) >= 4:
            kid = struct.unpack(">i", body[:4])[0]
            c.send_frame(0x00, struct.pack(">i", kid))
            ka += 1
            got_ka = True
    check(got_ka, "keepalive (0x00) received and echoed")

    # 6. still alive after the echo (no kick)
    kicked = False
    end = time.time() + 3
    while time.time() < end:
        try:
            pid, body = c.read_frame()
        except socket.timeout:
            continue
        if pid == 0x40:
            kicked = True
            break
    check(not kicked, "no disconnect after the keepalive echo")

    c.close()
    print(f"  {CHECKS - len(FAILURES)}/{CHECKS} checks passed")
    if FAILURES:
        print("FAILED: " + ", ".join(FAILURES))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
