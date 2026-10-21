# Client crash exploit: S2F cursor framed as window 0 / slot -1

- Status: fixed (`sendSlot`/`sendCursor`/`sendSlotWin`/furnace/login cursor
  syncs now frame window -1). Every login with a world used to crash any
  vanilla 1.7.10 client deterministically.
- Reported by: local vanilla 1.7.10 client (PrismLauncher) vs zigcraft
  `localhost:25566`, crash on every join right after login.

## Symptoms

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

## Verification

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
