#!/usr/bin/env python3
"""Headless load bot: logs in and walks a square to exercise chunk streaming.

This is traffic, not an exploit: it speaks only normal play packets
(handshake/login, client settings, keepalive echoes, position+look, chat)
so the server treats it like a vanilla client. Purpose is load/heat:
walking across chunk borders forces unload bursts, bulk re-sends and
background generation, which is what you watch when hunting leaks or
stalls (track the server's VmRSS across a run).

Usage:
  python3 traffic_bot.py [host] [port] [username] [--duration 150]
"""
import argparse
import select
import socket
import struct
import sys
import time


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


def read_frame(buf: bytearray, s: socket.socket, deadline: float) -> tuple[int, bytes]:
    """Read one Length-prefixed frame, waiting up to `deadline` total.

    Uses select() so an idle connection doesn't burn the deadline while a
    partial multi-hundred-KB bulk frame in flight gets the time it needs.
    """
    def need(n: int) -> bytes:
        while len(buf) < n:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("frame timeout")
            r, _, _ = select.select([s], [], [], remaining)
            if not r:
                continue
            chunk = s.recv(65536)
            if not chunk:
                raise EOFError("eof")
            buf.extend(chunk)
        out = bytes(buf[:n])
        del buf[:n]
        return out

    def rv() -> int:
        n = 0
        shift = 0
        while True:
            v = need(1)[0]
            n |= (v & 0x7F) << shift
            if not (v & 0x80):
                return n
            shift += 7

    ln = rv()
    raw = need(ln)
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
    return pid, raw[off:]


def send_frame(s: socket.socket, pid: int, body: bytes) -> None:
    head = enc_varint(pid) + body
    s.sendall(enc_varint(len(head)) + head)


def main() -> int:
    ap = argparse.ArgumentParser(description="headless load bot for asteorite")
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=25566)
    ap.add_argument("username", nargs="?", default="LoadBot")
    ap.add_argument("--duration", type=float, default=150.0)
    ap.add_argument("--view", type=int, default=8)
    ap.add_argument("--half-side", type=float, default=48.0)
    ap.add_argument("--tick", type=float, default=0.2)
    ap.add_argument("--static", action="store_true",
                    help="log in and idle (no movement): isolates login-burst retention")
    args = ap.parse_args()

    s = socket.create_connection((args.host, args.port), timeout=10)
    s.settimeout(60.0)
    buf = bytearray()

    # handshake (play) + login
    host_b = args.host.encode()
    hs = enc_varint(0) + enc_varint(5) + enc_varint(len(host_b)) + host_b \
        + struct.pack(">H", args.port) + enc_varint(2)
    s.sendall(enc_varint(len(hs)) + hs)
    name_b = args.username.encode()
    ls = enc_varint(0) + enc_varint(len(name_b)) + name_b
    s.sendall(enc_varint(len(ls)) + ls)

    # client settings once (view distance etc.)
    st = enc_string("en_US") + bytes((args.view & 0xFF, 0, 1, 1, 0))
    # read burst until PlayerPosLook
    counts: dict[int, int] = {}
    nbytes = 0
    t0 = time.time()
    try:
        while True:
            pid, body = read_frame(buf, s, time.time() + 60)
            counts[pid] = counts.get(pid, 0) + 1
            nbytes += len(body)
            if pid == 0x00 and len(body) >= 4:  # echo during burst too;
                kid = struct.unpack(">i", body[:4])[0]  # slow logins must
                out = struct.pack(">i", kid)  # still answer keepalive
                s.sendall(enc_varint(len(enc_varint(0) + out)) + enc_varint(0) + out)
            elif pid == 0x40:
                print(f"server disconnected us during login: {body[:200]!r}", flush=True)
                return 2
            elif pid == 0x08:
                break
    except (TimeoutError, EOFError, OSError) as e:
        print(f"login burst failed: {e}", flush=True)
        return 1
    print(f"logged in ({time.time()-t0:.1f}s, {sum(counts.values())} frames)", flush=True)
    send_frame(s, 0x15, st)

    # walk a square around spawn: crosses chunk borders steadily
    cx, cz, y = 8.5, 8.5, 65.0
    h = args.half_side
    waypoints = [(cx - h, cz - h), (cx + h, cz - h), (cx + h, cz + h), (cx - h, cz + h)]
    wx, wz = waypoints[0]
    wi = 1
    step = 5.0
    sent = 0
    recvd = sum(counts.values())
    rbytes = nbytes
    sbytes = 0
    chunk_bulks = 0
    unloads = 0
    next_tick = time.time()
    next_stat = time.time() + 15.0
    next_chat = time.time() + 30.0
    deadline = time.time() + args.duration
    try:
        while time.time() < deadline:
            # drain inbound (non-blocking poll; partial frames stay buffered).
            # bounded per tick so a bulk flood can't starve our own echoes.
            for _ in range(200):
                r, _, _ = select.select([s], [], [], 0)
                if not r and not buf:
                    break
                try:
                    pid, body = read_frame(buf, s, time.time() + 2.0)
                except TimeoutError:
                    break  # stalled mid-frame; resume next tick
                counts[pid] = counts.get(pid, 0) + 1
                recvd += 1
                rbytes += len(body)
                if pid == 0x00 and len(body) >= 4:  # keepalive echo
                    kid = struct.unpack(">i", body[:4])[0]
                    out = struct.pack(">i", kid)
                    s.sendall(enc_varint(len(enc_varint(0) + out)) + enc_varint(0) + out)
                    sent += 1
                elif pid == 0x26:
                    chunk_bulks += 1
                elif pid == 0x21:
                    unloads += 1
                elif pid == 0x40:
                    print("server disconnected us:", body[:200], flush=True)
                    return 2
            now = time.time()
            if now >= next_tick and not args.static:
                next_tick = now + args.tick
                # advance toward current waypoint
                tx, tz = waypoints[wi]
                dx, dz = tx - wx, tz - wz
                dist = (dx * dx + dz * dz) ** 0.5
                if dist < step:
                    wx, wz = tx, tz
                    wi = (wi + 1) % len(waypoints)
                else:
                    wx += dx / dist * step
                    wz += dz / dist * step
                body = struct.pack(">dddd", wx, 65.0, 64.0, wz) \
                    + struct.pack(">ff", 0.0, 0.0) + b"\x01"
                s.sendall(enc_varint(len(enc_varint(0x06) + body)) + enc_varint(0x06) + body)
                sent += 1
                sbytes += len(body)
            if now >= next_chat:
                next_chat = now + 45.0
                cb = enc_string("load test lap")
                s.sendall(enc_varint(len(enc_varint(0x01) + cb)) + enc_varint(0x01) + cb)
                sent += 1
            if now >= next_stat:
                next_stat = now + 15.0
                kinds = sorted(counts.items())
                print(f"  t+{now-t0:.0f}s sent={sent} recvd={recvd} "
                      f"bulk0x26={chunk_bulks} unload0x21={unloads} "
                      f"up={sbytes/1024:.0f}KiB down={rbytes/1024:.0f}KiB", flush=True)
                print(f"    by-id={kinds}", flush=True)
    except (EOFError, OSError) as e:
        print(f"connection lost: {e}", flush=True)
        return 1
    finally:
        try:
            s.close()
        except OSError:
            pass
    print(f"done: {args.duration:.0f}s sent={sent} recvd={recvd} "
          f"bulks={chunk_bulks} unloads={unloads}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
