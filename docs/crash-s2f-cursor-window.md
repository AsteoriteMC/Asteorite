# Client crash exploits: S2F cursor window + living-health watcher type

- Status: both fixed. Every login with a world used to crash any vanilla
  1.7.10 client deterministically (first in `GuiDownloadTerrain`, then on
  the first living-entity tick once past it).
- Reported by: local vanilla 1.7.10 client (PrismLauncher) vs zigcraft
  `localhost:25566`, crash on every join right after login.

## Crash 1: cursor Set Slot as window 0 / slot -1 (fixed)

### Symptoms

Client dies in "Ticking screen" while `GuiDownloadTerrain` (`bdu`) is up,
before any chunk renders (`Chunk stats: MultiplayerChunkCache: 0, 0`):

```
java.lang.ArrayIndexOutOfBoundsException: -1
    at java.util.ArrayList.elementData(ArrayList.java:422)
    at java.util.ArrayList.get(ArrayList.java:435)
    at zs.a(SourceFile:104)      <- Container.getSlot
    at zs.a(SourceFile:385)      <- Container.putStackInSlot
    at bjb.a(SourceFile:727)     <- NetHandlerPlayClient.handleSetSlot
    at gq.a(SourceFile:27)       <- S2FPacketSetSlot.processPacket
    at gq.a(SourceFile:10)
    at ej.a(SourceFile:174)
    at bcx.e(SourceFile:78)
    at bao.p(SourceFile:1343)
```

Player entity already exists (`All players: 1`), world time is set
(`Level time: 2340`), so JoinGame/PosLook/TimeUpdate all parsed fine.
The killer packet arrives in the login burst just after the bulk chunks.

## Root cause

Vanilla 1.7.10 `NetHandlerPlayClient.handleSetSlot` (CFR decompile of
`minecraft-1.7.10-client.jar`, class `bjb`, method `a(gq)` — `gq` is
S2F: byte windowId, short slot, ItemStack):

```java
public void a(gq gq2) {
    if (gq2.c() == -1) {              // windowId == -1 -> cursor
        player.inventory.setItemStack(gq2.e());
    } else {
        ...
        player.openContainer.a(gq2.d(), gq2.e());  // putStackInSlot(slot)
    }
}
```

Cursor is selected by **windowId == -1**, not by slot. `Container.putStackInSlot`
calls `getSlot(slot)` unconditionally, and `getSlot` is a bare
`ArrayList.get` — so any other window with slot -1 throws AIOOBE: -1.

zigcraft framed every cursor update as **window 0, slot -1**
(`sendSlot(-1)`, `sendCursor()`, `sendSlotWin(0, -1)`, the furnace
take/click cursor syncs, and the login inventory sync in
`server.zig`, which sends `frameSetSlotAlloc(0, -1, cursor)`
unconditionally — even for an empty cursor, since `getSlot` throws
before the item is touched). Vanilla's own convention (cf.
`EntityPlayerMP`: `new S2FPacketSetSlot(-1, -1, ...)`) is window -1.

Our scripted test clients never caught it: they parse S2F fields but
never emulate the windowId==-1 cursor rule, and our unit tests pinned
*our* convention (`frameSetSlotAlloc(0, -1, ...)` round-trip).

## Trigger

Any login when a world is present (login inventory sync), plus any later
cursor sync (click pickup/place/swap, craft take, furnace take). No
attacker needed — the server crashes its own players. Conversely, any
rogue 1.7.10 server can crash connecting vanilla clients the same way,
so treat unexpected S2F frames from untrusted servers as hostile.

## Fix

Frame cursor updates as window -1, slot -1:

- `src/net/conn.zig`: `sendSlot` (window follows slot sign), `sendCursor`,
  three `sendSlotWin(0, -1)` call sites.
- `src/net/server.zig`: furnace take/click cursor syncs, login cursor sync.
- `src/proto/v5/packets.zig`: unit test now frames `(-1, -1)` and asserts
  the window byte; `src/net/conn.zig` click test asserts window -1 on
  cursor frames.

## Verification (crash 1)

- `zig build test --summary all`: 21/21 steps, 186/186 tests green.
- PoC `poc/setslot_cursor_crash.py`: logs in (offline mode), captures the
  burst through PlayerPosLook, emulates the vanilla handler
  (`window == -1 -> cursor`, else `slots[slot]` with Java-style bounds).
  Before the fix it reports
  `0x2F SetSlot window=0 slot=-1` + `CRASH ArrayIndexOutOfBoundsException: -1`
  (exit 1); after the fix the cursor frame is `window=-1 slot=-1` (exit 0).
- Real-client rejoin after the fix is still owed: connect a vanilla 1.7.10
  client and confirm it lands past GuiDownloadTerrain without a crash
  report.

## Crash 2: living health tagged as int instead of float (fixed)

With crash 1 fixed, the client gets chunks (`MultiplayerChunkCache:
81, 81`) and then dies on "Ticking entity" — our demo pig:

```
java.lang.ClassCastException: java.lang.Integer cannot be cast to java.lang.Float
    at te.d(SourceFile:95)     <- DataWatcher.getWatchableObjectFloat
    at sv.aS(SourceFile:549)   <- EntityLivingBase.getHealth
    ...
-- Entity being ticked --
Entity Type: Pig (wo), Entity ID: 1
```

### Root cause

Vanilla 1.7.10 `DataWatcher` types (official server jar, class `te`,
static init — the same ids the client uses):

```
Byte -> 0, Short -> 1, Integer -> 2, Float -> 3, String -> 4, ...
```

`writeLivingBaseline` (`src/proto/v5/packets.zig`) tagged index 6
(health) as `(2 << 5) | 6` — type **int** carrying float bits. The client
stores an Integer at watcher 6 and throws the moment anything calls
`getFloat(6)` (first living-entity tick: pig, then the player). The
metadata *parsed* fine, so there was no parse error — just a poisoned
watcher. The pig existing at all proves the 0x0F layout (incl. velocity
tail) is byte-aligned; only the tag was wrong.

### Fix

One byte: `(2 << 5) | 6` -> `(3 << 5) | 6` (`0x46` -> `0x66`), plus a
regression test pinning the exact baseline bytes
(`(0:byte)(1:short 300)(6:float) + 0x7F`) and updating the
`resolveAttack` test that had pinned the buggy `0x46`. Covers Spawn
Player (0x0C), Spawn Mob (0x0F), and all 0x1C living updates — they share
`writeLivingBaseline`.

### Verification (crash 2)

- Same suite green (21/21, 186/186; the fixed `resolveAttack` test now
  asserts `0x66`).
- PoC extended to walk 0x0F/0x1C watcher lists and flag `(type 2,
  index 6)`: against the pre-fix server it reports
  `0x0F SpawnMob metadata: CRASH TAG: index 6 as int(2)` (exit 1);
  against the fixed server all metadata is float-tagged (exit 0).
- Real-client rejoin owed again: confirm the client survives the pig tick
  and can walk around spawn.
