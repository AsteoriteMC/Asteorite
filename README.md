# Asteorite

<img src="assets/brand/logo.png" width="320" align="right" alt="Asteorite logo">

_Asteorite_ server software.

A vanilla **Minecraft 1.7.10** server (protocol 5) in pure Zig — no Java
needed to build or run. Terrain generation is bit-identical to vanilla
1.7.10 (verified against live JVM oracles).

Requires **Zig 0.16.0** (see `build.zig.zon`).

## Building

```sh
zig build                  # debug binaries -> zig-out/bin/
zig build -Doptimize=ReleaseFast   # release binaries -> zig-out/bin/
```

The `asteorite` binary is ~15 MB in release mode. Both flavors land in
`zig-out/bin/` (a release build overwrites the debug binaries there and
vice versa).

## Starting a server

```sh
./zig-out/bin/asteorite serve
# or without installing first:
zig build run -- serve
# (put "seed": 42 in asteorite.json for worldgen — see below)
```

Then connect with a vanilla 1.7.10 client to `localhost:25565`
(offline mode by default — no Mojang account needed).

First-run notes:

- **Admin access is console-only by default.** Bootstrap an op with
  `--op <name>` (persisted in the db, so you only need it once), then use
  in-game/console commands from there. Console commands: `help`, `list`,
  `save-all`, `stop`.
- The world **seed lives in the config file** (`"seed"` in `asteorite.json`;
  there is no `--seed` flag). It drives on-demand chunk generation into
  the world folder (default `./world`, overridable with `--db`; set
  `"db": null` to disable persistence). If the seed changes, delete the
  world folder — stored chunks are never regenerated.
- `--gen-spawn <r>` pre-generates a spawn disk of radius `r` on boot
  (needs `"seed"` in the config file), so players don't wait on
  first join.
- `--online` enables Mojang auth; RSA keys (`server_rsa.key/.der`) are
  created automatically in the working directory.
- RCON is off unless `--rcon-password` is set (default port 25575).

## Arguments

`asteorite serve [port] [options]` — run `serve --help` for the full text.
Precedence is **built-in defaults < config file < CLI flags**.

| Flag | Default | Notes |
|---|---|---|
| `[port]` (positional) | 25565 | listen port |
| `--online` / `--no-online` | off | Mojang auth; `--no-` wins over a config file |
| `--db <path>` | `world` | LSM world database directory (`"db": null` disables persistence) |
| `--view <1..16>` | 4 | view distance; 1.7.10 clients cap at 16 |
| `--gen-spawn <r>` | none | pre-generate spawn disk, needs `"seed"` in config |
| `--gen-workers <n>` | cpu count (max 8) | background chunk-gen workers |
| `--op <name>` | — | repeatable; grants op, persisted |
| `--rcon-password <pw>` | none | enables RCON |
| `--rcon-port <port>` | 25575 | RCON port |
| `--motd <text>` | `Asteorite` | server list message |
| `--max-players <n>` | 20 | server list player cap |
| `--brand <name>` | `vanilla` | `vanilla`, `fabric`, or `forge` (`fml` accepted; see below) |
| `--transport <kind>` | `auto` | `auto`, `uring`, `kqueue`, `iocp`, `blocking` (network backend) |
| `--transport-workers <n>` | cpu count (max 8) | io_uring/kqueue worker threads (one ring per worker) |
| `--region-threads <n>` | cpu count (max 8) | region tick threads (1 = sequential legacy path) |
| `--storage-profile <p>` | `auto` | `auto`, `hdd`, `ssd`, `nvme` (SST sizing + io_uring SST reads) |
| `--out-cap <bytes>` | 4 MiB | per-connection outbox cap; a slow consumer past it is dropped |
| `--send-zc-threshold <bytes>` | 8192 | frames at/above this size go out zerocopy (`SEND_ZC`) |
| `--tcp-nodelay` / `--no-tcp-nodelay` | on | `TCP_NODELAY` on accepted sockets |
| `--sndbuf <bytes>` / `--rcvbuf <bytes>` | OS default | socket buffer sizes |
| `-c, --config <path>` | `./asteorite.json` if present | JSON config file |
| `-h, --help` | — | help |

`--flag value` and `--flag=value` both work; `--` ends flag parsing.

### Network transports

`--transport` picks the network backend; `auto` resolves per OS
(io_uring on Linux, kqueue on macOS/BSD, IOCP on Windows, blocking
anywhere with `--transport blocking`).

The **io_uring** backend (Linux) is the fast path: one ring per worker
thread, multishot accept, multishot recv with registered buffer rings,
and zerocopy sends for the big frames (chunk bulks). Measured on a
20-core box with 500 idle + 100 moving clients: **600/600 joined, 0
errors, output push p99 0.99 ms, RSS 15 MiB** (the blocking transport
uses 212 MiB — the difference is the per-connection thread stacks).

The blocking transport is the portable fallback (one thread per
connection) and is also what `--transport blocking` selects.

The **kqueue** backend (macOS/BSD) is implemented, lifecycle-reviewed
(map-authority close, retained slots, flush wakeups so ticker output
never stalls, working stop()), and compiles for the Darwin target —
but this box is Linux, so it still has no runtime coverage. The
**IOCP** backend (Windows, `src/net/iocp.zig`: one completion port,
worker completion loops, blocking acceptor thread, same Handler
contract) is in the same position: implemented, cross-compiled for
`x86_64-windows`, pure parts unit-tested on every target, runtime
needs Windows hardware. Two known v1 limits: IOCP conns carry no peer
IP (`ip_len == 0`, so IP bans don't match them), and pre-existing
`--transport blocking` remains the documented fallback on both
(one thread per connection).

### Storage profiles

`--storage-profile` picks the LSM tuning; `auto` detects rotational
storage on Linux (sysfs) and otherwise keeps today's defaults:

- `hdd` — big SSTs (8 MiB flush), rare compactions (12 runs), batched WAL
  syncs: seeks are the bottleneck, so move as few bytes as possible.
- `ssd` — today's defaults (4 MiB flush, compact at 8 runs).
- `nvme` — small SSTs (1 MiB flush), frequent small compactions (4 runs),
  SST reads through io_uring (registered buffers + fixed files), parallel
  cross-shard compaction. Measured `zig build bench` (ReleaseFast):
  gets **572 µs → 85 µs (6.7×)** on 2 MB strides, 640/640 reads through
  the ring with 0 fallbacks; compaction 22 ms per 4 MiB merged.

The ring is best-effort: a kernel that refuses io_uring still serves,
on plain pread (the stats line keeps working, `sp=` shows the profile).

### Region threading

`--region-threads` (default: cpu count, max 8; `1` = sequential legacy
path) runs the per-viewer tick in Folia-style 32x32-chunk regions:
viewers file into region groups, groups run on a persistent pool of
stable workers (pinned once; a generation barrier replaces the join —
time/weather publish through atomics only, never a world lock), and
the merge folds worker outputs in group order (deterministic for a
given grouping). Fork-join survives as the fallback (pool creation
failure, non-Linux). Mobs are owned by regions: border crossings push
full-state `Transfer`s, the next tick's drain adopts into the target
and deletes the source (delete-at-drain: every snapshot holds exactly
one copy, attacks never miss; a mid-flight kill drops the transfer).
Player crossings still feed the per-region census + shed load signal.

A per-region circuit breaker degrades hot regions only: 3 straight ticks
with p99 over 15 ms sheds that region (players-only reconcile, no
furnace-window resync) until 5 straight cool ticks recover it; entries
show as `region_shed=` in the stats line. Measured `zig build bench`
(ReleaseFast, 8 regions x 200 viewers x 2000 entities): **5.63×** over
the sequential engine with identical checksums (pool matches fork-join
there); on near-empty ticks the pool does **3.0µs vs fork-join's
1317µs** — per-tick spawn costs ~150µs/worker here, which is why the
pool exists. Workers pin to CCX-grouped cores (big cores first on
big.LITTLE); pinning is advisory and never affects correctness. Item
entities stay global (merge + magnet pickup are cross-region pair
interactions — partitioning them needs a halo protocol).

### Config file

Copy `asteorite.example.json` to `asteorite.json` (or pass `-c <path>`).
Every key is optional; anything the CLI sets wins over the file:

```json
{
  "port": 25565,
  "online": false,
  "db": "world",
  "view_distance": 8,
  "seed": 42,
  "gen_spawn": 4,
  "gen_workers": 4,
  "ops": ["alice"],
  "rcon_password": null,
  "rcon_port": 25575,
  "motd": "Asteorite",
  "max_players": 20,
  "brand": "vanilla",
  "transport": "auto",
  "out_cap_bytes": 4194304,
  "send_zc_threshold": 8192,
  "storage_profile": "auto"
}
```

### Seeds

The world seed is set with `"seed"` in `asteorite.json` (there is no
`--seed` flag). Seeds are full signed **int64** — every numeric Minecraft
seed works,
including negatives and the whole 19-digit range (`-2^63..2^63-1`).
Non-numeric strings hash with Java `String.hashCode`, exactly like typing
text into the vanilla seed field (`"Notch"` → `75456088`). Quoted numeric
strings parse as integers (decimal, `0x` hex, `0o` octal); over-long ones
fall back to hashing, like vanilla's `Long.parseLong` catch path. Bare
JSON floats and integers outside int64 are rejected at startup.

### Brands

The `brand` option controls what the server advertises in the server-list
handshake:

- `vanilla` — exact 1.7.10 shape, no extras.
- `fabric` — byte-identical to vanilla on the wire today (no 1.7.10-era
  Fabric marker exists); reserved for the modding API.
- `forge` — adds the FML block
  `"modinfo":{"type":"FML","modList":[...]}` (empty until the modding API
  registers mods with versions).

## Tools

Built alongside the server (`zig-out/bin/`):

| Command | Purpose |
|---|---|
| `zig build dump -- region/r.0.0.mca` | inspect an Anvil region file |
| `zig build import -- <region.mca> <db> [dim] [shards]` | migrate Anvil → LSM db |
| `zig build wgen -- <seed> <x> <z> [count]` | dump generated chunks for a seed |
| `zig build genlayer -- <seed> <x> <z> <w> <h> [--all]` | dump biome GenLayers |
| `zig build check -- <db>` | verify an LSM db (WAL CRCs, SSTs, MANIFEST) |
| `zig build player-import -- <player.dat> <db> <name>` | import a vanilla player.dat |
| `zig build player-dump -- <db> <name>` | inspect one stored player row |
| `zig-out/bin/seed_dump [seed]` | GenLayer chain seeds (default 1) |
| `zig-out/bin/gen_bench [seed] [x] [z]` | worldgen benchmark |

## Server commands

In-game, console, and RCON share one implementation: `src/cmd/` holds one
file per command (`list.zig`, `give.zig`, …) plus `mod.zig`, the builder
API, and `spec.zig`, the spec framework. Each file declares a validated
`def` — name, permission node, minimum op level, aliases, and a **spec**
(list of typed overloads). Usage strings, argument parsing, and
tab-completion candidates are all *derived from the spec*, so the three
can never drift apart; `define()` renders the usage at comptime (with
`usage_override` only for the few vanilla texts the generator can't
spell). `sim/permissions.zig` builds its permission table from the same
defs, in the vanilla dedicated-server registration order.

The full vanilla 1.7.10 dedicated roster is implemented (48 commands):
time, gamemode, difficulty, defaultgamemode, kill, toggledownfall,
weather, xp, tp, give, effect, enchant, me, seed, help (`?`), debug,
tell (`w`, `msg`), say, spawnpoint, setworldspawn, gamerule, clear,
testfor, spreadplayers, playsound, scoreboard, achievement, summon,
setblock, testforblock, tellraw, op, deop, stop, save-all, save-off,
save-on, ban-ip, pardon-ip, ban, banlist, pardon, kick, list, whitelist,
setidletimeout, netstat, publish — plus the server extension `perm`.

Tab-completion follows the jar: `/`-prefixed command/argument candidates
(case-insensitive, permission-filtered, aliases included, per-command
dynamic sets for items/blocks/mobs/gamerules/enchants), bare-text
player-name completion otherwise, and no response for unknown commands.
Argument shapes mirror vanilla (overloads, `~` coordinates, selectors
`@p`/`@r`/`@a`, vanilla range messages), and admin feedback goes to
fellow ops as gray-italic `[Server: …]` like the dedicated server.

To add a command: copy `src/cmd/stop.zig`, give it a `def` + `run`,
register the module in `sim/permissions.zig`'s `modules` list, and add
tests. Commands stay version-agnostic — anything protocol-specific
(packet framing, wire ids, chunk streaming) goes through the backend
methods on `Server` documented at the top of `src/cmd/mod.zig`, so a
future protocol version reuses every command file unchanged.

## Development

```sh
zig build test              # full suite (must stay green)
python3 tools/traffic_bot.py [host] [port] [username]  # load bot: login, walk, keepalive
```

The `traffic_bot.py` bot exercises login, chunk streaming and keepalive
against a running server — the same harness used for live verification.

## Logo & branding

The mark is a burning asteroid on a fire trail: *Asteorite* = *asteroid* + *mite*.
Assets live in `assets/brand/`.

| File | Use |
|---|---|
| `assets/brand/logo.png` (1200) | Primary lockup, dark badge — README, splash screen |
| `assets/brand/logo-512.png` | Primary lockup, 512×512 |
| `assets/brand/logo.svg` | Vector, **type as paths** — ship this one |
| `assets/brand/logo-light.png` | Lockup for white/light backgrounds (transparent) |
| `assets/brand/logo-light.svg` | Light lockup, type as paths |
| `assets/brand/logo-sans.png` / `logo-sans.svg` | Alternative with an all-sans wordmark |
| `assets/brand/logo-square.png` / `logo-square.svg` | Same lockup, **square** background (no rounded corners) |
| `assets/brand/avatar-1200.png` | **GitHub org avatar** — square background, mark only, circle-crop safe |
| `assets/brand/avatar-512.png` / `avatar-256.png` | Avatar at smaller sizes |
| `assets/brand/avatar.svg` | Avatar, vector |
| `assets/brand/mark.png` (512) | Asteroid + flame alone, transparent — server icon, avatar |
| `assets/brand/mark-256/64/32.png` | Favicons |
| `assets/brand/mark.svg` | Mark, vector |
| `assets/brand/BRANDING.md` | Palette, type spec, design rationale |

Wordmark: **Noto Sans Black** (104 pt, tracking 50/1000 em). The "MC" tag is
**Monocraft Black** — a faithful recreation of Minecraft's own font, installed at
`~/.local/share/fonts/monocraft/` (OFL-1.1). Two letters can be monospaced without
looking typewritten; a nine-letter wordmark cannot, which is why the pixel face is
only used on the "MC".

Use the `logo.svg` / `logo-square.svg` / `avatar.svg` variants (type as paths) for
anything you ship — the `*-live-text.svg` files need Noto Sans Black and Monocraft
installed to render correctly.

### The org avatar

GitHub renders org avatars as a **circle** in most of the UI, so `avatar-*.png` is
composed for that crop rather than for the square: the asteroid is scaled up so its
farthest point sits at radius 536 of the 600 pt circle (64 pt of margin), and the
flame deliberately exits the lower-left of the circle — the crop edge becomes the end
of the trail instead of a cut. Verified by compositing the 512 asset against a
circular mask.

`logo-square.png` is the same lockup on a full-bleed square background, for anywhere
that wants sharp corners (GitHub's org banner area, marketplace tiles, README headers).
