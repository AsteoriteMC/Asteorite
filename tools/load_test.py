#!/usr/bin/env python3
"""Load test for the asteorite transports (Phase B acceptance).

Opens N connections at once (asyncio), logs them all in, echoes the
server's keepalives and (optionally) walks the moving ones around so the
server streams chunks. Reports the login rate, the error count and the
per-connection uptime, so the server's own stats line (tick/flush p99,
RSS) can be read next to it.

Usage:
  python3 tools/load_test.py --port 25599 [--idle 500] [--moving 100]
                             [--seconds 60] [--view 8]
"""
import argparse
import asyncio
import json
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


class Conn:
    def __init__(self, name):
        self.name = name
        self.reader = None
        self.writer = None
        self.keepalives = 0
        self.bulks = 0
        self.unloads = 0
        self.errors = 0
        self.joined = False

    async def connect(self, host, port, view):
        self.reader, self.writer = await asyncio.open_connection(host, port)
        host_b = host.encode()
        hs = enc_varint(5) + enc_string(host) + struct.pack(">H", port) + enc_varint(2)
        self.writer.write(enc_varint(len(enc_varint(0) + hs)) + enc_varint(0) + hs)
        ls = enc_varint(0) + enc_string(self.name)
        self.writer.write(enc_varint(len(ls)) + ls)
        await self.writer.drain()

    def send(self, pid, body=b""):
        head = enc_varint(pid) + body
        self.writer.write(enc_varint(len(head)) + head)

    async def pump(self):
        """Read frames; echo keepalives; count chunk traffic."""
        try:
            while True:
                ln = 0
                shift = 0
                while True:
                    b = (await self.reader.readexactly(1))[0]
                    ln |= (b & 0x7F) << shift
                    if not (b & 0x80):
                        break
                    shift += 7
                raw = await self.reader.readexactly(ln)
                pid = raw[0]
                if pid == 0x00 and len(raw) >= 5:
                    kid = struct.unpack(">i", raw[1:5])[0]
                    self.send(0x00, struct.pack(">i", kid))
                    self.keepalives += 1
                elif pid == 0x26:
                    self.bulks += 1
                elif pid == 0x21:
                    self.unloads += 1
                elif pid == 0x08:
                    self.joined = True
        except (asyncio.IncompleteReadError, ConnectionResetError, OSError):
            return

    async def walk(self, seconds, step=0.2):
        """Walk a square (crosses chunk borders -> chunk streaming)."""
        pts = [(-24, -24), (24, -24), (24, 24), (-24, 24)]
        wi = 1
        x, z = pts[0]
        tx, tz = pts[wi]
        end = time.time() + seconds
        while time.time() < end:
            dx, dz = tx - x, tz - z
            dist = (dx * dx + dz * dz) ** 0.5
            if dist < 5:
                x, z = tx, tz
                wi = (wi + 1) % len(pts)
                tx, tz = pts[wi]
            else:
                x += dx / dist * 5
                z += dz / dist * 5
            body = struct.pack(">dddd", x, 65.0, 64.0, z) + struct.pack(">ff", 0.0, 0.0) + b"\x01"
            self.send(0x06, body)
            try:
                await self.writer.drain()
            except Exception:
                return
            await asyncio.sleep(step)


async def one(host, port, name, view, moving, seconds, results, retries=3):
    c = Conn(name)
    for attempt in range(retries + 1):
        try:
            await asyncio.wait_for(c.connect(host, port, view), timeout=30)
            break
        except Exception as e:
            c.errors += 1
            if attempt == retries:
                results.append(c)
                return
            await asyncio.sleep(0.2 * (attempt + 1))
    # Client settings (view distance).
    c.send(0x15, enc_string("en_US") + bytes((view & 0xFF, 0, 1, 1, 0)))
    pump = asyncio.create_task(c.pump())
    if moving:
        walk = asyncio.create_task(c.walk(seconds))
    else:
        walk = None
    await asyncio.sleep(seconds)
    if walk:
        walk.cancel()
    pump.cancel()
    try:
        c.writer.close()
    except Exception:
        pass
    results.append(c)


async def main_async(args):
    total = args.idle + args.moving
    results = []
    t0 = time.time()
    tasks = []
    for i in range(total):
        moving = i >= args.idle
        name = f"{'M' if moving else 'I'}{i}"
        tasks.append(asyncio.create_task(one(args.host, args.port, name, args.view, moving, args.seconds, results)))
    # Connect rate: a real server does not get 600 SYNs in the same
    # millisecond (the listen backlog would refuse them).
    if args.rate > 0:
        chunk = max(1, args.rate // 20)
        for i in range(0, len(tasks), chunk):
            await asyncio.gather(*tasks[i : i + chunk], return_exceptions=True)
            await asyncio.sleep(0.05)
    else:
        await asyncio.gather(*tasks, return_exceptions=True)
    elapsed = time.time() - t0

    joined = sum(1 for c in results if c.joined)
    errs = sum(c.errors for c in results)
    kas = sum(c.keepalives for c in results)
    bulks = sum(c.bulks for c in results)
    unloads = sum(c.unloads for c in results)
    print(f"conns={total} joined={joined} errors={errs} keepalives={kas} bulks={bulks} unloads={unloads} elapsed={elapsed:.1f}s")
    if joined < total:
        print(f"WARNING: {total - joined} connections never joined")
    return 0 if errs == 0 and joined == total else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=25599)
    ap.add_argument("--idle", type=int, default=500)
    ap.add_argument("--moving", type=int, default=100)
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--view", type=int, default=8)
    ap.add_argument("--rate", type=int, default=200, help="connect rate per second (0 = all at once)")
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
