//! Surface-apply GPU design: measured, analyzed, DEPRIORITIZED.
//!
//! Status: design + verdict, no kernel. The numbers below (ReleaseFast,
//! this box, `genq_dump <seed> <cx> <cz> <out> 200`) say a surface GPU
//! kernel is a poor trade — comparable absolute saving to fill at ~10x the
//! complexity. This file records the analysis so the decision is reviewable
//! and the design is buildable if the bottleneck picture changes.
//!
//! ## Measured per-chunk costs (µs)
//!
//! | stage              | base (1,0,0) | mesa (55555,-1,-1) |
//! |--------------------|--------------|--------------------|
//! | densityField (CPU) | ~1844        | ~1846              |
//! | fillChunk (CPU)    | ~397         | ~448               |
//! | fill+surface (CPU) | ~1424        | ~1717              |
//! | surface ≈          | ~1027        | ~1269              |
//! | RNG floor          | ~491         | ~491               |
//!
//! The RNG floor is the exact minimum draw sequence surfaceChunk consumes:
//! 1 nextDouble + 256 nextIntBound(5) per column x 256 columns (sand
//! nextIntBound(4)s add on top in sand biomes). Measured with the real
//! JavaRandom LCG, so it is a lower bound, not an estimate.
//!
//! Split: RNG stream ~491µs (48%, inherently sequential) vs scan logic +
//! writes + tables + tempAt ~536µs (52%). Even a perfect GPU scan (~20µs,
//! fill-like) leaves ~500µs of CPU stream replay: net saving ~480µs/chunk
//! vs fill's ~400µs/chunk at a fraction of the complexity.
//!
//! ## Why the stream blocks parallelization
//!
//! Columns share one JavaRandom in chunk order. Draw counts per column are
//! data-dependent: the base path consumes an extra nextIntBound(4) each
//! time filler_depth hits exactly 0 while filler == sand (sand biomes
//! only); the mesa path consumes none. To give GPU invocation k its exact
//! starting stream state, the CPU must know every previous column's draw
//! count — which requires evaluating the filler_depth trajectory, i.e. a
//! scan-lite pass (~50-70% of the scan) PLUS a full stream replay (~500µs).
//! Precompute total ≈ 750µs to save ≈ 480µs. Not worth it.
//!
//! LCG skip-ahead does not help: jumping to column k's state needs the
//! exact skip distance, which is the data-dependent count above. Splitting
//! fixed draws (skip-ahead-able) from sand draws (not) would change stream
//! positions — non-vanilla, forbidden.
//!
//! ## The design that would work (if revisited)
//!
//! 1. CPU per chunk, in order: run the stream once, recording per column
//!    {depth: i32, r5[256]: u8, sand_vals[8]: u32, sand_n: u8,
//!    freeze: bool, mesa: bool} (~75KB/chunk; sand overflow past 8 falls
//!    back to CPU for that column — measure first, bound empirically).
//! 2. GPU: 256 invocations (one per column), each running the full 256-deep
//!    top-down scan from its recorded draws + shared tables (TOP256 /
//!    FILLER256 / TEMP256 as one 256-entry SSBO) + freeze flag instead of
//!    TempEval (freeze is 1 bit/column; the simplex eval stays CPU).
//!    Mesa columns run on CPU (simplex-heavy band lookups); per-column
//!    routing by the mesa flag.
//! 3. Same bit-exactness discipline as threshold: NoContraction on every
//!    float op (f32 and f64), bit-soup oracle with subnormals, real-q
//!    `--realq` gate before any wiring.
//!
//! Expected outcome: ~500µs CPU (stream) + ~20µs GPU vs ~1000µs all-CPU.
//! Revisit only if: (a) fill-wiring + batching makes surface the new
//! bottleneck on region-gen profiles, or (b) someone demonstrates exact
//! skip-ahead counts cheaper than the scan-lite pass.
//!
//! ## What this means for G1 order
//!
//! `job.JobKind.surface_apply` stays a valid contract (table lookups over
//! column batches); only the fill side is implemented. Next GPU value is
//! the async job queue + CPU-fallback backend (src/gpu/-only, drops in at
//! wiring), not more kernels: fill covers the proven win, batching covers
//! the scaling, and every other candidate is either blocked (K4/L1 refs)
//! or measured-marginal (carve — sequential walk, sparse writes).
