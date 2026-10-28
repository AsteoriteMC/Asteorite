//! G1 GPU work (desktop headless Vulkan). UNWIRED — not imported by
//! `src/root.zig`, not referenced in `build.zig`. Additive-only by design
//! (the bench agent owns the shared tree).
//!
//! Contents:
//! - `vk_min.zig`: minimal Vulkan binding + loader (dlopen, 3-tier
//!   GIPA/GDPA resolution, headless instance, compute-family pick with a
//!   queueCount guard, 1-queue device with optional 1.0 features,
//!   full dispatch tier: buffers/memory, descriptors, pipeline layout,
//!   shader module, compute pipeline, command pool/buffer, barriers,
//!   submit/fence). Unit-tested (`zig test src/gpu/vk_min.zig -lc`):
//!   result/type names, C ABI offsets, memory-type pick, feature count,
//!   loader-open (skips without a driver).
//! - `echo.comp.spvasm` + `echo.comp.spv`: echo kernel (1024 u32 copy).
//! - `echo_spv.zig`: `@embedFile`s the echo binary + structural tests.
//! - `threshold.comp.spvasm` + `threshold.comp.spv`: density-threshold
//!   kernel — ports `Shaper.fillChunk` (src/worldgen/v5/shaper.zig)
//!   bit-exactly: host stages CPU-computed q[825] f64 + 4 params, GPU runs
//!   the trilinear fill + stone/water/id select over 512 columns
//!   (LocalSize 64 -> 8 groups, 65536 u32 cells out).
//! - `threshold_spv.zig`: embeds the threshold binary + structural tests
//!   (magic, version, bound, whole-stream walk, Float64 capability,
//!   NoContraction count).
//! - `job.zig`: async job interface (Job/Backend/TickBudget +
//!   `expectBitIdentical`). Unit-tested, no device needed.
//! - `../tools/gpu_probe.zig`: standalone probe + echo dispatch + threshold
//!   dispatch with soup oracle, plus `--realq <file>` mode (genq_dump
//!   output: REAL JVM-verified q + REAL fillChunk expected — the game-data
//!   proof) and `--batchq` multi-chunk mode with `--groups` diagnostic cap.
//!   Build with `zig build gpu-probe`, run `./zig-out/bin/gpu_probe`.
//!
//! - `../tools/genq_dump.zig`: stages REAL q[825] + REAL fillChunk output
//!   to a file for `--realq` (`zig build genq-dump`). Imports the real
//!   Shaper/ids through the `asteorite` module.
//!
//! Verified 2026-10-26, both drivers green:
//! RX 9070 XT (RADV, dedicated compute family): echo PASS (1024 u32,
//! ~210µs), threshold soup PASS + 3 real chunks PASS (65536 cells each
//! bit-identical, ~120-240µs; seeds/chunks (1,0,0), (42,3,-5),
//! (12345,-7,11) — the JVM-golden chunks from the shaper tests).
//! llvmpipe: echo + soup + realq PASS (CPU-emulated, slower as expected).
//!
//! Batch amortization (RX 9070 XT, min-of-5, per-chunk vs CPU fill 418µs):
//! N=1: 115µs (3.6x), N=4: 36µs (12x), N=8: 20µs (21x), N=16: 18µs (23x).
//! Fixed cost ≈ 100-150µs (submit ~17µs + fence latency); marginal cost
//! ≈ 1µs/chunk. Cap dispatches at 128 groups (16 chunks): past ~200 groups
//! the experimental RADV driver falls off a cliff (fence 10-100x, proven
//! group-count-triggered via --groups bisection, not buffer size). Region
//! scale = many 16-chunk dispatches, pipelined async — per-chunk cost stays
//! ~18µs, so a 1024-chunk region is ~19ms of background GPU work.
//! llvmpipe: batch correct at all N (slower, CPU-emulated).
//! Exit 2 = no loader / device / compute queue / float64 / host-coherent
//! memory (soft fail for CI).
//!
//! Bugs found by this scaffold (all real, all fixed):
//! - `VK_PIPELINE_BIND_POINT_COMPUTE` is 1, not 0: binding the compute
//!   pipeline at bind point 0 left dispatch with a null pipeline
//!   (record-time segfault on radv, null-jump worker on lavapipe).
//! - `vkGetInstanceProcAddr(null, …)` resolves globals only — the
//!   Loader/Instance/Device three-tier design (missing fns previously
//!   resolved to null and crashed far from the cause).
//! - VkPhysicalDeviceFeatures is 55 members with shaderFloat64 at index 39
//!   (verified against `vulkaninfo`; NOT 50/34 — the struct has no
//!   texel-buffer pair and includes the depthClamp block). A short array
//!   over-reads stack garbage into the driver → FEATURE_NOT_PRESENT on
//!   every driver, a deeply misleading error for a correct-looking call.
//! - FMA contraction is REAL on RADV: fusing one `(q-d)*0.125` flipped an
//!   exact-0.0 comparison (cell 16 knife-edge: expect water, got stone).
//!   Every f64 arithmetic result in every checked-in shader carries
//!   NoContraction (22 in threshold); the spv test pins the count and the
//!   bit-soup oracle (subnormals, NaN/Inf, exact zeros) proves it.
//!
//! Rules for future kernels (TODO.md Phase G + H5): async bulk jobs only,
//! tick never waits; bit-identical output vs CPU; integer-exact stages
//! first — the noise/RNG core stays CPU (Vulkan float != Java StrictMath).
//! NoContraction on ALL float arithmetic, no exceptions.
//!
//! Wiring checklist (AFTER the bench agent lands — do not start early):
//! 1. `exe.linkLibC()` (or equivalent) in `build.zig`: raw `dlopen` externs
//!    (`std.DynLib` fails in test binaries).
//! 2. `src/root.zig`: export `gpu` modules (single claimant rule —
//!    `import_gate.zig` forbids path-imports from two modules; switch the
//!    probe to `@import("asteorite").gpu...` at that point).
//! 3. `build.zig`: `gpu-probe` step + SPIR-V sources to the install tree.
//! 4. `--gpu off|vulkan` + `--gpu-budget-ms` in `cli.zig`/`config.zig`.
//! 5. `GenPool` submit/poll behind `job.Backend`; CPU fallback default.
//! 6. Threshold wiring: real-q staging is proven (`--realq`); at wiring time
//!    feed `densityField` q + profile ids/SEA_LEVEL directly (no files) and
//!    keep the worldgen_dump goldens as the gate; then surface-apply next
//!    ONLY per SURFACE_DESIGN.md (measured-marginal: RNG floor 491µs of
//!    ~1027µs surface; draw-table design documented, deprioritized).
//!
//! WIRING STATUS 2026-10-26 (done, all green):
//! - Config/CLI/boot: `gpu`/`gpu_budget_ms`/`gpu_max_batch`/`gpu_device`
//!   in config.zig + cli.zig + main.zig (merge/validate/boot notes/tested)
//!   + asteorite.example.toml.
//! - `GenPool.create` takes `gpufill.Options`; per-worker GpuFill (own
//!   device/queue/pipeline/buffers, no cross-thread sharing) + shared
//!   GpuCtx; CPU fallback per fill. Boot pregen Gen gets its own Fill.
//! - `zig build test` 30/30 green incl. new GPU integration test
//!   (GenPool+GPU byte-identical vs sync CPU on 4 chunks, asserts
//!   gpu_fill > 0 and zero fallbacks; skips without a driver).
//! - Live: --gpu vulkan boots ("fill offload active (RX 9070 XT...)"),
//!   pregens clean, DB `check` clean; 5-chunk surface band + full
//!   center/corner chunks block-identical vs --gpu off. Bulk-file diffs
//!   are pre-existing pregen worker-order nondeterminism (CPU-vs-CPU
//!   differs identically; blocks deterministic everywhere sampled) —
//!   compare at block level, never bulk level, for parity.
//! - Remaining wiring follow-ups: multi-dispatch batcher (v2, needs the
//!   async queue), gpu counters in the tick stats line (collected in
//!   Stats, not yet displayed), surface-apply (see SURFACE_DESIGN.md).
