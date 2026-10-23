# Vanilla fixtures (real 1.7.10 server output — never hand-written)

## vanilla_player.dat (617 bytes gzipped NBT)
An actual `player.dat` produced by the official 1.7.10 server jar:

- jar sha256: `c70870f00c4024d829e154f7e5f4e885b02dd87991726a3308d81f513972f3fc`
  (Mojang launcher `server.jar`, 952438ac4e01b4d115c5fc38f891710c4941df29)
- run under OpenJDK 21.0.12.1, offline mode, `gamemode=1`
- session: login as `Steve` (offline UUID
  `5627dd98-e6be-3c21-b8a8-e92344183641` — matches our own
  `offlineUuid("Steve")`, cross-checked in hex), creative give of 64 stone
  to hotbar slot 0, creative give of a diamond sword renamed to "Hi"
  (NBT `display:{Name:"Hi"}`) to hotbar slot 1, one 0x06 position packet
  to x=100.5 (**ignored by the vanilla server**: its moved-too-quickly
  guard dropped the teleport, so the file records the login spawn —
  a useful reminder that vanilla is server-authoritative nowhere here),
  disconnect (server saves the row on logout).
- resulting row: `Pos=[-116.5, 69.0, 250.5]`, `Rotation=[0,0]`,
  `HealF=20.0` + `Health=20(short)`, `foodLevel=20`,
  `foodSaturationLevel=5.0`, `playerGameType=1`, `SelectedItemSlot=0`,
  `Inventory=[{Slot:0,id:1(stone),Count:64}, {Slot:1,id:276,Count:1,
  tag:{display:{Name:"Hi"}}}]`, no `SpawnX/Y/Z` (no bed → exercises the
  spawn-fallback path), `Dimension=0`.

To regenerate: boot the jar above with `eula=true`,
`online-mode=false`, `gamemode=1`; replay the session above with a
scripted 1.7 client (`/tmp/opencode/fixture_session.py` pattern:
login → drain to 0x08 → two 0x10 creative gives (second with a
gzip NBT payload) → one 0x06 move → sleep → close); copy
`world/playerdata/<uuid>.dat` here.
