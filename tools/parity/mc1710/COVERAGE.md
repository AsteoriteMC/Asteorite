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
  `genlayer_dump` (13 cases incl. the live savanna window and M-rich
  windows: seed 7 Flower Forest + Birch M, seed 21 +129, seed 9
  Sunflower Plains). Compares the first w*h cells: vanilla returns an
  oversized reuse buffer.
- `chunk` — `ChunkOracle` (real `aqz` base fill + surface replacement
  per chunk) vs `chunk_dump` (8 cases: plains, taiga, mesa x2, jungle,
  savanna, M-rich, live-seed savanna). Compares base/surface CRCs +
  histograms + corner/population biome ids. Carve excluded (ours is
  caves-only); the oracle harness must seed the provider rand exactly
  like `aqz.d` (a missing `setSeed` once faked a 400-cell divergence).

## P1 gaps (pipeline-found, with evidence)

- **Mutated-biome decorator data (OPEN — precise spec, `decor.zig`
  is foreign WIP so no code touched)**. Surface tables are complete
  (`TOP256`/`FILLER256`/`TEMPF256`/`HEIGHTS` all carry 21 explicit M
  entries; mesa family handled). The gap is decorator counts, pinned in
  `oracles/notes/decorator-counts.txt` (`DecoFields` oracle):
  - Barren M (own class, fresh default decorator — trees=0):
    130,133,134,149,151,155,156,157,158 get `{trees=0, flowers=2,
    grass=1, rest 0, E=1, F=3}`. The `+128`-strip gives them base flora
    (e.g. 149 grows jungle giants, vanilla grows none).
  - 132 Flower Forest (`aif`, own config): `{trees=6, flowers=100,
    grass=1}` vs stripped forest `{10,2,2}`.
  - 163/164 Savanna M (`ait`, own config): `{trees=2, flowers=2,
    grass=5}` vs stripped savanna `{1,4,20}`.
  - 129 Sunflower Plains: identical to plains (strip correct, no change).
  - Swamp disks: vanilla `F=sand` / `E=clay` loops give swamp
    `{sand=3, clay=0}` (`E=0`, `F=3` in `DecoFields`); our swamp
    `{sand=0, clay=1}` is inverted on both fields (RNG draws shift even
    where attempts fizzle). SwamplandM (134) `E=1` matches default clay.
  - Chain side (shore/smooth/rareBiome) verified live on M ground
    (above), so `isJungle`/`isMesa`/`isSnowy` need no change on observed
    behavior.
  - Next step: promote rescued `vgold/Dec*` oracles to a T0 decor area;
    that is the mechanism that will verify any decor-side fix.
- **River-chain 2-cell divergence (CLOSED 2026-10-30 — same lake-flag
  root cause)**: looked like a river-chain split, but both river parents
  are 92077 (lake marker); the cells needed the lake-mutated fallback
  (`35 -> 36 -> 164`), which the old river-gated code skipped. Post-fix
  L25-vs-axr shows 0/256 diffs.
- **Voronoi site-selection (ADJUDICATED 2026-10-30 — other agent correct)**:
  vanilla `aqz.d` surface, chunk biome array, populate run biome, and
  snow all resolve through the chunk cache (`aib.b` / `apx.a` lazy fill /
  `ahb.a(II)` / `ahb.r|e`), whose blocks fill once from the voronoi
  `d`-layer (`ahz` ctor via 6-arg `false`; verified in `aqz`/`aib`/
  `ahy`/`ahz`/`apx` bytecode). Only the density blend uses full-res
  (`aib.a` 5-arg, field `c`). The e40e9a7/46fda38 full-res claims for
  surface/chunk/decorate were wrong (misattributed which `aib` method
  each site calls); the workdir state (roots[1] at `gen.zig:620,878`,
  `shaper.zig:269`) matches vanilla. Remaining: `decorateCenter`
  comments still claim full-res (stale, owner's cleanup).
- **Mixed-leaf symptom, re-explained (CLOSED 2026-10-30)**: the old
  code read the run biome at chunk CENTER+8; vanilla `aqz.populate`
  reads `ahb.a(cx*16+16, cz*16+16)` (corner, verified above). In the
  4x4-quantized voronoi field these disagree in ~25% of chunks
  (measured on a 961-chunk L1 window), selecting wrong-kind neighbor
  runs at borders (birch/spruce decor inside swamp chunks, stranded
  vine columns) — compounded by the pre-0881c10 merge smearing
  trunk/leaf metas across the 3x3 view. The full-res layer switch was
  not the active ingredient: the corner+16 sample point (kept) plus
  the whole-cell merge fix account for the cure. Verified: a 9-chunk
  `genChunk` scan over a canopy/oak/spruce border zone finds 0
  foreign-kind trunks/leaves and 0 off-biome vines (scratch harness,
  removed after use).

## Fixed by the pipeline (this round)

- **Hills gate used the river marker, vanilla uses the lake marker**
  (`genlayer.zig` mixEarly): `(v11-2)%29==0` per `axr` bytecode, plus
  the lake-mutated +128 fallback with similarity-vote fallthrough,
  dropped the non-vanilla `v10 != 0` river-claim guard, deepOcean now
  falls through to the vote. Evidence: jungle blob (156 cells 21 vs 22),
  `ChainDbg`/`AxrDump`/`Roll` oracles in `oracles/debug/`, `axr.txt`
 /`axv.txt` disassembly in `oracles/notes/`. Verified: `genlayer`
  13/13 live-agree after the fix.
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

Noise stacks, surface builder, tree/decor shapes, carve geometry (note:
our carver is caves-only until ravines land — a chunk-area carve stage
waits on that), structure placement, drops tables, recipe matcher, redstone components,
packet codecs, slot/NBT, player rows, anvil import, lighting, mob
spawning. Rescued oracle sources exist for most; each needs a corpus +
adapter + `expected/` per the README recipe.
