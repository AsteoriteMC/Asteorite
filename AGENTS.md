# AGENTS.md — Asteorite coding guidelines

All agents and contributors follow this file. Correctness and byte-exact vanilla parity outrank brevity.

## 1. Shared vs versioned code (strict)

- Reusable mechanisms live in shared code: `src/sim/`, `src/game/` (rules, block/mob engines), `src/world/`, `src/cmd/`, `src/net/`, `src/worldgen/pipeline.zig`, `src/worldgen/rng/`.
- Versioned code holds only data and wire behavior: `src/game/mc5/*_data.zig`, `src/proto/v5/`, `src/worldgen/v5/`, `src/versions/mc*.zig`, `-Dmc` profile selection in `build.zig`.
- Never branch shared engines on version. Pass profile data in (`BlockDef`, `RedstoneRules`, drop/recipe/potion tables, wire-id maps).
- `src/sim/**`, `src/world/**`, `src/cmd/**` must not `@import` any `proto/*` path. Exception: `src/world/import/**` (migration only). Enforced by `zig build check-imports` (`src/import_gate.zig`).

## 2. Function depth: max 2 control-flow levels

- Counts: `if` / `for` / `while` / `switch` / `catch` nesting inside one function body. Call chains and boolean expressions do not count.
- Past depth 2, extract a helper. Prefer early returns/continues over nesting.
- Helpers get behavior-revealing names (`canPush`, `settleFluid`, `primePoweredTnt`), one job each.

## 3. No duplicated code

- Do not copy-paste blocks, tables, or formulas. Second use = extract to a shared helper, comptime function, or data table.
- One source of truth per fact: wire ids in `wire_ids.zig`, block behavior in `game/mc5/blocks.zig`, drops/recipes/potions in their `*_data.zig`.
- For jar ports, cite the class/method (e.g. `ask`, `aqz.populate`) once at the port site; callers reference the port, not the jar.

## 4. Dead code cleanup (best effort, reviewers verify)

- When uses are removed, remove the now-dead helper/table/branch in the same change. No commented-out code, no unused parameters, no orphan tests.
- If a follow-up genuinely reuses it within the same task, say so in the commit message; otherwise delete. Re-adding later is cheap.
- Keep `TODO.md` honest: check boxes only for shipped + verified work.

## 5. Optimized algorithms (strict, measured)

- Pick the asymptotically better algorithm for the job; no O(n²) where O(n log n)/O(n)/O(1) exists, no repeated scans inside tick/gen/store hot paths.
- Budgets are load-bearing: per-tick drain caps, region breaker accounting, gen worker counts, store read caps. Do not bypass them; wire new tick work into the existing budget discipline.
- Performance claims need numbers: `zig build bench`, tick p50/p99, pregen chunks/s, or store round-trip timings. Full LTO is banned for builds (OOM); deploy uses thin LTO.

## 6. Verification gate

- `zig build test` green (plus `check-imports` and `test-exploit`) before commit, push, or any deploy. Flakes get re-run from a clean worktree, never hand-waved.
- Gameplay-affecting changes (net, sim, worldgen, drops, redstone, explosions, persistence) also need live E2E over TCP with a real 1.7.10 client before deploy.
- Preserve JVM goldens. If vanilla proves an old golden wrong (jar bytecode/disassembly), re-pin with the jar citation and fresh histograms in the test comment.

## 8. Naming conventions

- Files/dirs: `snake_case.zig` matching module role (`redstone/`, `worldgen/v5/`, `game/mc5/*_data.zig`). Co-located tests use `*_tests.zig` or inline `test` blocks; no separate test dirs.
- Types: `PascalCase` (`WorldView`, `BlockDef`, `FallSpawn`, `GolemKind`). Enum/union members: `snake_case` (`air`, `lit_furnace`, `placed`).
- Functions/variables: `camelCase` (`placeSound`, `genChunk`, `markDirty`, `normalCube`). Predicates: `is`/`has`/`can`/`should` prefix returning `bool` (`isWire`, `canPush`, `shouldDropBreak`).
- Constants: `SCREAMING_SNAKE_CASE` (`COUNT`, `MAX_LOG_LINES`, `Q_PER_CHUNK`, `WILD`). Module aliases: `snake_case` (`java_random`, `carve_mod`, `block_mod`).
- No single-letter names except loop indices and coordinates (`x`, `y`, `z`, `i`). No new abbreviations: spell out (`meta`, `pos`, `dir` allowed; jar names like `ask`/`aqz` only in port citations, never as identifiers).
- Tests: sentence-style behavior names (`test "slot roundtrip incl NBT bytes"`), never `test1`/`test_foo`.
- Jar ports keep vanilla semantics in the name (`weak`/`strong`/`indirect`/`gettingPowered` for `ahb` power); document the obfuscated source once in the module doc comment.

## 7. Deploy recipe (`~/asteorite-test`)

- Build: `zig build -Doptimize=ReleaseFast -Dstrip -Dlto=thin` (exit 0, `--version` smoke check).
- Back up the live binary to `asteorite.bak-<timestamp>`, `install -m 755` the new one into `~/asteorite-test`. Do NOT restart the server — the owner restarts it.
- Cache: `tools/prune-cache.sh --dry-run` first, then run for real when `.zig-cache` exceeds 20 GB. Never delete entries younger than the 120-min guard.
