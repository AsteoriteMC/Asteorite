#!/usr/bin/env python3
"""PoC: zigcraft S2F cursor packet crashes vanilla 1.7.10 clients.

Exploit: the server frames cursor updates as Set Slot (0x2F) with
window=0, slot=-1. Vanilla 1.7.10's NetHandlerPlayClient.handleSetSlot
(CFR decompile of minecraft-1.7.10-client.jar, class bjb, method a(gq)):

    if (windowId == -1) {          // gq.c() == -1 -> cursor
        inventory.setItemStack(item);
    } else {
        ...
        openContainer.putStackInSlot(slot, item);   // -> slots.get(slot)
    }

With window=0 the else-branch runs putStackInSlot(-1) ->
Container.getSlot(-1) -> ArrayList.get(-1) ->
java.lang.ArrayIndexOutOfBoundsException: -1, ticking GuiDownloadTerrain.

Correct vanilla convention (cf. EntityPlayerMP): cursor = window -1, slot -1.

This script logs in (offline mode), captures play packets through
PlayerPosLook, finds 0x2F cursor frames, and emulates the vanilla handler.
Exit 0 + "SAFE" if no crashing frame is seen; exit 1 + "CRASH" if the
exploit triggers (mirrors the Java AIOOBE as a Python IndexError).

Usage: python3 setslot_cursor_crash.py [host] [port] [username]
"""
import socket
import struct
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 25566
NAME = sys.argv[3] if len(sys.argv) > 3 else "PocBot"


def enc_varint(n: int) -> bytes:
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += struct.pack("B", b | 0x80)
        else:
            out += struct.pack("B", b)
            return out


class Reader:
    def __init__(self, f):
        self.f = f

    def read(self, n: int) -> bytes:
        b = self.f.read(n)
        if len(b) != n:
            raise EOFError("short read")
        return b

    def varint(self) -> int:
        n = 0
        shift = 0
        while True:
            v = self.read(1)[0]
            n |= (v & 0x7F) << shift
            if not (v & 0x80):
                return n
            shift += 7

    def frame(self):
        ln = self.varint()
        pid = self.varint()
        body = self.read(ln - len(enc_varint(pid)))
        return pid, body


def parse_slot(body: bytes, off: int):
    wid = struct.unpack_from("b", body, off)[0]
    off += 1
    slot = struct.unpack_from(">h", body, off)[0]
    off += 2
    item_id = struct.unpack_from(">h", body, off)[0]
    off += 2
    if item_id != -1:
        off += 1 + 2  # count + damage
        nbt_len = struct.unpack_from(">h", body, off)[0]
        off += 2
        if nbt_len > 0:
            off += nbt_len
    return wid, slot, off


# --- vanilla 1.7.10 handler emulation (bjb.a(gq) / zs.getSlot) ---
class VanillaContainer:
    def __init__(self):
        self.slots = [None] * 45  # ContainerPlayer inventorySlots

    def getSlot(self, i: int):
        # Java ArrayList.get: negative indices throw (unlike Python).
        if i < 0 or i >= len(self.slots):
            raise IndexError(f"Index {i} out of bounds for length {len(self.slots)}")
        return self.slots[i]  # AIOOBE mirrored as IndexError

    def putStackInSlot(self, i: int, stack):
        self.getSlot(i)  # throws before touching the item


def vanilla_handle_setslot(window: int, slot, container: VanillaContainer):
    if window == -1:  # gq.c() == -1 -> cursor path, safe
        return "cursor"
    container.putStackInSlot(slot, None)  # raises IndexError for slot=-1
    return "container"


def main() -> int:
    s = socket.create_connection((HOST, PORT), timeout=10)
    s.settimeout(10)
    f = s.makefile("rb")
    r = Reader(f)

    host_b = HOST.encode()
    hs = enc_varint(0) + enc_varint(5) + enc_varint(len(host_b)) + host_b \
        + struct.pack(">H", PORT) + enc_varint(2)
    s.sendall(enc_varint(len(hs)) + hs)
    name_b = NAME.encode()
    ls = enc_varint(0) + enc_varint(len(name_b)) + name_b
    s.sendall(enc_varint(len(ls)) + ls)

    container = VanillaContainer()
    cursor_frames = []
    try:
        while True:
            pid, body = r.frame()
            if pid == 0x2F:
                wid, slot, _ = parse_slot(body, 0)
                cursor_frames.append((wid, slot))
                print(f"  0x2F SetSlot window={wid} slot={slot}")
                if slot == -1:
                    try:
                        vanilla_handle_setslot(wid, slot, container)
                        print("    vanilla: survived (cursor path)")
                    except IndexError as e:
                        print(f"    vanilla: CRASH ArrayIndexOutOfBoundsException: -1 ({e})")
                        print("EXPLOIT TRIGGERED: window=0/slot=-1 cursor frame")
                        return 1
            elif pid == 0x08:
                print("  0x08 PlayerPosLook (login burst complete)")
                break
    except (EOFError, socket.timeout) as e:
        print(f"  [!] stream ended early: {e}")
    finally:
        s.close()

    if not cursor_frames:
        print("no 0x2F frames seen (no world? --db/--seed missing?)")
        return 2
    print("SAFE: no crashing cursor frame observed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
