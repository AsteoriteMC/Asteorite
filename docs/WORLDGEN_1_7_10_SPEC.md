1.7.10 world-generation conformance spec (Asteorite `mc5` profile).

Purpose: pin EVERY stage of the 1.7.10 overworld pipeline to vanilla
behavior so that "server terrain != singleplayer terrain for the same
seed" reports can be triaged against a checklist instead of folklore.

Origin: full audit of `src/worldgen/v5/*`, `src/worldgen/rng/*`,
seed plumbing (`src/config.zig`, `src/main.zig`), and the serve path
(`src/sim/world/view/burst.zig`, `src/world/store.zig`), prompted by:
standing on a snow mountain at block (247,127,708) on the server while
the same coords in a singleplayer world with (allegedly) the same seed
is ocean. Block (247,708) is chunk (15,44), local (7,4).

How to use this file: each stage lists INPUTS, VANILLA REFERENCE,
IMPLEMENTATION (file:line), RNG ACCOUNTING, STATUS, and DIVERGENCE RISK
for the ocean-vs-mountain symptom class (base-terrain mismatch, i.e.
biome field or density field differs — populate/carve/structures cannot
produce a y=127 mountain <-> ocean flip).

## S0. Symptom triage (2026-10-25): snow mountain vs ocean at (247,708)

VERDICT (2026-10-25, seed -3755478573795537924): OUR CODE IS CORRECT AT
THIS WINDOW. A vanilla-jar oracle (LayerProbe harness, real
`axn.a(seed, DEFAULT)` GenLayers from minecraft-1.7.10-unsigned.jar)
returns byte-identical biome windows to our Chain:

- final_mix @ (58,174) 10x10: vanilla = uniform 140, ours = uniform 140
- voronoi   @ (58,174) 10x10: vanilla = uniform 24,  ours = uniform 24
- 3rd root  @ (58,174) 10x10: vanilla = uniform 140, ours = uniform 140

140 = Ice Plains Spikes (mutated ice plains): a snow-mountain biome.
Density inputs are therefore vanilla-identical; density math is golden-
pinned (S5.3); octave permutations are seed-global and pinned (S4.5).
By composition our base terrain at chunk (15,44) == vanilla's: mountain
~y125 with snow (our genChunk: height=125, snow@126, biome 140 — exactly
the reported server observation). A same-seed DEFAULT 1.7.10 singleplayer
MUST show spikes there too. The "ocean" comes from the comparison setup,
not our generator — prime suspects: singleplayer client is NOT 1.7.10
(modern versions reuse numeric seeds with a different generator — same
seed, different world), a mistyped seed digit, or non-DEFAULT world type.
See D1.

Symptom class determines the suspect set. A y≈127 snow mountain vs ocean
(sea level 63) is a BASE-TERRAIN mismatch: the biome height blend or the
density/noise field differs at chunk (15,44) — or the two worlds run
different seeds / world types / coordinates.

Ruled OUT by inspection (cannot flip mountain<->ocean):
- populate/decorate (ores/trees/flowers/lakes/dungeons/springs/snow tail
  only add or carve small holes; lakes max ~6r holes to bedrock, never a
  64-block ocean fill). src/worldgen/v5/decor.zig:populateOne.
- caves (carve only stone/dirt/grass, never fill ocean).
  src/worldgen/v5/carve.zig.
- structures (villages/mineshafts/strongholds add blocks; village ground
  fill is ±a few blocks). Placement is not even implemented yet (S8).
- chunk serve coordinates (no x/z swap: store key, view spiral, bulk
  columns all carry x,z straight through — S10).
- snow-tail support gate (post-process on top of terrain; S9).

Ruled IN (can flip mountain<->ocean), ranked:
1. SEED MISMATCH (most common, zero code involved). Server seed comes
   from the config-file `"seed"` key only (no --seed flag). Singleplayer
   comparison must use the identical i64. String seeds hash with Java
   hashCode; typing the hash digits vs the string gives different worlds.
   MUST be excluded first — see diagnostic procedure D1.
2. WORLD-TYPE MISMATCH. Server hardcodes DEFAULT (large_biomes=false,
   amplified=false at src/main.zig + genpool create). A singleplayer
   LARGE_BIOMES or AMPLIFIED world with the same seed is a different
   world. MUST be excluded — see D1.
3. FAR-FIELD GenLayer divergence. Goldens pin only near-origin windows
   (8x8 at 0,0 for seeds 1/42; S3). A coordinate bug that is identity
   near origin but wrong far away (sign handling in zoom/voronoi parent
   origins, IntCache-equivalent windowing) would pass all goldens and
   flip continents at (15,44). Prime suspect if seed/type match.
4. FAR-FIELD density/noise divergence (octave permutation order,
   biome-array origin). Same argument as (3); density goldens pin only
   chunks (0,0),(3,-5),(-7,11),(10,10),(5,-3),(0,1),(8,8) — none near
   (15,44). Prime suspect if seed/type match.
5. Stale/corrupt chunk in the server LSM (old seed's chunk served for
   new seed; pre-gen from a previous seed). Operational, not code.
6. Ravines disabled / structures unplaced: real deviations (S7/S8) but
   CANNOT explain mountain<->ocean. Do not chase for this symptom.

What I need to close this out: the exact `"seed"` value from your server
config + confirmation the singleplayer world used that exact numeric seed
with World Type DEFAULT, structures ON/OFF noted. Then run D2.

## S1. Pipeline order and files

Vanilla 1.7.10 ChunkProviderGenerate.provideChunk + populate order:
  1. density field q[5*33*5] from GenLayer biome array + octave stacks
  2. trilinear fill -> stone/water/air (sea level 63)
  3. surface builder (ahu.b per column: bedrock, top/filler, freeze)
  4. cave + ravine carvers (MapGenCaves/MapGenRavine, 17x17 neighborhood)
  5. structure generators (villages/mineshafts/strongholds/scattered)
  6. populate: seed mix -> structure gen -> lakes -> dungeons ->
     biome.decorate (ores/disks/trees/flora/springs) -> snow/ice tail
  7. lighting + heightmap + voronoi biomes per column

Implementation mapping (all under src/worldgen/v5/, rng in
src/worldgen/rng/):
  gen.zig:Gen.genFlat      = stages 1-4 (density, fill, surface, carve)
  gen.zig:Gen.genChunk     = genFlat + decorateInto (stage 6 on a 3x3
                             merge) + light + heightmap + voronoi biomes
  gen.zig:Gen.decorateInto = 9x genFlat into 48x48 view, decorateCenter,
                             extract center, post-merge snow sweep
  shaper.zig:Shaper        = stages 1-3 (densityField, fillChunk,
                             surfaceChunk) + octave/chain ownership
  carve.zig:Carver         = stage 4 (caves ON, ravines OFF — see S7)
  decor.zig                = stage 6 (seedForChunk, populateOne,
                             decorateCenter 3x3 merge, snow tail)
  struct/*                 = stage 5 (detection ported, placement partial)
  noise.zig                = ImprovedNoise/Octaves/Simplex/SimplexOctaves
  genlayer.zig:Chain       = full GenLayer graph (S3)
  biome.zig                = biome tables (S3.5)
  surface.zig              = buildColumn + MesaState (S6)
  serve.zig/genpool.zig    = getOrGen, worker pool, spawn, pregen

NOTE: src/worldgen/pipeline.zig (GenCtx/StageId) is a version-neutral
scaffold with stub stages — NOT the live path. The live path is Gen.

## S2. Seed plumbing spec

### S2.1 Canonical rule. The world seed is ONE i64 threaded everywhere.
  - Java long semantics: full -2^63..2^63-1 range round-trips exactly.
  - Server source of truth: config-file `"seed"` ONLY. There is no
    --seed flag (src/cli.zig rejects --seed; help text states config-only).
  - Resolution: src/config.zig:FileConfig.resolveSeed — JSON integer used
    verbatim; JSON string parsed as integer (decimal/0x/0o) else Java
    String.hashCode sign-extended to i64 (parseSeedString); float or other
    types are hard errors; missing/null = no worldgen at all.
  - Wiring: src/main.zig reads eff.seed -> Gen.init(salloc, s, false,
    false) + GenPool.create(..., s, false, false, n). Both large_biomes
    and amplified are HARDCODED false (DEFAULT world type). No flag, no
    config key, no generatorOptions string exists anywhere in src/.
  - Fan-out from the single seed (must all match vanilla):
    a. Shaper octave stacks share ONE JavaRandom(world_seed), drawn in
       fixed constructor order (S4).
    b. GenLayer Chain.buildDefault(world_seed) + initVanilla quirk (S3).
    c. Surface per-chunk Random(cx*341873128712 + cz*132897987541) (S6).
    d. Carver per-neighbor reseed from two nextLongs of Random(seed) (S7).
    e. Populate seedForChunk mix (S9).
    f. MesaState uses its OWN Random(world_seed) streams (S6) — must not
       interleave with (a).
    g. TempEval uses its OWN Random(1234) (S6) — world-independent.

### S2.2 Singleplayer-comparison protocol (D1 — do this FIRST on any report).
  1. Read the exact integer from the server config + startup log line
     ("seed={?d}"). Beware: if config held a STRING seed, the effective
     seed is its hash, not the string.
  2. Singleplayer world MUST be: same numeric seed, World Type DEFAULT
     (not Large Biomes, not Amplified), same MC version 1.7.10.
  3. Structures ON vs server: server does not place structures yet (S8),
     so village/hut presence differs by design — compare BASE TERRAIN
     (F3 biome + height), not structures.
  4. Delete/verify: server LSM must not contain chunks from a previous
     seed (wipe world dir or confirm fresh pregen after seed change).
  5. /tp uses BLOCK coords; chunk = floorDiv(block,16). (247,708) =
     chunk (15,44) local (7,4). Confirm no ~N-block offset confusion
     (e.g. comparing 247,708 against 708,247).

## S3. GenLayer chain spec (biome field — suspect #1 for ocean<->mountain)

### S3.1 Construction (genlayer.zig:Chain.buildDefault, lines ~215-290).
Vanilla 1.7.10 axn.a(seed, WorldType.DEFAULT) equivalent. Exact layer
list in order with (kind, seed):
  island(1) -> fuzzy_zoom(2000) -> add_island(1) -> zoom(2001) ->
  add_island(2) -> add_island(50) -> add_island(70) ->
  remove_too_much_ocean(2) -> add_snow(2) -> add_island(3) ->
  edge_cool_warm(2) -> edge_heat_ice(2) -> edge_special(3) ->
  zoom(2002) -> zoom(2003) -> add_island(4) -> mushroom_island(5) ->
  deep_ocean(4) [=deep]
  river branch: magnify(deep,1000,0)=deep -> river_init(100)
  biome branch: magnify(deep,1000,0)=deep -> biome(200) [warm/cool tables
    per large_biomes flag] -> magnify(1000,2) -> biome_edge(1000) [=bio]
  hills mix: river2=magnify(river,1000,2); mixed=river_mix(1000,bio,river2)
  scaled river: r3=magnify(river,1000,2) -> magnify(1000,4 or 6) ->
    river(1) -> smooth(1000) [=r3]
  hills: rare_biome(1001,mixed) -> 4 (or 6) x [zoom(1000+qi),
    +add_island(3) after qi==0, +shore(1000) after qi==1] ->
    smooth(1000) [=hills]
  final_mix=river_mix2(100,hills,r3); voronoi=voronoi_zoom(10,final_mix)
  roots = [final_mix, voronoi, final_mix].
Consumers: densityField samples roots[0] (final_mix) at (cx*4-2,cz*4-2,
10x10); surfaceChunk samples roots[1] (voronoi) at (cx*16,cz*16,16x16);
genChunk biomes sample roots[1] 16x16; snow tail samples roots[1] 48x48.

### S3.2 initWorldGenSeed quirk (lines ~292-310). initVanilla recurses from
the voronoi root following SINGLE parents, EXCEPT river_mix2 (axv) which
visits both. river_mix (axr) has NO override in the jar, so its river-side
zooms (layers 23,24) keep baseSeed 0 — replicated deliberately and pinned
by test "vanilla init quirk". If this quirk regresses, ALL downstream
chunkSeeds shift -> global continent reshuffle (would fail origin
goldens too, so currently pinned).

### S3.3 Per-layer RNG rules (each cell inits chunkSeed at its own coords):
  island: nextInt(10)==0 -> 1 else 0; force (0,0)=1 if window covers it.
  zoom/fuzzy_zoom: parent origin (x>>1,z>>1), size (w>>1)+2; per 2x2 cell
    seed ((gx+px)*2,(gz+pz)*2) — multiply AFTER add; picks: SOUTH first
    then EAST (draw order is spec — swapped order desyncs everything);
    diagonal = random (fuzzy) or selectModeOrRandom (normal, exact
    10-condition tie-break chain at selectModeOrRandom); output offset
    (x&1,z&1) via u32-bitcast (negative-safe).
  add_island: ocean cell with any land neighbor -> reservoir-sampled
    neighbor (nextInt(count) chain 1..4), then nextInt(3)==0 to plant
    (plains, or 4 if picked 4); land cell with any ocean neighbor ->
    growRoll (nextInt(5)==0 -> 0, except 4 stays 4).
  remove_too_much_ocean: ocean cell with 4 ocean neighbors ->
    nextInt(2)==0 plants land. (Seeds every cell incl. land cells —
    initChunkSeed runs unconditionally; nextInt only on all-ocean.)
  add_snow: land -> nextInt(6): 0->4(cold), 1->3(ice), else 1.
  edge_cool_warm: 1 with ANY 3/4 neighbor -> 2. edge_heat_ice: 4 with ANY
    1/2 neighbor -> 3. edge_special: non-zero + nextInt(13)==0 tags
    variant bits ((1+nextInt(15))<<8)&3840 (parens exact: & over |).
  mushroom_island: ocean cell with 4 ocean neighbors + nextInt(100)==0
    -> 14.
  deep_ocean: NO RNG. Ocean with 4 ocean neighbors -> 24.
  river_init: parent 1:1; positive -> nextInt(299999)+2 else 0.
  river: NO seeding. riverC(v)= v<2 ? v : 2+(v&1); cell uniform over
    N/E/S/W/center -> -1 else 7.
  river_mix: seeds every cell; mutated +128 rule (only v10<128, only if
    biomeExists(v10+128)); hillsVariant table (desert->17, forest->18,
    birch->28, roofed->1, taiga->19, megataiga->33, coldtaiga->31,
    plains->nextInt(3)?18:4, iceplains->13, jungle->22, ocean->24,
    hills->34, savanna->36, mesa-similar->37, deepOcean 1/3 -> plains/
    forest); similarity gate needs >=3 similar N/E/S/W neighbors.
  biome: 1:1; strips variant bits (&~0xF00 via 0xFFFFF0FF mask, exact
    unsigned); oceanic/mushroom pass through; 1->warm table (or mesa
    38/39 on variant), 2->desert table (or jungle 21), 3->cool table (or
    megataiga 32), 4->icy table, else 14. Tables: warm_default =
    {2,2,2,35,35,1} (LARGE_BIOMES variant differs — server never uses).
  biome_edge: edgeA(3->20: needs areBiomesSimilar(c,3) and ALL neighbors
    edgeSimilar), edgeB(38->37, 39->37, 32->5: exact-id match, neighbors
    areBiomesSimilar), desert-adjacency 2->34, swamp 6 rules, else keep.
    edgeSimilar = areBiomesSimilar OR (both registered AND (temps equal
    OR either MEDIUM — medium is a wildcard)).
  shore: mushroom 14->15 on ocean adjacency; jungle handling (23/16);
    3/34/20->25 stoneBeach, snowy(10,11,12,13,26,30,31)->26 coldBeach,
    mesa 37/38 rules, default land->16 beach on ocean adjacency.
  smooth: seeds ONLY when N==E and S==W (else deterministic pick).
  rare_biome: seeds every cell; nextInt(57)==0 AND c==1 -> 129.
  river_mix2: NO seeding, 1:1 both parents. Ocean/deepOcean pass; river
    7 on icePlains->11 frozenRiver, mushroom->15 shore, else river&0xFF.
  voronoi_zoom: x-=2,z-=2 prologue; parent (xx>>2)+2x2 window; per parent
    cell FOUR reseeds with (gx+px)<<2 arithmetic (<< AFTER +, Java
    precedence); jitter nextInt(1024)/1024-0.5)*3.6 (+4.0 on +x/+z
    candidates); middle candidates masked &0xFF, outer raw (bytecode
    quirk); nearest of 4 wins; output offset (xx&3,zz&3).

### S3.4 areBiomesSimilar (lines ~72-111). Vanilla compares CLASSES, not
temps. Groups: {0,10,24} ocean trio, {2,17} desert, {3,20,34} hills,
{4,18,27,28,29} forest family, {5,19,30,31,32,33} taiga family,
{7,11} river, {12,13} ice, {14,15} mushroom, {16,26} beach,
{21,22,23} jungle, {35,36} savanna, {37,38,39} mesa; all else unique
(38/39 mesa pair special-cased first). Verified by live JVM probing
(e.g. similar(21,3)==false).

### S3.5 Biome tables (biome.zig). HEIGHTS[256] rootHeight/heightVariation
(hex-exact f32 from BiomeDump, incl. mutated +128 variants; fallback
plains). densityField indexes HEIGHTS[(u32)id & 255]. TOP256/FILLER256/
TOPMETA256/TEMPF256 (BiomeAll2 probe). TEMP_F[40] float temps; Temp
categories {ocean,cold,medium,warm} from getTempCategory probing.
STATUS: tables are probe-dumped, high confidence. RISK for (15,44):
a wrong HEIGHTS entry for the local biome shifts height but NOT
ocean<->mountain by itself (ocean comes from biome id 0/24 + depth
blend, not from heights alone).

### S3.6 STATUS / coverage gap. Goldens pin 8x8 final_mix+voronoi at origin
for seeds 1 and 42 only. CLOSED for the reported window: vanilla-jar
oracle (LayerProbe, /tmp/opencode/verify/LayerProbe.java — kept OUT of the
repo with the other temp harnesses) confirms roots[0..2] identical at
(58,174) for seed -3755478573795537924 (see S0 VERDICT). G1/G2 remain open
in general: no permanent far-field goldens are committed; add the (15,44)
windows as goldens to stop this regressing (D2.4).

## S4. Noise spec (suspect #2 for ocean<->mountain)

### S4.1 java.util.Random (rng/java_random.zig). 48-bit LCG (0x5DEECE66D/0xB),
setSeed XORs multiplier; nextInt/nextLong/nextBoolean/nextFloat/
nextDouble/nextBytes/nextGaussian (polar method via strictLog — 1-ulp
sensitive, uses strict_math.zig fdlibm port, NOT libc). nextIntBound
replicates power-of-two fast path + signed-32 rejection loop. Pinned by
OpenJDK goldens (incl. minInt seed, rejection path, gaussian bits).

### S4.2 ImprovedNoise (noise.zig, awj). init: 3 nextDoubles*256 offsets,
Fisher-Yates perm[256] via nextIntBound(256-i)+i, perm mirrored to
[256..512] INSIDE the loop. populate 2D (ySize==1): mixed grad2/grad3
corners (NOT a typo), index-SUM hashes (perm[v]+w, third load perm[sum]).
populate 3D: y-cache STALENESS replicated exactly (recompute x-lerps
only when iy==0 or wrapped y-hash changes; else keep stale grads while
y/z lerps use fresh fy/fz) — "more correct" recompute FAILS goldens.
fade/lerp (a+t*(b-a) order), JLS toIntSat/floorLong saturation.

### S4.3 Octaves (awk). init draws `count` ImprovedNoises sequentially from
ONE shared Random. generate: per octave, floorLong wrap mod 16777216 on
x/z, populate with scales*freq, amplitude=freq, freq/=2 (GROWING
amplitudes 1/freq — golden mean ~3213 confirms direction).

### S4.4 Simplex (awo) + SimplexOctaves (awl). skew/unskew constants bit-exact;
lattice() maps d==0 -> -1 (bytecode dcmpg/ifle); offsets added ONLY in
grid path (X by 1st double, Z by the 2ND — 3rd drawn, unused — do not
"fix"); double perm indirection; grid() per-octave (x_scale*freq*amp,
0.55/amp). TempEval stack = SimplexOctaves(Random(1234),1).

### S4.5 Shaper stack construction (shaper.zig:Shaper.init). ONE shared
Random(world_seed), fixed order: min_s(16) -> max_s(16) -> main_s(8) ->
surf_s simplex(4) -> depth10(10, UNUSED, RNG fidelity) -> depth_s(16)
-> forest8(8, UNUSED, RNG fidelity); parabolic weights 10/sqrt(i²+j²+0.2)
in f32; chain build; TempEval.init; MesaState.init(world_seed) (own
streams — no interleaving with the shared Random).
STATUS: combined density+fill goldens pass (seeds 1,42,12345) — order is
JVM-confirmed at those points. RISK: same far-field caveat as S3.6.

## S5. Density field + fill spec

### S5.1 densityField (shaper.zig ~93-190). Biome array 10x10 from roots[0]
at (cx*4-2, cz*4-2) -> HEIGHTS blend over 5x5 parabolic kernel (amplify
rule if amplified — never on server); depth field g[25] from depth_s at
(cx*4, 10, cz*4, 5x1x5, scales 200/1/200); dd from main_s (8.55515,
4.277575, 8.55515, 5x33x5); e/f from min/max_s (684.412 cube, 5x33x5);
per-column bf/bf2/bf3 blend, d6 depth remap (neg*-0.3, *3-2, /2 /1.4 /2
or /8 branches), d7/d8/d9, per-y d10 ((y-d9)*12*128/256/d8, *4 if neg),
d11/d12/d13 clamped lerp, d14; y>29 taper in F32 ((y-29)/3.0f widened)
toward -10. q[n4], n4 = column-major over 5x5x33.

### S5.2 fillChunk (shaper.zig ~194-242). Trilinear over 4x4x32 cells, 8+4+4
subdivision (0.125/0.25 steps, d16 starts d11-d17 — op order is spec);
block index (fx+i*4)<<12 | (j*4)<<8 | (cy*8+fy), minus 256 (signed wrap),
+256 per z-step; rule: d16>0 -> stone, else y<63 water else air.
SEA_LEVEL = 63 (shaper.zig + gen.zig agree).

### S5.3 STATUS. Density bit-pattern goldens (first ~100 q values as u64)
+ fill stone/water counts + full-array CRC pass for seeds
1@(0,0), 42@(3,-5), 12345@(-7,11). RISK: pins are single chunks;
(15,44) unverified.

## S6. Surface builder spec

### S6.1 surfaceChunk (shaper.zig ~246-291). Stone-noise grid s[256] from
surf_s.grid(cx*16,cz*16,16,16, scales 0.0625, freq 1.0, amp 0.5);
voronoi 16x16 from roots[1]; per-chunk Random(cx*341873128712 +
cz*132897987541) (wrapping +% — Java long overflow); per column (i,j)
dispatches mesa (ids 37/38/39/165/166/167) else buildColumn.

### S6.2 buildColumn (surface.zig ~46-124, ahu.b). depth=(int)(noise/3+3+
nextDouble*0.25) (truncation, not floor); per-y from 255 down, drawing
nextInt(5) EVERY y for bedrock (y<=r5 -> bedrock); air resets filler;
stone branch: first-stone sets top/filler (depth<=0 -> air/stone; y in
59..64 -> biome TOP/FILLER); y<63 & top==air -> freeze check
tempAt<TEMPF)<0.15 -> ice else water; y>=62 places top; y<56-depth ->
gravel; else filler; sand->sandstone transition (nextInt(4)+max(0,y-63)).
TOP/FILLER from TOP256/FILLER256 indexed by FULL biome id (mutated ok).

### S6.3 tempAt (TempEval). y>64: biomeTemp - (simplex(x/8,z/8)*4 + y-64)*
0.05/30 (f64 math, f32 result); else biomeTemp. Stack = own Random(1234).

### S6.4 mesaBuildColumn + MesaState (surface.zig ~129-339, ail). Band layers
from own Random(world_seed) r1 (exact for-continue ++ semantics +
nextBoolean placements); e/f stacks from own Random(world_seed) r2 (4
then 1 octaves); g stack = FIRST octave set built from r1 (order: g,
layers, then r2 e/f — interleaving is spec). band() indexes by Y (+n4
from g simplex on X only, round-half-up via floor(a+0.5)); bryce spires
(id 165) via e/f evals; forest cap (38/166) dirt/coarse above 86+2d.
STATUS: mesa goldens pass (55555 @ -1,-1 and 0,0 incl. meta CRC).

### S6.5 STATUS. Surface CRC goldens pass (same chunks as S5.3 + mesa).
Cannot cause ocean<->mountain beyond ±1-3 surface blocks.

## S7. Carver spec (caves ON, ravines OFF — known deviation)

### S7.1 carveChunk (carve.zig ~75-94, aqx.a). Random(world_seed) ->
l=nextLong, l2=nextLong; 17x17 neighborhood (cx±8); per neighbor seed
(di*%l ^ dj*%l2 ^ seed); reseed, cavesEntry. RAVINES DISABLED (lines
~89-91, "DEBUG: ravines disabled" — reseed+ravineEntry commented out).
DEVIATION #1 (accepted pending phase): vanilla carves ravines (~1/50
per neighbor-chunk trigger); server leaves ravine terrain intact. Small
local holes only — IRRELEVANT to mountain<->ocean.

### S7.2 cavesEntry (aqw): n5 = nextInt(nextInt(nextInt(15)+1)+1); if
nextInt(7)!=0 -> n5=0 (so caves ~1/7 of neighbor triggers); per cave:
start (di*16+nextInt16, nextInt(nextInt(120)+8), dj*16+nextInt16);
1/4 branch into caveWalk (big room, f=1+nextFloat*6) + 1-4 walk13s;
else 1 walk13 (f3=size, yaw, pitch; 1/10 fat variant).
caveWalk13: Random(walkSeed) (java seed, NOT chunkSeed); n4m range
(112-nextInt(28)); big-room single pass; branch recursion at n6 with
nextLong-BEFORE-nextFloat arg order (Java left-to-right — swapped order
once poisoned all tunnels); distance cull (d12 = ff+18); ellipsoid carve
via carveCells (water check scans top+bottom on interior columns —
exact skip/jump; off-by-one i vs i+1 read/write replicated; grass-top
replaced via voronoi TOP256 lookup; lava(11 still) below y=10).
Trig via qh table built f64->f32 (Zig @sin insufficient — 1e-7 drift).
STATUS: grass-top WalkAllLog + full-array CRC golden passes. Only carves
stone/dirt/grass; never fills ocean. IRRELEVANT to this symptom.

## S8. Structures spec (placement missing — known deviation)

### S8.1 State. struct/ ports detection (village/mineshaft/stronghold/
scattered canSpawn grids + components + loot) but genFlat/generateChunk
NEVER invokes structure generation: provideChunk has no MapGen pass.
populateOne runs "detection only, zero draws" (decor.zig ~1530).
DEVIATION #2 (accepted pending phase): villages, mineshafts, strongholds,
witch huts/desert temples/jungle temples (scattered) place NO blocks.
Consequence: missing buildings/ores-displacement near them; NO effect on
base terrain height/biome. IRRELEVANT to mountain<->ocean. (Vanilla also
suppresses lakes near strongholds — assumed absent, same phase.)
### S8.2 canSpawn grids use own ChunkRand-style streams (zero populate draws
when skipped — no RNG desync from absence).

## S9. Populate / decorate spec (cannot cause this symptom, listed for
completeness + RNG audit)

### S9.1 seedForChunk (decor.zig ~1492). setSeed(world_seed);
l=nextLong/2*2+1 (trunc division — matches Java /); l1 same;
setSeed(cx*%l +% cz*%l1 ^ world_seed) (Zig precedence gives
((cx*%l)+%(cz*%l1))^seed = Java (x*l+z*l1)^seed; wrapping ops = Java
long overflow). EXACT.

### S9.2 populateOne order (decor.zig ~1518+): water lake (not desert 2/17,
1/4, y=nextInt256) -> lava lake (1/8, y=nextInt(nextInt248+8), runs if
y<63 or 1/10) -> dungeons 8x (y=nextInt256) -> recompute heights ->
ice spikes (3x) + ice paths (2x, radius 4) on biome 140 ONLY (aij.a runs
these BEFORE super.decorate; base ice plains 12 skips) ->
ores (dirt 20x32/0-256, gravel 10x32, coal 20x16/0-128, iron 20x8/0-64,
gold 2x8/0-32, redstone 8x7/0-16, diamond 1x7/0-16, lapis triangular
nextInt16+nextInt16, all no-+8 offset) -> disks (sand/clay/gravel counts
per diskCounts, +8 offset, wy=top+1) -> trees (count + 1/10 bonus, +8,
wy=top+1, selectTree incl. -999/-100 specials) -> bigshroom ->
flowers (wy=nextInt(f+32), tulip simplex Random(2345)) -> grass
(wy=nextInt(2f)) -> deadbush -> lilies -> shrooms (B loop 1/4 brown +
1/8 red, standalone brown 1/4 + red 1/8, wy=nextInt(2f)) -> reeds (C
loop + 10 unconditional) -> pumpkin 1/32 -> cactus -> springs (50
water y=nextInt(nextInt248+8), 20 lava y=nextInt(nextInt(nextInt240+8)+8))
-> exHills extras (emerald 3+nextInt6 y=nextInt28+4 on stone; 7x
silverfish minable-8 y=nextInt64) -> SNOW/ICE TAIL (per-column frozen
check on win_bio, heightAt live height, water->ice, soft-flora bury,
else snow on snowSupport).
Vanilla gates added this audit round: mushrooms need soil+darkness
(mycelium exempt), flowers need light>=8, snowSupport (leaves/full-snow
hold; ice/fluids/flora never), soft-flora bury. JVM populate goldens
(forest + plains seed 42) regenerate byte-identical.

### S9.3 decorateCenter 3x3 merge (decor.zig ~1849). Copies 9 flats into a
48x48 view (ox=(cx-1)*16), snapshots base, runs populateOne per neighbor
(dz,dx sorted, CENTER LAST) each from the pristine base with its own
seedForChunk + center+8 voronoi biome + 16x16 win_bio slice, merging back
only changed cells. RATIONALE: vanilla populates on one live world where
spillover (trees/lakes across borders) is order-dependent; the merge
makes generation a pure function f(seed,cx,cz) (required for worker-pool
determinism). DIVERGENCE ACCEPTED: border spillover differs from any
single vanilla exploration order by design (affects only decorate
features within ~2 blocks of chunk borders — trees/lakes/disks).
CANNOT flip mountain<->ocean. Post-merge: sweepFloaters (center flora)
+ gen.zig snow-support sweep (center snow).
win_bio layout: filled [wdx*16+wdz] (View x*sz+z layout) from
bio48[lx+lz*sx] (getInts row-major [dz*w+dx] — same thing); tail reads
[dx*16+dz]. Consistent — the transposition trap flagged in comments is
currently avoided (verified by snow/ice per-column test).

### S9.4 Snow/ice tail (decor.zig ~1770-1801 + gen.zig ~369-392). Per-column
isFrozenBiome check (base ids 10,11,12,13,30,31 — NOT taiga 5/19,
NOT biome-class based). heightAt = live topmost non-air. Water->ice;
soft flora (tuft/flowers/shrooms/deadbush) on snowSupport soil -> bury
(replaced); else air above + snowSupport(tid) -> snow_layer.
NOTE (fixed this audit): stray TAILDBG std.debug.print calls removed;
stale seedForChunk docstring corrected.

## S10. Chunk assembly + serve spec (ruled out for this symptom)

### S10.1 genChunk assembly (gen.zig ~189-266). genFlat -> decorateInto ->
pack into Chunk sections (only non-empty), border-exact light from the
48-wide flood, biomes = voronoi 16x16 truncated to u8, heights =
topmost lightOpacity!=0 (flora/snow/glass/lava excluded; water/ice/
leaves included).
### S10.2 Storage key (store.zig ~75-90). encodeKey(dim,x,z): dim byte +
big-endian biased x,z. Round-trip tested incl. min/maxInt. No swap.
### S10.3 Serve path (burst.zig sendColumns/resyncDisk/completeLogin).
positions carry (x=chunkX, z=chunkZ) end to end: spiral offsets added as
(cx+dx, cz+dz), sentKey(x,z), BulkColumn{.x=pos.x,.z=pos.z}. No
transposition found. View distance spiral matches serve.Spiral order.
### S10.4 Light (gen.zig lightGrid48). 48-wide exact column skylight +
raise-BFS both channels; center extracted with 16-cell margin
(border-exact by construction). Affects rendering brightness only.

## S11. Verification status + coverage gaps (the honest table)

Pinned by live-JVM goldens (all passing at time of writing):
  java_random: nextInt/Long/Bound(rejection)/Float/Double/Boolean/Bytes/
    Gaussian bits, setSeed reset.
  genlayer: 8x8 final_mix + voronoi at origin, seeds 1 and 42; init-quirk
    baseSeed==0 layers 23,24.
  shaper density: q bit-patterns + fill counts + CRC for 1@(0,0),
    42@(3,-5), 12345@(-7,11); surface CRC for same + mesa 55555@(-1,-1)
    and @(0,0) incl. meta CRC.
  genFlat CRC: 1@(0,0), 42@(3,-5), 12345@(-7,11), 55555@(-1,-1),@(0,0),
    42@(0,1), 1@(5,-3), 777@(10,10), 99@(-4,6), 7@(8,8).
  populateOne CRC: forest + plains (seed 42 chunk 0,0).
  carve: grass-top walk CRC; trig spot checks.
  decor/orseeds: minable/tree/disk/dungeon/lake unit goldens (see file).

NOT pinned (coverage gaps — where a far-field bug would hide):
  G1. No GenLayer golden beyond the origin 8x8 window. (15,44) region
      never sampled against JVM.
  G2. No density/fill/surface golden within ~40 chunks of (15,44).
  G3. No end-to-end genChunk golden vs a real 1.7.10 server chunk dump
      (all CRCs are internal consistency + near-origin JVM only).
  G4. Structures unplaced (S8) and ravines off (S7) — whole subsystems
      unverified by design.
  G5. decorateCenter merge has no vanilla counterpart (pure-function
      design); only internal determinism (pool byte-identical test).

Closing G1/G2 is the code path to excluding (3)/(4): add JVM goldens
for the GenLayer window + density field of chunk (15,44) under the
reporter's seed (needs the seed + a Goldens-harness run; harness lives
with whoever holds the jar tooling — see tmp_golden pattern removed
after use; do NOT commit temp tools).

## S12. Known deviations register (do not "fix" silently — each changes bytes)

D-A (fixed this audit): TAILDBG debug prints in snow tail — removed.
    Stale seedForChunk docstring — corrected. No byte change.
D-B ravines disabled (carve.zig). Changes bytes when enabled. Needs:
    golden vs JVM ravine walk + full-chunk CRC before flipping.
D-C structures unplaced (genFlat has no MapGen pass). Changes bytes.
    Needs: placement port + stronghold-lake suppression + goldens.
D-D decorateCenter 3x3 merge vs vanilla live-world populate order.
    By design (determinism); border-cell decorate features may differ
    from vanilla. Not a bug to "fix" without a determinism-preserving
    alternative.
D-E light gates on flora/mushrooms evaluate skylight-from-opacity
    (block light assumed 0 pre-lighting, same as vanilla at this stage).
    Matches vanilla outcomes; no RNG consumed either way.
D-F pipeline.zig scaffold unused by live path (docs only).
D-G per-biome decorate extras (surveyed 2026-10-25 via jar bytecode;
only spikes ported — rest are open gaps, each needs its own JVM golden):
DONE: ice spikes (arw) + ice paths (arv radius 4), 3x+2x on biome 140
before ores (aij.a order). Goldens: SpikeGold harness (real arw/arv,
seeds 1/2/3/7/42 + dirt-top negative; spike n=18/176/99/198/82,
path n=58 always). End-to-end: chunk (15,44) seed -3755478573795537924
yields 694 packed_ice, top spike y=136.
DONE (order-verified, aid.a runs super first): hills emerald/silverfish
placement after springs matches vanilla position in the RNG stream.
OPEN: desert wells (aic.a: new arl 1/1000 per chunk), forest extras
(aif.a: aru + flower-count tweaks), jungle melon patch (asc) + vine
patch (asr) in aik.a, plains tulip gate (aip.a: simplex 200x/-0.8 +
flower-count override — our flowerType needs a line-by-line check),
savanna extras (ais.a), taiga extras incl. likely boulders (aiw.a: arf).
Mega-taiga podzol/boulder coverage belongs here too.

## D. Diagnostic procedures

### D1 (5 min, excludes causes #1/#2/#5 — do FIRST):
  1. `seed` from server config + startup log. Note string-vs-int.
  2. Fresh singleplayer, seed = that integer, World Type DEFAULT,
     version EXACTLY 1.7.10 (launcher profile!). A modern client with the
     same numeric seed generates a DIFFERENT world — this is now the #1
     suspect for any "same seed, different terrain" report (proven: our
     (15,44) output is vanilla-identical, S0 VERDICT).
  3. /tp 247 127 708 (or 247 ~ 708), F3: biome + Y. Screenshot both.
  4. If they now match: original comparison used a different seed/type.
     Done — no code action.
  5. If still ocean-vs-mountain: server world dir may hold stale chunks
     (wipe world/ + pregen, re-check) — else proceed to D2.

### D2 (needs the seed; excludes causes #3/#4):
  1. Temp tool (pattern: tools/tmp_golden.zig, deleted after use):
     Gen.init(seed,false,false) -> shaper.chain.getInts(roots[0],
     15*4-2,44*4-2,10,10) print ints; densityField(15,44) print q CRC;
     genFlat(15,44) print block CRC + heightmap max.
  2. Same-window JVM run (Goldens harness): identical three outputs.
  3. First divergence localizes the fix: biome window -> S3 regjster;
     q CRC -> S4/S5; flat CRC only -> S6/S7.
  3b. Cross-check with an independent vanilla tool (Amidst/MineAtlas
     1.7.10 profile, same seed) at 247,708 for a second opinion.
  4. Add the (15,44) outputs as permanent goldens (closes G1/G2 for this
     region).
