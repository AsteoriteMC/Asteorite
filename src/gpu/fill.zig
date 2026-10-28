//! Persistent GPU fill for GenPool workers (Phase G wiring).
//!
//! One `GpuCtx` per process (owns the loader + instance + chosen device);
//! one `GpuFill` per gen worker (owns a logical device + queue + pipelines +
//! persistently-mapped staging buffers + command pool). Workers never share
//! GPU state, so no cross-thread locking anywhere past init.
//!
//! Two dispatch shapes, same bit-exact kernel family:
//! - `fill`: one chunk, synchronous submit + fence wait (~100-500µs).
//! - `fillBatch`: up to `batch_cap` chunks in ONE dispatch + ONE fence
//!   wait (v2 amortized path, ~18µs/chunk at N=16 per the probe gate).
//! Both run on GenPool worker threads — never the tick path, so the
//! async-only rule holds by construction. Any GPU failure returns false
//! and the caller runs the CPU `fillChunk`: bit-identical either way
//! (proven by the --realq probe gate on JVM-verified chunks).
//!
//! Cap guidance (from threshold_batch_spv): stay ≤128 groups (16 chunks)
//! per dispatch; past ~200 groups the experimental RADV driver falls off a
//! fence-latency cliff. `Options.max_batch` (validated 1..64) clamps below.

const std = @import("std");
const vk = @import("vk_min.zig");
const th = @import("threshold_spv.zig");
const bth = @import("threshold_batch_spv.zig");
const ids_mod = @import("../ids.zig");

/// Which physical device to prefer. `cpu` selects a CPU-type device
/// (llvmpipe) for testing the GPU path without discrete hardware.
pub const DevicePref = enum {
    auto,
    discrete,
    integrated,
    cpu,

    pub fn parse(s: []const u8) ?DevicePref {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "discrete")) return .discrete;
        if (std.mem.eql(u8, s, "integrated")) return .integrated;
        if (std.mem.eql(u8, s, "cpu")) return .cpu;
        return null;
    }
};

/// GenPool-facing options (translated from config in main.zig).
/// `budget_ms` lives in config only (async pacing is a v2 concern) and is
/// NOT read here — see the boot note in main.zig.
pub const Options = struct {
    enabled: bool = false,
    device: DevicePref = .auto,
    /// Max chunks per batch dispatch. Validated 1..64 at the config
    /// boundary; clamped to `batch_cap` (16) at wiring time.
    max_batch: usize = 16,
};

/// Max chunks per batch dispatch. 16 chunks = 128 groups, the RADV-safe
/// ceiling from threshold_batch_spv (past ~200 groups fence latency falls
/// off a cliff). `Options.max_batch` clamps at or below this.
pub const batch_cap: usize = 16;

/// Batch staging sizes, sized to `batch_cap` — NOT the shader MAXBATCH=64
/// ceiling: dispatch indices stay < n ≤ 16 by construction (`fillBatch`
/// rejects larger n), so the smaller bound buffers are always in-bounds.
/// Saves ~12.4 MiB of pinned host-visible memory per worker.
pub const batch_q_bytes: usize = batch_cap * bth.Q_PER_CHUNK * 8;
pub const batch_out_bytes: usize = batch_cap * bth.CELLS_PER_CHUNK * 4;

/// Process-wide GPU state. Created once when `--gpu vulkan` is set;
/// null means CPU-only (flag off or no usable device — both are normal).
pub const GpuCtx = struct {
    loader: vk.Loader,
    inst: vk.Instance,
    phys: vk.VkPhysicalDevice,
    family: u32,
    feats: [vk.VK_DEVICE_FEATURE_COUNT]u32,
    /// Human-readable device line for the boot log (not NUL-terminated).
    desc: [64]u8 = [_]u8{0} ** 64,
    desc_len: usize = 0,

    pub fn description(self: *const GpuCtx) []const u8 {
        return self.desc[0..self.desc_len];
    }

    /// Null on any unavailable-GPU condition (no loader, no device, no
    /// compute queue, no float64): the caller logs once and runs CPU-only.
    /// Real errors (OOM) propagate.
    pub fn init(backing: std.mem.Allocator, device_pref: DevicePref) !?*GpuCtx {
        var loader = vk.Loader.open() catch |err| switch (err) {
            error.NoVulkanLibrary, error.NoGetInstanceProcAddr => return null,
            else => return err,
        };
        errdefer loader.close();
        var inst = loader.createHeadlessInstance("asteorite") catch return null;
        errdefer inst.destroy();

        const n = inst.deviceCount() catch return null;
        if (n == 0) {
            inst.destroy();
            loader.close();
            return null;
        }
        var devs: [16]vk.VkPhysicalDevice = undefined;
        const ngot = inst.enumDevices(devs[0..@min(n, 16)]) catch {
            inst.destroy();
            loader.close();
            return null;
        };
        var scratch: [vk.device_id_scratch_bytes]u8 align(4) = undefined;
        var families: [32]vk.VkQueueFamilyProperties = undefined;
        var best: ?usize = null;
        var best_tier: u8 = 255;
        for (devs[0..ngot], 0..) |phys, i| {
            const id = inst.getDeviceId(phys, &scratch);
            if (inst.pickComputeFamily(phys, &families) == null) continue;
            const tier: u8 = switch (id.deviceType) {
                .discrete_gpu => 0,
                .integrated_gpu => 1,
                .virtual_gpu => 2,
                .cpu => 3,
                else => 4,
            };
            const wanted: ?u8 = switch (device_pref) {
                .auto => null,
                .discrete => 0,
                .integrated => 1,
                .cpu => 3,
            };
            if (wanted) |wt| {
                if (tier != wt) continue;
                best = i;
                best_tier = tier;
                break;
            }
            if (tier < best_tier) {
                best = i;
                best_tier = tier;
            }
        }
        const bi = best orelse {
            inst.destroy();
            loader.close();
            return null;
        };
        const phys = devs[bi];
        const fam = inst.pickComputeFamily(phys, &families) orelse unreachable;
        const feats = inst.features(phys);
        if (feats[vk.VK_FEATURE_SHADER_FLOAT64] == 0) {
            inst.destroy();
            loader.close();
            return null;
        }
        const self = try backing.create(GpuCtx);
        errdefer backing.destroy(self);
        self.* = .{
            .loader = loader,
            .inst = inst,
            .phys = phys,
            .family = fam,
            .feats = feats,
        };
        const id = inst.getDeviceId(phys, &scratch);
        const nm = std.mem.sliceTo(id.deviceName[0..], 0);
        const nlen = @min(nm.len, self.desc.len - 1);
        @memcpy(self.desc[0..nlen], nm[0..nlen]);
        self.desc_len = nlen;
        return self;
    }

    pub fn deinit(self: *GpuCtx, backing: std.mem.Allocator) void {
        self.inst.destroy();
        self.loader.close();
        backing.destroy(self);
    }
};

/// Per-worker fill state. All Vulkan objects are created once (dispatch
/// command buffers pre-recorded, fence persistent); per fill: memcpy q
/// in, update params, reset fence, submit, fence-wait, convert out.
/// Buffers stay mapped (host-coherent) for the GpuFill lifetime.
pub const GpuFill = struct {
    dev: vk.Device,
    queue: vk.VkQueue,
    family: u32,
    set_layout: vk.VkDescriptorSetLayout,
    pool: vk.VkDescriptorPool,
    set: vk.VkDescriptorSet,
    pipe_layout: vk.VkPipelineLayout,
    mod: vk.VkShaderModule,
    pipeline: vk.VkPipeline,
    cmd_pool: vk.VkCommandPool,
    cmd: vk.VkCommandBuffer,
    /// Persistent fence reused across fills (create+destroy per fill sat
    /// on the critical path: two driver calls per dispatch). Reset before
    /// each submit; the fence wait guarantees the prior submit completed.
    fence: vk.VkFence,
    q_buf: vk.VkBuffer,
    o_buf: vk.VkBuffer,
    p_buf: vk.VkBuffer,
    q_mem: vk.VkDeviceMemory,
    o_mem: vk.VkDeviceMemory,
    p_mem: vk.VkDeviceMemory,
    q_ptr: [*]u8,
    o_ptr: [*]u8,
    p_ptr: [*]u8,
    /// Batch path (v2 amortized dispatch): second pipeline + chunk-major
    /// staging for up to `batch_cap` chunks, same set layout (the batch
    /// shader uses set 0 = {q @0, out @1, params @2} like the single
    /// kernel). Created in initResources; `batch_ok` false keeps the
    /// single-fill path alive when batch setup fails.
    b_mod: vk.VkShaderModule,
    b_pipeline: vk.VkPipeline,
    b_pool: vk.VkDescriptorPool,
    b_set: vk.VkDescriptorSet,
    b_q_buf: vk.VkBuffer,
    b_o_buf: vk.VkBuffer,
    b_p_buf: vk.VkBuffer,
    b_q_mem: vk.VkDeviceMemory,
    b_o_mem: vk.VkDeviceMemory,
    b_p_mem: vk.VkDeviceMemory,
    b_q_ptr: ?[*]u8 = null,
    b_o_ptr: ?[*]u8 = null,
    b_p_ptr: ?[*]u8 = null,
    batch_ok: bool = false,
    /// Pre-recorded batch command buffers, one per chunk count 1..16
    /// (index n-1). Same commands the old per-fill recording emitted
    /// (merged availability barrier + dispatch of groupsFor(n)); recorded
    /// once at init, resubmitted without re-recording. Valid only when
    /// `batch_ok` (zeroed otherwise).
    b_cmds: [batch_cap]vk.VkCommandBuffer,
    /// Successful batch dispatches (for the pool stats proof that the
    /// amortized path ran, not just N=1 fills). Single-writer like above.
    batches_ok: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    logged_fallback: bool = false,
    /// Fills completed on the GPU vs declined to CPU. Single-writer (the
    /// owning worker); read cross-thread by GenPool.snapshotStats, hence
    /// atomic.
    fills_ok: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fills_fallback: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn fail(self: *GpuFill, what: []const u8) bool {
        if (!self.logged_fallback) {
            self.logged_fallback = true;
            std.log.warn("gpu: fill offload failed ({s}); falling back to CPU fill for this worker", .{what});
        }
        _ = self.fills_fallback.fetchAdd(1, .monotonic);
        return false;
    }

    /// Create per-worker state from the shared context. Null on any
    /// failure (worker runs CPU-only).
    pub fn init(ctx: *GpuCtx, backing: std.mem.Allocator) ?*GpuFill {
        const self = backing.create(GpuFill) catch return null;
        errdefer backing.destroy(self);
        // NOTE: backing.create leaves memory uninitialized — field defaults
        // do NOT apply. Every field is assigned here or in initResources;
        // the atomics especially must not read garbage (stats + warn gate).
        self.logged_fallback = false;
        self.fills_ok = std.atomic.Value(u64).init(0);
        self.fills_fallback = std.atomic.Value(u64).init(0);
        self.batches_ok = std.atomic.Value(u64).init(0);
        self.batch_ok = false;
        const prio: f32 = 1.0;
        self.dev = ctx.inst.createComputeDeviceWithFeatures(ctx.phys, ctx.family, prio, &ctx.feats) catch return null;
        errdefer self.dev.destroy();
        self.queue = self.dev.queue(ctx.family, 0);
        self.family = ctx.family;
        if (!self.initResources(ctx)) {
            self.dev.destroy();
            backing.destroy(self);
            return null;
        }
        return self;
    }

    /// Buffers, descriptors, pipeline, command buffer. False on any failure
    /// (caller destroys the device). Persistent maps: coherent memory needs
    /// no flush/invalidate; the per-fill barriers order host<->shader.
    fn initResources(self: *GpuFill, ctx: *GpuCtx) bool {
        const dev = &self.dev;
        const props = ctx.inst.memoryProperties(ctx.phys);

        // --- buffers (host-visible + coherent; exact sizes, N=1) ---
        const qbci = vk.VkBufferCreateInfo{ .size = th.q_bytes, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
        if (dev.vkCreateBuffer(dev.handle, &qbci, null, &self.q_buf) != vk.VK_SUCCESS) return false;
        const obci = vk.VkBufferCreateInfo{ .size = th.out_bytes, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
        if (dev.vkCreateBuffer(dev.handle, &obci, null, &self.o_buf) != vk.VK_SUCCESS) return false;
        const pbci = vk.VkBufferCreateInfo{ .size = th.ParamWords * 4, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
        if (dev.vkCreateBuffer(dev.handle, &pbci, null, &self.p_buf) != vk.VK_SUCCESS) return false;

        var q_req: vk.VkMemoryRequirements = undefined;
        dev.vkGetBufferMemoryRequirements(dev.handle, self.q_buf, &q_req);
        const q_type = vk.findHostCoherentMemoryType(&props, q_req.memoryTypeBits) orelse return false;
        const q_ai = vk.VkMemoryAllocateInfo{ .allocationSize = q_req.size, .memoryTypeIndex = q_type };
        if (dev.vkAllocateMemory(dev.handle, &q_ai, null, &self.q_mem) != vk.VK_SUCCESS) return false;
        if (dev.vkBindBufferMemory(dev.handle, self.q_buf, self.q_mem, 0) != vk.VK_SUCCESS) return false;

        var o_req: vk.VkMemoryRequirements = undefined;
        dev.vkGetBufferMemoryRequirements(dev.handle, self.o_buf, &o_req);
        // Readback-heavy output: prefer a cached heap (CPU reads go
        // through the cache, not uncached BAR/WC mappings). Falls back
        // to the coherent picker where no cached heap exists.
        const o_type = vk.findHostCachedMemoryType(&props, o_req.memoryTypeBits) orelse
            vk.findHostCoherentMemoryType(&props, o_req.memoryTypeBits) orelse return false;
        const o_ai = vk.VkMemoryAllocateInfo{ .allocationSize = o_req.size, .memoryTypeIndex = o_type };
        if (dev.vkAllocateMemory(dev.handle, &o_ai, null, &self.o_mem) != vk.VK_SUCCESS) return false;
        if (dev.vkBindBufferMemory(dev.handle, self.o_buf, self.o_mem, 0) != vk.VK_SUCCESS) return false;

        var p_req: vk.VkMemoryRequirements = undefined;
        dev.vkGetBufferMemoryRequirements(dev.handle, self.p_buf, &p_req);
        const p_type = vk.findHostCoherentMemoryType(&props, p_req.memoryTypeBits) orelse return false;
        const p_ai = vk.VkMemoryAllocateInfo{ .allocationSize = p_req.size, .memoryTypeIndex = p_type };
        if (dev.vkAllocateMemory(dev.handle, &p_ai, null, &self.p_mem) != vk.VK_SUCCESS) return false;
        if (dev.vkBindBufferMemory(dev.handle, self.p_buf, self.p_mem, 0) != vk.VK_SUCCESS) return false;

        var qp: *anyopaque = undefined;
        if (dev.vkMapMemory(dev.handle, self.q_mem, 0, vk.VK_WHOLE_SIZE, 0, &qp) != vk.VK_SUCCESS) return false;
        self.q_ptr = @ptrCast(qp);
        var op: *anyopaque = undefined;
        if (dev.vkMapMemory(dev.handle, self.o_mem, 0, vk.VK_WHOLE_SIZE, 0, &op) != vk.VK_SUCCESS) return false;
        self.o_ptr = @ptrCast(op);
        var pp: *anyopaque = undefined;
        if (dev.vkMapMemory(dev.handle, self.p_mem, 0, vk.VK_WHOLE_SIZE, 0, &pp) != vk.VK_SUCCESS) return false;
        self.p_ptr = @ptrCast(pp);

        // --- descriptors: set 0 = {q @0, out @1, params @2} ---
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
            .{ .binding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
        };
        const layout_ci = vk.VkDescriptorSetLayoutCreateInfo{ .bindingCount = bindings.len, .pBindings = &bindings };
        if (dev.vkCreateDescriptorSetLayout(dev.handle, &layout_ci, null, &self.set_layout) != vk.VK_SUCCESS) return false;
        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 3 },
        };
        const pool_ci = vk.VkDescriptorPoolCreateInfo{ .maxSets = 1, .poolSizeCount = pool_sizes.len, .pPoolSizes = &pool_sizes };
        if (dev.vkCreateDescriptorPool(dev.handle, &pool_ci, null, &self.pool) != vk.VK_SUCCESS) return false;
        const set_ai = vk.VkDescriptorSetAllocateInfo{ .descriptorPool = self.pool, .descriptorSetCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{self.set_layout} };
        if (dev.vkAllocateDescriptorSets(dev.handle, &set_ai, &self.set) != vk.VK_SUCCESS) return false;
        const q_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = self.q_buf }};
        const o_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = self.o_buf }};
        const p_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = self.p_buf }};
        const writes = [_]vk.VkWriteDescriptorSet{
            .{ .dstSet = self.set, .dstBinding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &q_info },
            .{ .dstSet = self.set, .dstBinding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &o_info },
            .{ .dstSet = self.set, .dstBinding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &p_info },
        };
        dev.vkUpdateDescriptorSets(dev.handle, writes.len, &writes, 0, null);

        // --- pipeline ---
        const pipe_layout_ci = vk.VkPipelineLayoutCreateInfo{ .setLayoutCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{self.set_layout} };
        if (dev.vkCreatePipelineLayout(dev.handle, &pipe_layout_ci, null, &self.pipe_layout) != vk.VK_SUCCESS) return false;
        const mod_ci = vk.VkShaderModuleCreateInfo{ .codeSize = th.words.len * 4, .pCode = &th.words };
        if (dev.vkCreateShaderModule(dev.handle, &mod_ci, null, &self.mod) != vk.VK_SUCCESS) return false;
        const stage = vk.VkPipelineShaderStageCreateInfo{
            .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = self.mod,
            .pName = "main",
        };
        const pipe_ci = vk.VkComputePipelineCreateInfo{ .stage = stage, .layout = self.pipe_layout };
        if (dev.vkCreateComputePipelines(dev.handle, vk.VK_NULL_HANDLE, 1, &pipe_ci, null, &self.pipeline) != vk.VK_SUCCESS) return false;

        // --- command buffer + persistent fence (record the N=1 dispatch once) ---
        const pool_ci2 = vk.VkCommandPoolCreateInfo{ .queueFamilyIndex = self.family };
        if (dev.vkCreateCommandPool(dev.handle, &pool_ci2, null, &self.cmd_pool) != vk.VK_SUCCESS) return false;
        const cmd_ai = vk.VkCommandBufferAllocateInfo{ .commandPool = self.cmd_pool, .commandBufferCount = 1 };
        if (dev.vkAllocateCommandBuffers(dev.handle, &cmd_ai, &self.cmd) != vk.VK_SUCCESS) return false;
        const fence_ci = vk.VkFenceCreateInfo{};
        if (dev.vkCreateFence(dev.handle, &fence_ci, null, &self.fence) != vk.VK_SUCCESS) return false;
        if (!self.recordSingle()) {
            dev.vkDestroyFence(dev.handle, self.fence, null);
            return false;
        }
        // --- batch path (soft-fail: single fills still run without it) ---
        self.batch_ok = self.initBatchResources(ctx);
        return true;
    }

    /// Record the N=1 dispatch once: merged host->shader availability
    /// barrier (q + params in ONE call), bind, dispatch, shader->host
    /// visibility barrier. Same commands the old per-fill recording
    /// emitted, in the same order — only the recording time moved.
    fn recordSingle(self: *GpuFill) bool {
        const dev = &self.dev;
        const begin = vk.VkCommandBufferBeginInfo{};
        if (dev.vkBeginCommandBuffer(self.cmd, &begin) != vk.VK_SUCCESS) return false;
        const avail = [_]vk.VkBufferMemoryBarrier{
            .{
                .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
                .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
                .buffer = self.q_buf,
            },
            .{
                .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
                .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
                .buffer = self.p_buf,
            },
        };
        dev.vkCmdPipelineBarrier(self.cmd, vk.VK_PIPELINE_STAGE_HOST_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, avail.len, &avail, 0, null);
        dev.vkCmdBindPipeline(self.cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        dev.vkCmdBindDescriptorSets(self.cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipe_layout, 0, 1, &self.set, 0, null);
        dev.vkCmdDispatch(self.cmd, th.groups, 1, 1);
        const visible = [_]vk.VkBufferMemoryBarrier{
            .{
                .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
                .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
                .buffer = self.o_buf,
            },
        };
        dev.vkCmdPipelineBarrier(self.cmd, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, visible.len, &visible, 0, null);
        if (dev.vkEndCommandBuffer(self.cmd) != vk.VK_SUCCESS) return false;
        return true;
    }

    /// Record the N-chunk batch dispatch once (same shape as recordSingle,
    /// batch buffers/pipeline/set, groupsFor(n)).
    fn recordBatch(self: *GpuFill, cmd: vk.VkCommandBuffer, n: u32) bool {
        const dev = &self.dev;
        const begin = vk.VkCommandBufferBeginInfo{};
        if (dev.vkBeginCommandBuffer(cmd, &begin) != vk.VK_SUCCESS) return false;
        const avail = [_]vk.VkBufferMemoryBarrier{
            .{
                .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
                .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
                .buffer = self.b_q_buf,
            },
            .{
                .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
                .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
                .buffer = self.b_p_buf,
            },
        };
        dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_HOST_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, avail.len, &avail, 0, null);
        dev.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.b_pipeline);
        dev.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipe_layout, 0, 1, &self.b_set, 0, null);
        dev.vkCmdDispatch(cmd, bth.groupsFor(n), 1, 1);
        const visible = [_]vk.VkBufferMemoryBarrier{
            .{
                .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
                .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
                .buffer = self.b_o_buf,
            },
        };
        dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, visible.len, &visible, 0, null);
        if (dev.vkEndCommandBuffer(cmd) != vk.VK_SUCCESS) return false;
        return true;
    }

    /// Batch pipeline + chunk-major staging (up to `batch_cap` chunks).
    /// Same set layout as the single kernel (the batch shader binds set 0
    /// = {q @0, out @1, params @2}); separate set/buffers, shared queue
    /// and command pool. False on any failure (caller keeps batch_ok
    /// false; the N=1 path is unaffected).
    fn initBatchResources(self: *GpuFill, ctx: *GpuCtx) bool {
        const dev = &self.dev;
        const props = ctx.inst.memoryProperties(ctx.phys);

        // Null-init so the single cleanup below is safe at any stage
        // (destroy/free on VK_NULL_HANDLE are spec no-ops; unmaps guarded).
        self.b_q_buf = vk.VK_NULL_HANDLE;
        self.b_o_buf = vk.VK_NULL_HANDLE;
        self.b_p_buf = vk.VK_NULL_HANDLE;
        self.b_q_mem = vk.VK_NULL_HANDLE;
        self.b_o_mem = vk.VK_NULL_HANDLE;
        self.b_p_mem = vk.VK_NULL_HANDLE;
        self.b_q_ptr = null;
        self.b_o_ptr = null;
        self.b_p_ptr = null;
        self.b_pool = vk.VK_NULL_HANDLE;
        self.b_set = vk.VK_NULL_HANDLE;
        self.b_mod = vk.VK_NULL_HANDLE;
        self.b_pipeline = vk.VK_NULL_HANDLE;
        for (0..batch_cap) |k| self.b_cmds[k] = vk.VK_NULL_HANDLE;

        const ok = blk: {
            const qbci = vk.VkBufferCreateInfo{ .size = batch_q_bytes, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
            if (dev.vkCreateBuffer(dev.handle, &qbci, null, &self.b_q_buf) != vk.VK_SUCCESS) break :blk false;
            const obci = vk.VkBufferCreateInfo{ .size = batch_out_bytes, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
            if (dev.vkCreateBuffer(dev.handle, &obci, null, &self.b_o_buf) != vk.VK_SUCCESS) break :blk false;
            const pbci = vk.VkBufferCreateInfo{ .size = th.ParamWords * 4, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
            if (dev.vkCreateBuffer(dev.handle, &pbci, null, &self.b_p_buf) != vk.VK_SUCCESS) break :blk false;

            var q_req: vk.VkMemoryRequirements = undefined;
            dev.vkGetBufferMemoryRequirements(dev.handle, self.b_q_buf, &q_req);
            const q_type = vk.findHostCoherentMemoryType(&props, q_req.memoryTypeBits) orelse break :blk false;
            const q_ai = vk.VkMemoryAllocateInfo{ .allocationSize = q_req.size, .memoryTypeIndex = q_type };
            if (dev.vkAllocateMemory(dev.handle, &q_ai, null, &self.b_q_mem) != vk.VK_SUCCESS) break :blk false;
            if (dev.vkBindBufferMemory(dev.handle, self.b_q_buf, self.b_q_mem, 0) != vk.VK_SUCCESS) break :blk false;

            var o_req: vk.VkMemoryRequirements = undefined;
            dev.vkGetBufferMemoryRequirements(dev.handle, self.b_o_buf, &o_req);
            // Readback-heavy output: prefer a cached heap (see above).
            const o_type = vk.findHostCachedMemoryType(&props, o_req.memoryTypeBits) orelse
                vk.findHostCoherentMemoryType(&props, o_req.memoryTypeBits) orelse break :blk false;
            const o_ai = vk.VkMemoryAllocateInfo{ .allocationSize = o_req.size, .memoryTypeIndex = o_type };
            if (dev.vkAllocateMemory(dev.handle, &o_ai, null, &self.b_o_mem) != vk.VK_SUCCESS) break :blk false;
            if (dev.vkBindBufferMemory(dev.handle, self.b_o_buf, self.b_o_mem, 0) != vk.VK_SUCCESS) break :blk false;

            var p_req: vk.VkMemoryRequirements = undefined;
            dev.vkGetBufferMemoryRequirements(dev.handle, self.b_p_buf, &p_req);
            const p_type = vk.findHostCoherentMemoryType(&props, p_req.memoryTypeBits) orelse break :blk false;
            const p_ai = vk.VkMemoryAllocateInfo{ .allocationSize = p_req.size, .memoryTypeIndex = p_type };
            if (dev.vkAllocateMemory(dev.handle, &p_ai, null, &self.b_p_mem) != vk.VK_SUCCESS) break :blk false;
            if (dev.vkBindBufferMemory(dev.handle, self.b_p_buf, self.b_p_mem, 0) != vk.VK_SUCCESS) break :blk false;

            var qp: *anyopaque = undefined;
            if (dev.vkMapMemory(dev.handle, self.b_q_mem, 0, vk.VK_WHOLE_SIZE, 0, &qp) != vk.VK_SUCCESS) break :blk false;
            self.b_q_ptr = @ptrCast(qp);
            var op: *anyopaque = undefined;
            if (dev.vkMapMemory(dev.handle, self.b_o_mem, 0, vk.VK_WHOLE_SIZE, 0, &op) != vk.VK_SUCCESS) break :blk false;
            self.b_o_ptr = @ptrCast(op);
            var pp: *anyopaque = undefined;
            if (dev.vkMapMemory(dev.handle, self.b_p_mem, 0, vk.VK_WHOLE_SIZE, 0, &pp) != vk.VK_SUCCESS) break :blk false;
            self.b_p_ptr = @ptrCast(pp);

            // New pool + set on the shared layout (batch buffers bound here).
            const b_pool_sizes = [_]vk.VkDescriptorPoolSize{
                .{ .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 3 },
            };
            const b_pool_ci = vk.VkDescriptorPoolCreateInfo{ .maxSets = 1, .poolSizeCount = b_pool_sizes.len, .pPoolSizes = &b_pool_sizes };
            if (dev.vkCreateDescriptorPool(dev.handle, &b_pool_ci, null, &self.b_pool) != vk.VK_SUCCESS) break :blk false;
            const b_set_ai = vk.VkDescriptorSetAllocateInfo{ .descriptorPool = self.b_pool, .descriptorSetCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{self.set_layout} };
            if (dev.vkAllocateDescriptorSets(dev.handle, &b_set_ai, &self.b_set) != vk.VK_SUCCESS) break :blk false;
            const b_q_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = self.b_q_buf }};
            const b_o_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = self.b_o_buf }};
            const b_p_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = self.b_p_buf }};
            const b_writes = [_]vk.VkWriteDescriptorSet{
                .{ .dstSet = self.b_set, .dstBinding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &b_q_info },
                .{ .dstSet = self.b_set, .dstBinding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &b_o_info },
                .{ .dstSet = self.b_set, .dstBinding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &b_p_info },
            };
            dev.vkUpdateDescriptorSets(dev.handle, b_writes.len, &b_writes, 0, null);

            const b_mod_ci = vk.VkShaderModuleCreateInfo{ .codeSize = bth.words.len * 4, .pCode = &bth.words };
            if (dev.vkCreateShaderModule(dev.handle, &b_mod_ci, null, &self.b_mod) != vk.VK_SUCCESS) break :blk false;
            const b_stage = vk.VkPipelineShaderStageCreateInfo{
                .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .module = self.b_mod,
                .pName = "main",
            };
            const b_pipe_ci = vk.VkComputePipelineCreateInfo{ .stage = b_stage, .layout = self.pipe_layout };
            if (dev.vkCreateComputePipelines(dev.handle, vk.VK_NULL_HANDLE, 1, &b_pipe_ci, null, &self.b_pipeline) != vk.VK_SUCCESS) break :blk false;
            // Pre-record one command buffer per chunk count 1..16 from the
            // shared pool (freed with it in deinit, even on failure below).
            for (0..batch_cap) |k| {
                const ai = vk.VkCommandBufferAllocateInfo{ .commandPool = self.cmd_pool, .commandBufferCount = 1 };
                if (dev.vkAllocateCommandBuffers(dev.handle, &ai, &self.b_cmds[k]) != vk.VK_SUCCESS) break :blk false;
            }
            for (1..batch_cap + 1) |n| {
                if (!self.recordBatch(self.b_cmds[n - 1], @intCast(n))) break :blk false;
            }
            break :blk true;
        };
        if (!ok) {
            // Half-built batch objects must not leak into a worker that
            // keeps running on the N=1 path for the rest of the process.
            // Unmap only what mapped (ptrs null-init above; mems may be
            // valid-but-unmapped when a map call itself failed).
            if (self.b_q_ptr != null) dev.vkUnmapMemory(dev.handle, self.b_q_mem);
            if (self.b_o_ptr != null) dev.vkUnmapMemory(dev.handle, self.b_o_mem);
            if (self.b_p_ptr != null) dev.vkUnmapMemory(dev.handle, self.b_p_mem);
            dev.vkDestroyPipeline(dev.handle, self.b_pipeline, null);
            dev.vkDestroyShaderModule(dev.handle, self.b_mod, null);
            dev.vkDestroyDescriptorPool(dev.handle, self.b_pool, null);
            if (self.b_p_mem != vk.VK_NULL_HANDLE) dev.vkFreeMemory(dev.handle, self.b_p_mem, null);
            if (self.b_o_mem != vk.VK_NULL_HANDLE) dev.vkFreeMemory(dev.handle, self.b_o_mem, null);
            if (self.b_q_mem != vk.VK_NULL_HANDLE) dev.vkFreeMemory(dev.handle, self.b_q_mem, null);
            dev.vkDestroyBuffer(dev.handle, self.b_p_buf, null);
            dev.vkDestroyBuffer(dev.handle, self.b_o_buf, null);
            dev.vkDestroyBuffer(dev.handle, self.b_q_buf, null);
            // Leave batch_ok false; handles below are garbage-but-untouched
            // (deinit only runs the batch teardown when batch_ok is set).
            return false;
        }
        return true;
    }

    /// Release Vulkan objects. Does NOT free `self` — the owner that
    /// allocated it destroys it (GenPool.destroy / main boot path).
    pub fn deinit(self: *GpuFill) void {
        const dev = &self.dev;
        dev.vkUnmapMemory(dev.handle, self.p_mem);
        dev.vkUnmapMemory(dev.handle, self.o_mem);
        dev.vkUnmapMemory(dev.handle, self.q_mem);
        dev.vkDestroyFence(dev.handle, self.fence, null);
        dev.vkDestroyCommandPool(dev.handle, self.cmd_pool, null);
        dev.vkDestroyPipeline(dev.handle, self.pipeline, null);
        dev.vkDestroyShaderModule(dev.handle, self.mod, null);
        dev.vkDestroyPipelineLayout(dev.handle, self.pipe_layout, null);
        dev.vkDestroyDescriptorPool(dev.handle, self.pool, null);
        dev.vkDestroyDescriptorSetLayout(dev.handle, self.set_layout, null);
        dev.vkFreeMemory(dev.handle, self.p_mem, null);
        dev.vkFreeMemory(dev.handle, self.o_mem, null);
        dev.vkFreeMemory(dev.handle, self.q_mem, null);
        dev.vkDestroyBuffer(dev.handle, self.p_buf, null);
        dev.vkDestroyBuffer(dev.handle, self.o_buf, null);
        dev.vkDestroyBuffer(dev.handle, self.q_buf, null);
        if (self.batch_ok) {
            dev.vkUnmapMemory(dev.handle, self.b_p_mem);
            dev.vkUnmapMemory(dev.handle, self.b_o_mem);
            dev.vkUnmapMemory(dev.handle, self.b_q_mem);
            dev.vkDestroyPipeline(dev.handle, self.b_pipeline, null);
            dev.vkDestroyShaderModule(dev.handle, self.b_mod, null);
            dev.vkDestroyDescriptorPool(dev.handle, self.b_pool, null);
            dev.vkFreeMemory(dev.handle, self.b_p_mem, null);
            dev.vkFreeMemory(dev.handle, self.b_o_mem, null);
            dev.vkFreeMemory(dev.handle, self.b_q_mem, null);
            dev.vkDestroyBuffer(dev.handle, self.b_p_buf, null);
            dev.vkDestroyBuffer(dev.handle, self.b_o_buf, null);
            dev.vkDestroyBuffer(dev.handle, self.b_q_buf, null);
        }
        dev.destroy();
    }

    /// GpuFill one chunk: stage q, dispatch the threshold kernel (8 groups),
    /// convert the u32 output to ids. Returns false on ANY GPU problem
    /// (caller runs the CPU fillChunk — identical bytes either way).
    /// `sea`/`stone`/`water`/`air` select the output codes (must be the
    /// fillChunk alphabet or the tripwire below declines to CPU).
    pub fn fill(self: *GpuFill, q: []const f64, blocks: []ids_mod.Id, sea: i32, stone: u32, water: u32, air: u32) bool {
        if (q.len != th.q_len or blocks.len != th.cells) return self.fail("bad dims");
        const dev = &self.dev;
        // Stage inputs (coherent: no flush needed; barriers order visibility).
        @memcpy(@as([*]f64, @ptrCast(@alignCast(self.q_ptr)))[0..q.len], q);
        const pw = @as([*]u32, @ptrCast(@alignCast(self.p_ptr)))[0..th.ParamWords];
        pw[0] = @bitCast(sea);
        pw[1] = stone;
        pw[2] = water;
        pw[3] = air;

        // Pre-recorded dispatch: reset the persistent fence, submit, wait.
        // (Staging above is plain memcpy — the CB only references buffers,
        // so values flow through memory with no re-recording.)
        if (dev.vkResetFences(dev.handle, 1, &self.fence) != vk.VK_SUCCESS) return self.fail("fence-reset");
        const submit = vk.VkSubmitInfo{ .commandBufferCount = 1, .pCommandBuffers = &[_]vk.VkCommandBuffer{self.cmd} };
        if (dev.vkQueueSubmit(self.queue, 1, &submit, self.fence) != vk.VK_SUCCESS) return self.fail("submit");
        if (dev.vkWaitForFences(dev.handle, 1, &self.fence, 1, 5_000_000_000) != vk.VK_SUCCESS) return self.fail("fence-wait");

        // Convert with a tripwire: the kernel may only emit the three
        // staged codes; anything else means GPU-side corruption — decline
        // to CPU rather than write a poisoned id into the world.
        const got = @as([*]const u32, @ptrCast(@alignCast(self.o_ptr)))[0..blocks.len];
        for (got, blocks) |v, *b| {
            if (v == stone) {
                b.* = @enumFromInt(@as(u16, @intCast(stone)));
            } else if (v == water) {
                b.* = @enumFromInt(@as(u16, @intCast(water)));
            } else if (v == air) {
                b.* = @enumFromInt(@as(u16, @intCast(air)));
            } else {
                return self.fail("bad output code");
            }
        }
        _ = self.fills_ok.fetchAdd(1, .monotonic);
        return true;
    }

    /// Batched fill (v2 amortized path): N chunks' density fields in ONE
    /// dispatch of `8*N` groups + ONE fence wait. `qs`/`outs` are parallel
    /// (chunk-major layout in staging); same shared params + tripwire as
    /// `fill`. Returns false when batch objects are unavailable or on ANY
    /// GPU problem — the caller CPU-fills instead (identical bytes).
    pub fn fillBatch(self: *GpuFill, qs: []const []const f64, outs: []const []ids_mod.Id, sea: i32, stone: u32, water: u32, air: u32) bool {
        const n = qs.len;
        if (!self.batch_ok) return false;
        if (n == 0 or n > batch_cap or outs.len != n) return self.fail("bad batch dims");
        for (qs, outs) |q, o| {
            if (q.len != bth.Q_PER_CHUNK or o.len != bth.CELLS_PER_CHUNK) return self.fail("bad batch dims");
        }
        const dev = &self.dev;
        // Stage inputs chunk-major (probe-verified layout).
        const qd = @as([*]f64, @ptrCast(@alignCast(self.b_q_ptr.?)))[0 .. n * bth.Q_PER_CHUNK];
        for (qs, 0..) |q, i| @memcpy(qd[i * bth.Q_PER_CHUNK ..][0..bth.Q_PER_CHUNK], q);
        const pw = @as([*]u32, @ptrCast(@alignCast(self.b_p_ptr.?)))[0..th.ParamWords];
        pw[0] = @bitCast(sea);
        pw[1] = stone;
        pw[2] = water;
        pw[3] = air;

        // Pre-recorded N-chunk dispatch (recorded once at init).
        if (dev.vkResetFences(dev.handle, 1, &self.fence) != vk.VK_SUCCESS) return self.fail("fence-reset");
        const bcmd = self.b_cmds[n - 1];
        const submit = vk.VkSubmitInfo{ .commandBufferCount = 1, .pCommandBuffers = &[_]vk.VkCommandBuffer{bcmd} };
        if (dev.vkQueueSubmit(self.queue, 1, &submit, self.fence) != vk.VK_SUCCESS) return self.fail("submit");
        if (dev.vkWaitForFences(dev.handle, 1, &self.fence, 1, 5_000_000_000) != vk.VK_SUCCESS) return self.fail("fence-wait");

        // Per-chunk tripwire convert (same codes/or fail-closed as `fill`).
        const got = @as([*]const u32, @ptrCast(@alignCast(self.b_o_ptr.?)))[0 .. n * bth.CELLS_PER_CHUNK];
        for (outs, 0..) |o, i| {
            const g = got[i * bth.CELLS_PER_CHUNK ..][0..bth.CELLS_PER_CHUNK];
            for (g, o) |v, *b| {
                if (v == stone) {
                    b.* = @enumFromInt(@as(u16, @intCast(stone)));
                } else if (v == water) {
                    b.* = @enumFromInt(@as(u16, @intCast(water)));
                } else if (v == air) {
                    b.* = @enumFromInt(@as(u16, @intCast(air)));
                } else {
                    return self.fail("bad output code");
                }
            }
        }
        _ = self.fills_ok.fetchAdd(n, .monotonic);
        _ = self.batches_ok.fetchAdd(1, .monotonic);
        return true;
    }
};
