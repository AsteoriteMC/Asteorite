# 1.7.10 parity coverage

Live areas run via `tools/parity/parity.py run`. Statuses: green (in CI
gate), gap (pipeline-found, tracked with evidence), todo (no harness yet).

## T0 live oracle (green)

- `rng` — `java.util.Random` vs `worldgen_dump` fresh-stream draws
  (8 seeds incl. INT64 extremes + live seed). Exact ints, epsilon floats.
- `registry-blocks` — `BlockIdDump` (server jar) wire-id set vs
  `wire_ids.toWire` over `ids.zig` (independent reimplementation).
- `registry-biomes` — `BiomeDump` (all 256 slots) vs `biome.zig`
  names + `biomeExists` registered set (incl. the 161 dup-slot quirk).
- `genlayer` — `LayerProbe.initializeAllBiomeGenerators` roots vs
  `genlayer_dump` (9 cases incl. the live savanna window). Compares the
  first w*h cells: vanilla returns an oversized reuse buffer.

## P1 gaps (pipeline-found, with evidence)

- **Mutated-biome table data**: `biomeExists` + `HEIGHTS` know the M
  variants but the main biome table has no M entries (surface/temp for
  129+ falls back to plains). Found by `registry-biomes`
  (oracle lists 60 real biomes, we document 40). Needs surface rules
  per M variant + golden re-pins.
- **River-chain 2-cell divergence**: `genlayer` case `1 80 -48 16 16`
  at river_mix scale shows vanilla=164 (Savanna M via river claim)
  where we emit 36 — our river chain says no-river where vanilla says
  river. Isolated to 2/256 cells; needs `AxrDump` parent tracing.
- **Voronoi reappeared in gen wiring**: `gen.zig:620,878` and
  `shaper.zig:269` read `roots[1]` (voronoi) for chunk biomes,
  decorate runs, and surface columns, with a comment asserting voronoi
  is correct. The full-res fix (jar-verified: `aqz` uses genBiomes
  everywhere) is not in effect on those paths. Pending owner decision
  (active refactor area — not touched by the pipeline).

## Fixed by the pipeline (this round)

- **Hills gate used the river marker, vanilla uses the lake marker**
  (`genlayer.zig` mixEarly): `(v11-2)%29==0` per `axr` bytecode, plus
  the lake-mutated +128 fallback with similarity-vote fallthrough,
  dropped the non-vanilla `v10 != 0` river-claim guard, deepOcean now
  falls through to the vote. Evidence: jungle blob (156 cells 21 vs 22),
  `ChainDbg`/`AxrDump`/`Roll` oracles in `oracles/debug/`, `axr.txt`
 /`axv.txt` disassembly in `oracles/notes/`. Verified: `genlayer`
  9/9 live-agree after the fix.
- **Biome comment names** now match vanilla exactly (`Ice Plains`,
  `Deep Ocean`, … — 18 fixes, comment-only, no behavior change).

## T1 pinned (in-tree goldens, jar-cited, no live oracle yet)

Full-pipeline CRCs, mesa surface, ZC1 pack, roofed grid, dark-oak grid,
redstone sim goldens (16/16), drops bounds/rates, furnace 20-tick
quanta, enchanting offers, explosion craters, brewing chains. Next step:
promote each to T0 with an oracle + corpus (rescued sources in
`oracles/{vgold,verify,smoke,mcscan,vdump}` cover trees, decor, carve,
lakes, structures, registries, packets, crypto).

## Todo areas (no harness yet)

Noise stacks, surface builder, tree/decor shapes, carve geometry,
structure placement, drops tables, recipe matcher, redstone components,
packet codecs, slot/NBT, player rows, anvil import, lighting, mob
spawning. Rescued oracle sources exist for most; each needs a corpus +
adapter + `expected/` per the README recipe.
