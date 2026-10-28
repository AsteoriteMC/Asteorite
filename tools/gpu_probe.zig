//! gpu-probe: standalone Vulkan headless-compute probe (G1 steps 4-5).
//!
//! Built via `zig build gpu-probe` (imports the `asteorite` module like
//! every other tool); run directly:
//!
//!   ./zig-out/bin/gpu_probe [--realq <file>|--batchq f1..fN [--groups G]]
//!
//! Stage 1 (probe): headless instance, device table, 1-queue compute
//! device with shaderFloat64. Exit 2 = no loader / device / compute queue
//! / float64 / host-coherent memory (soft fail).
//! Stage 2 (echo): dispatch the checked-in echo SPIR-V (1024 u32 copy)
//! and bit-compare GPU output vs CPU input. Any mismatch is a hard error.
//! Stage 3 (threshold): density-threshold kernel over soup q (default,
//! transcribed-`fillChunk` oracle, maximal edge sensitivity), `--realq`
//! <file> (one real chunk), or `--batchq` f1..fN (N real chunks, one
//! dispatch; `--batchq --groups G ...` caps dispatch size, diagnostic).
//! Bit-identical in every mode; any mismatch is a hard error.

const std = @import("std");
const vk = @import("asteorite").gpuvk;
const spv = @import("asteorite").gpuecho;
const th = @import("asteorite").gputhreshold;
const bth = @import("asteorite").gpubatch;

const APP_NAME = "asteorite-gpu-probe";

/// Non-trivial fill: catches lane shifts, truncation, and stale memory.
fn fillPattern(out: []u32) void {
    for (out, 0..) |*w, i| {
        w.* = @as(u32, @intCast(i)) *% 2654435761 +% 0x9e3779b9;
    }
}

fn firstMismatch(a: []const u32, b: []const u32) ?usize {
    for (a, b, 0..) |x, y, i| {
        if (x != y) return i;
    }
    return null;
}

fn vkCheck(r: vk.VkResult, what: []const u8) !void {
    if (r != vk.VK_SUCCESS) {
        std.debug.print("gpu-probe: {s} failed: {s}\n", .{ what, vk.resultName(r) });
        return error.VulkanFailed;
    }
}

fn runEcho(
    io: std.Io,
    out: *std.Io.Writer,
    inst: *const vk.Instance,
    phys: vk.VkPhysicalDevice,
    family: u32,
    dev: *vk.Device,
    q: vk.VkQueue,
) !void {
    const size: u64 = spv.byte_size;
    const props = inst.memoryProperties(phys);

    // --- buffers (one host-visible+coherent allocation each) ---
    const bci = vk.VkBufferCreateInfo{ .size = size, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
    var in_buf: vk.VkBuffer = undefined;
    try vkCheck(dev.vkCreateBuffer(dev.handle, &bci, null, &in_buf), "createBuffer in");
    defer dev.vkDestroyBuffer(dev.handle, in_buf, null);
    var out_buf: vk.VkBuffer = undefined;
    try vkCheck(dev.vkCreateBuffer(dev.handle, &bci, null, &out_buf), "createBuffer out");
    defer dev.vkDestroyBuffer(dev.handle, out_buf, null);

    var in_req: vk.VkMemoryRequirements = undefined;
    dev.vkGetBufferMemoryRequirements(dev.handle, in_buf, &in_req);
    const in_type = vk.findHostCoherentMemoryType(&props, in_req.memoryTypeBits) orelse {
        try out.print("gpu-probe: no host-coherent memory for input, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    const in_ai = vk.VkMemoryAllocateInfo{ .allocationSize = in_req.size, .memoryTypeIndex = in_type };
    var in_mem: vk.VkDeviceMemory = undefined;
    try vkCheck(dev.vkAllocateMemory(dev.handle, &in_ai, null, &in_mem), "alloc in");
    defer dev.vkFreeMemory(dev.handle, in_mem, null);
    try vkCheck(dev.vkBindBufferMemory(dev.handle, in_buf, in_mem, 0), "bind in");

    var out_req: vk.VkMemoryRequirements = undefined;
    dev.vkGetBufferMemoryRequirements(dev.handle, out_buf, &out_req);
    const out_type = vk.findHostCoherentMemoryType(&props, out_req.memoryTypeBits) orelse {
        try out.print("gpu-probe: no host-coherent memory for output, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    const out_ai = vk.VkMemoryAllocateInfo{ .allocationSize = out_req.size, .memoryTypeIndex = out_type };
    var out_mem: vk.VkDeviceMemory = undefined;
    try vkCheck(dev.vkAllocateMemory(dev.handle, &out_ai, null, &out_mem), "alloc out");
    defer dev.vkFreeMemory(dev.handle, out_mem, null);
    try vkCheck(dev.vkBindBufferMemory(dev.handle, out_buf, out_mem, 0), "bind out");

    // --- fill input on the host (coherent: no flush needed) ---
    var in_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, in_mem, 0, vk.VK_WHOLE_SIZE, 0, &in_ptr), "map in");
    const in_words = @as([*]u32, @ptrCast(@alignCast(in_ptr)))[0..spv.elem_count];
    fillPattern(in_words);
    // Poison output so a no-op dispatch can't false-pass.
    var out_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, out_mem, 0, vk.VK_WHOLE_SIZE, 0, &out_ptr), "map out");
    const out_poison = @as([*]u32, @ptrCast(@alignCast(out_ptr)))[0..spv.elem_count];
    @memset(out_poison, 0xdeadbeef);
    dev.vkUnmapMemory(dev.handle, out_mem);
    dev.vkUnmapMemory(dev.handle, in_mem);

    // --- descriptors: set 0 = {in @0, out @1} ---
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
        .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
    };
    const layout_ci = vk.VkDescriptorSetLayoutCreateInfo{ .bindingCount = bindings.len, .pBindings = &bindings };
    var set_layout: vk.VkDescriptorSetLayout = undefined;
    try vkCheck(dev.vkCreateDescriptorSetLayout(dev.handle, &layout_ci, null, &set_layout), "createSetLayout");
    defer dev.vkDestroyDescriptorSetLayout(dev.handle, set_layout, null);

    const pool_sizes = [_]vk.VkDescriptorPoolSize{
        .{ .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 },
    };
    const pool_ci = vk.VkDescriptorPoolCreateInfo{ .maxSets = 1, .poolSizeCount = pool_sizes.len, .pPoolSizes = &pool_sizes };
    var pool: vk.VkDescriptorPool = undefined;
    try vkCheck(dev.vkCreateDescriptorPool(dev.handle, &pool_ci, null, &pool), "createPool");
    defer dev.vkDestroyDescriptorPool(dev.handle, pool, null);

    const set_ai = vk.VkDescriptorSetAllocateInfo{ .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{set_layout} };
    var set: vk.VkDescriptorSet = undefined;
    try vkCheck(dev.vkAllocateDescriptorSets(dev.handle, &set_ai, &set), "allocSet");

    const in_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = in_buf }};
    const out_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = out_buf }};
    const writes = [_]vk.VkWriteDescriptorSet{
        .{ .dstSet = set, .dstBinding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &in_info },
        .{ .dstSet = set, .dstBinding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &out_info },
    };
    dev.vkUpdateDescriptorSets(dev.handle, writes.len, &writes, 0, null);

    // --- pipeline: layout + checked-in echo module ---
    const pipe_layout_ci = vk.VkPipelineLayoutCreateInfo{ .setLayoutCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{set_layout} };
    var pipe_layout: vk.VkPipelineLayout = undefined;
    try vkCheck(dev.vkCreatePipelineLayout(dev.handle, &pipe_layout_ci, null, &pipe_layout), "createPipeLayout");
    defer dev.vkDestroyPipelineLayout(dev.handle, pipe_layout, null);

    const mod_ci = vk.VkShaderModuleCreateInfo{ .codeSize = spv.words.len * 4, .pCode = &spv.words };
    var mod: vk.VkShaderModule = undefined;
    try vkCheck(dev.vkCreateShaderModule(dev.handle, &mod_ci, null, &mod), "createShaderModule");
    defer dev.vkDestroyShaderModule(dev.handle, mod, null);

    const stage = vk.VkPipelineShaderStageCreateInfo{
        .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = mod,
        .pName = "main",
    };
    const pipe_ci = vk.VkComputePipelineCreateInfo{ .stage = stage, .layout = pipe_layout };
    var pipeline: vk.VkPipeline = undefined;
    try vkCheck(dev.vkCreateComputePipelines(dev.handle, vk.VK_NULL_HANDLE, 1, &pipe_ci, null, &pipeline), "createComputePipeline");
    defer dev.vkDestroyPipeline(dev.handle, pipeline, null);

    // --- command buffer: host->shader barrier, dispatch 16x1x1, barrier back ---
    const pool_ci2 = vk.VkCommandPoolCreateInfo{ .queueFamilyIndex = family };
    var cmd_pool: vk.VkCommandPool = undefined;
    try vkCheck(dev.vkCreateCommandPool(dev.handle, &pool_ci2, null, &cmd_pool), "createCmdPool");
    defer dev.vkDestroyCommandPool(dev.handle, cmd_pool, null);
    const cmd_ai = vk.VkCommandBufferAllocateInfo{ .commandPool = cmd_pool, .commandBufferCount = 1 };
    var cmd: vk.VkCommandBuffer = undefined;
    try vkCheck(dev.vkAllocateCommandBuffers(dev.handle, &cmd_ai, &cmd), "allocCmd");

    const begin = vk.VkCommandBufferBeginInfo{ .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    try vkCheck(dev.vkBeginCommandBuffer(cmd, &begin), "beginCmd");
    const avail = [_]vk.VkBufferMemoryBarrier{
        .{
            .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .buffer = in_buf,
        },
    };
    dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_HOST_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, avail.len, &avail, 0, null);
    dev.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    dev.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipe_layout, 0, 1, &set, 0, null);
    dev.vkCmdDispatch(cmd, 16, 1, 1);
    const visible = [_]vk.VkBufferMemoryBarrier{
        .{
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
            .buffer = out_buf,
        },
    };
    dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, visible.len, &visible, 0, null);
    try vkCheck(dev.vkEndCommandBuffer(cmd), "endCmd");

    // --- submit + fence wait ---
    const fence_ci = vk.VkFenceCreateInfo{};
    var fence: vk.VkFence = undefined;
    try vkCheck(dev.vkCreateFence(dev.handle, &fence_ci, null, &fence), "createFence");
    defer dev.vkDestroyFence(dev.handle, fence, null);
    const submit = vk.VkSubmitInfo{ .commandBufferCount = 1, .pCommandBuffers = &[_]vk.VkCommandBuffer{cmd} };
    const t0 = std.Io.Timestamp.now(io, .awake);
    try vkCheck(dev.vkQueueSubmit(q, 1, &submit, fence), "queueSubmit");
    const wr = dev.vkWaitForFences(dev.handle, 1, &fence, 1, 5_000_000_000);
    try vkCheck(wr, "waitForFences");
    const t1 = std.Io.Timestamp.now(io, .awake);

    // --- read back + bit-compare ---
    var ro_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, out_mem, 0, vk.VK_WHOLE_SIZE, 0, &ro_ptr), "remap out");
    defer dev.vkUnmapMemory(dev.handle, out_mem);
    const got = @as([*]const u32, @ptrCast(@alignCast(ro_ptr)))[0..spv.elem_count];

    var expect: [spv.elem_count]u32 = undefined;
    fillPattern(&expect);
    if (firstMismatch(&expect, got)) |idx| {
        try out.print(
            "gpu-probe: ECHO MISMATCH at [{d}]: expect 0x{x:0>8} got 0x{x:0>8}\n",
            .{ idx, expect[idx], got[idx] },
        );
        try out.flush();
        return error.EchoMismatch;
    }
    const ns = t0.durationTo(t1).nanoseconds;
    try out.print(
        "gpu-probe: echo PASS ({d} u32 bit-identical, dispatch+wait {d} ns)\n",
        .{ spv.elem_count, @max(0, ns) },
    );
}

/// Test oracle: exact transcription of `Shaper.fillChunk` arithmetic
/// (src/worldgen/v5/shaper.zig), parameterized over the game constants the
/// shader receives through its params SSBO. Wiring time replaces this with
/// the real call; until then it is the bit-exactness reference — any drift
/// between this copy and the source fails the next golden run, loudly.
fn fillOracle(
    q: *const [th.q_len]f64,
    blocks: *[th.cells]u32,
    sea: i32,
    stone: u32,
    water: u32,
    air: u32,
) void {
    @memset(blocks, air);
    for (0..4) |i| {
        for (0..4) |j| {
            const n6 = (i * 5 + j) * 33;
            const n7 = (i * 5 + j + 1) * 33;
            const n8 = ((i + 1) * 5 + j) * 33;
            const n9 = ((i + 1) * 5 + j + 1) * 33;
            for (0..32) |cy| {
                var d2 = q[n6 + cy];
                var d3 = q[n7 + cy];
                var d4 = q[n8 + cy];
                var d5 = q[n9 + cy];
                const d6 = (q[n6 + cy + 1] - d2) * 0.125;
                const d7 = (q[n7 + cy + 1] - d3) * 0.125;
                const d8 = (q[n8 + cy + 1] - d4) * 0.125;
                const d9 = (q[n9 + cy + 1] - d5) * 0.125;
                for (0..8) |fy| {
                    var d11 = d2;
                    var d12 = d3;
                    const d13 = (d4 - d2) * 0.25;
                    const d14 = (d5 - d3) * 0.25;
                    for (0..4) |fx| {
                        var n10: i32 = @as(i32, @intCast(((fx + i * 4) << 12) | ((j * 4) << 8) | (cy * 8 + fy)));
                        n10 -= 256;
                        var d16 = d11;
                        const d17 = (d12 - d11) * 0.25;
                        d16 -= d17;
                        for (0..4) |_| {
                            d16 += d17;
                            n10 += 256;
                            const y: i32 = @intCast(cy * 8 + fy);
                            blocks[@as(usize, @intCast(n10))] = if (d16 > 0.0) stone else if (y < sea) water else air;
                        }
                        d11 += d13;
                        d12 += d14;
                    }
                    d2 += d6;
                    d3 += d7;
                    d4 += d8;
                    d5 += d9;
                }
            }
        }
    }
}

/// Bit-soup q: xorshift64* u64 stream reinterpreted as f64 (covers every
/// exponent/mantissa class incl. NaN/Inf/subnormals/+-0) plus pinned float
/// edges at the head. The oracle and the shader must agree on ALL of it —
/// especially the NaN/zero crossings of `d > 0.0`.
fn fillDensityQ(out: *[th.q_len]f64) void {
    const edges = [_]f64{ 0.0, -0.0, 5e-324, -5e-324, 1e-310, 1.0, -1.0, 0.1, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 63.0 };
    for (edges, 0..) |e, k| out[k] = e;
    var s: u64 = 0x243f6a8885a308d3;
    for (out[edges.len..], 0..) |*w, k| {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        const bits = s *% 2685821657736338717 +% @as(u64, @intCast(k));
        w.* = @bitCast(bits);
    }
}

/// Dispatch core shared by the soup/realq/batch modes.
/// `q_src` (N*825 f64) is staged verbatim; `expect` (N*65536 u32) is the
/// bit-exact reference. `shader`/`groups` select the kernel and dispatch
/// shape. `label` names the mode in reports.
fn runFillCore(
    io: std.Io,
    out: *std.Io.Writer,
    inst: *const vk.Instance,
    phys: vk.VkPhysicalDevice,
    family: u32,
    dev: *vk.Device,
    q: vk.VkQueue,
    q_src: []const f64,
    expect: []const u32,
    sea: i32,
    stone: u32,
    water: u32,
    air: u32,
    shader: []const u32,
    groups: u32,
    label: []const u8,
) !void {
    std.debug.assert(q_src.len % th.q_len == 0);
    std.debug.assert(expect.len == q_src.len / th.q_len * th.cells);
    const props = inst.memoryProperties(phys);

    const qbci = vk.VkBufferCreateInfo{ .size = q_src.len * 8, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
    const obci = vk.VkBufferCreateInfo{ .size = expect.len * 4, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
    const pbci = vk.VkBufferCreateInfo{ .size = th.ParamWords * 4, .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };

    var q_buf: vk.VkBuffer = undefined;
    try vkCheck(dev.vkCreateBuffer(dev.handle, &qbci, null, &q_buf), "createBuffer q");
    defer dev.vkDestroyBuffer(dev.handle, q_buf, null);
    var o_buf: vk.VkBuffer = undefined;
    try vkCheck(dev.vkCreateBuffer(dev.handle, &obci, null, &o_buf), "createBuffer out");
    defer dev.vkDestroyBuffer(dev.handle, o_buf, null);
    var p_buf: vk.VkBuffer = undefined;
    try vkCheck(dev.vkCreateBuffer(dev.handle, &pbci, null, &p_buf), "createBuffer params");
    defer dev.vkDestroyBuffer(dev.handle, p_buf, null);

    var q_req: vk.VkMemoryRequirements = undefined;
    dev.vkGetBufferMemoryRequirements(dev.handle, q_buf, &q_req);
    const q_type = vk.findHostCoherentMemoryType(&props, q_req.memoryTypeBits) orelse {
        try out.print("gpu-probe: no host-coherent memory for q, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    const q_ai = vk.VkMemoryAllocateInfo{ .allocationSize = q_req.size, .memoryTypeIndex = q_type };
    var q_mem: vk.VkDeviceMemory = undefined;
    try vkCheck(dev.vkAllocateMemory(dev.handle, &q_ai, null, &q_mem), "alloc q");
    defer dev.vkFreeMemory(dev.handle, q_mem, null);
    try vkCheck(dev.vkBindBufferMemory(dev.handle, q_buf, q_mem, 0), "bind q");

    var o_req: vk.VkMemoryRequirements = undefined;
    dev.vkGetBufferMemoryRequirements(dev.handle, o_buf, &o_req);
    const o_type = vk.findHostCoherentMemoryType(&props, o_req.memoryTypeBits) orelse {
        try out.print("gpu-probe: no host-coherent memory for out, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    const o_ai = vk.VkMemoryAllocateInfo{ .allocationSize = o_req.size, .memoryTypeIndex = o_type };
    var o_mem: vk.VkDeviceMemory = undefined;
    try vkCheck(dev.vkAllocateMemory(dev.handle, &o_ai, null, &o_mem), "alloc out");
    defer dev.vkFreeMemory(dev.handle, o_mem, null);
    try vkCheck(dev.vkBindBufferMemory(dev.handle, o_buf, o_mem, 0), "bind out");

    var p_req: vk.VkMemoryRequirements = undefined;
    dev.vkGetBufferMemoryRequirements(dev.handle, p_buf, &p_req);
    const p_type = vk.findHostCoherentMemoryType(&props, p_req.memoryTypeBits) orelse {
        try out.print("gpu-probe: no host-coherent memory for params, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    const p_ai = vk.VkMemoryAllocateInfo{ .allocationSize = p_req.size, .memoryTypeIndex = p_type };
    var p_mem: vk.VkDeviceMemory = undefined;
    try vkCheck(dev.vkAllocateMemory(dev.handle, &p_ai, null, &p_mem), "alloc params");
    defer dev.vkFreeMemory(dev.handle, p_mem, null);
    try vkCheck(dev.vkBindBufferMemory(dev.handle, p_buf, p_mem, 0), "bind params");

    // --- stage inputs: caller q verbatim, poisoned out, params ---
    var q_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, q_mem, 0, vk.VK_WHOLE_SIZE, 0, &q_ptr), "map q");
    const q_words = @as([*]f64, @ptrCast(@alignCast(q_ptr)))[0..q_src.len];
    @memcpy(q_words, q_src);
    dev.vkUnmapMemory(dev.handle, q_mem);

    var o_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, o_mem, 0, vk.VK_WHOLE_SIZE, 0, &o_ptr), "map out");
    const o_poison = @as([*]u32, @ptrCast(@alignCast(o_ptr)))[0..expect.len];
    @memset(o_poison, 0xdeadbeef);
    dev.vkUnmapMemory(dev.handle, o_mem);

    var p_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, p_mem, 0, vk.VK_WHOLE_SIZE, 0, &p_ptr), "map params");
    const p_words = @as([*]u32, @ptrCast(@alignCast(p_ptr)))[0..th.ParamWords];
    p_words[0] = @bitCast(sea);
    p_words[1] = stone;
    p_words[2] = water;
    p_words[3] = air;
    dev.vkUnmapMemory(dev.handle, p_mem);

    // --- descriptors: set 0 = {q @0, out @1, params @2} ---
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
        .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
        .{ .binding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT },
    };
    const layout_ci = vk.VkDescriptorSetLayoutCreateInfo{ .bindingCount = bindings.len, .pBindings = &bindings };
    var set_layout: vk.VkDescriptorSetLayout = undefined;
    try vkCheck(dev.vkCreateDescriptorSetLayout(dev.handle, &layout_ci, null, &set_layout), "createSetLayout th");
    defer dev.vkDestroyDescriptorSetLayout(dev.handle, set_layout, null);

    const pool_sizes = [_]vk.VkDescriptorPoolSize{
        .{ .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 3 },
    };
    const pool_ci = vk.VkDescriptorPoolCreateInfo{ .maxSets = 1, .poolSizeCount = pool_sizes.len, .pPoolSizes = &pool_sizes };
    var pool: vk.VkDescriptorPool = undefined;
    try vkCheck(dev.vkCreateDescriptorPool(dev.handle, &pool_ci, null, &pool), "createPool th");
    defer dev.vkDestroyDescriptorPool(dev.handle, pool, null);

    const set_ai = vk.VkDescriptorSetAllocateInfo{ .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{set_layout} };
    var set: vk.VkDescriptorSet = undefined;
    try vkCheck(dev.vkAllocateDescriptorSets(dev.handle, &set_ai, &set), "allocSet th");

    const q_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = q_buf }};
    const o_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = o_buf }};
    const p_info = [_]vk.VkDescriptorBufferInfo{.{ .buffer = p_buf }};
    const writes = [_]vk.VkWriteDescriptorSet{
        .{ .dstSet = set, .dstBinding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &q_info },
        .{ .dstSet = set, .dstBinding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &o_info },
        .{ .dstSet = set, .dstBinding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &p_info },
    };
    dev.vkUpdateDescriptorSets(dev.handle, writes.len, &writes, 0, null);

    // --- pipeline ---
    const pipe_layout_ci = vk.VkPipelineLayoutCreateInfo{ .setLayoutCount = 1, .pSetLayouts = &[_]vk.VkDescriptorSetLayout{set_layout} };
    var pipe_layout: vk.VkPipelineLayout = undefined;
    try vkCheck(dev.vkCreatePipelineLayout(dev.handle, &pipe_layout_ci, null, &pipe_layout), "createPipeLayout th");
    defer dev.vkDestroyPipelineLayout(dev.handle, pipe_layout, null);

    const mod_ci = vk.VkShaderModuleCreateInfo{ .codeSize = shader.len * 4, .pCode = shader.ptr };
    var mod: vk.VkShaderModule = undefined;
    try vkCheck(dev.vkCreateShaderModule(dev.handle, &mod_ci, null, &mod), "createShaderModule th");
    defer dev.vkDestroyShaderModule(dev.handle, mod, null);

    const stage = vk.VkPipelineShaderStageCreateInfo{
        .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = mod,
        .pName = "main",
    };
    const pipe_ci = vk.VkComputePipelineCreateInfo{ .stage = stage, .layout = pipe_layout };
    var pipeline: vk.VkPipeline = undefined;
    try vkCheck(dev.vkCreateComputePipelines(dev.handle, vk.VK_NULL_HANDLE, 1, &pipe_ci, null, &pipeline), "createComputePipeline th");
    defer dev.vkDestroyPipeline(dev.handle, pipeline, null);

    // --- record: host->shader on q+params, dispatch 8, shader->host on out ---
    const pool_ci2 = vk.VkCommandPoolCreateInfo{ .queueFamilyIndex = family };
    var cmd_pool: vk.VkCommandPool = undefined;
    try vkCheck(dev.vkCreateCommandPool(dev.handle, &pool_ci2, null, &cmd_pool), "createCmdPool th");
    defer dev.vkDestroyCommandPool(dev.handle, cmd_pool, null);
    const cmd_ai = vk.VkCommandBufferAllocateInfo{ .commandPool = cmd_pool, .commandBufferCount = 1 };
    var cmd: vk.VkCommandBuffer = undefined;
    try vkCheck(dev.vkAllocateCommandBuffers(dev.handle, &cmd_ai, &cmd), "allocCmd th");

    const begin = vk.VkCommandBufferBeginInfo{ .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    try vkCheck(dev.vkBeginCommandBuffer(cmd, &begin), "beginCmd th");
    const avail_q = [_]vk.VkBufferMemoryBarrier{
        .{
            .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .buffer = q_buf,
        },
    };
    dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_HOST_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, avail_q.len, &avail_q, 0, null);
    const avail_p = [_]vk.VkBufferMemoryBarrier{
        .{
            .srcAccessMask = vk.VK_ACCESS_HOST_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .buffer = p_buf,
        },
    };
    dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_HOST_BIT, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, avail_p.len, &avail_p, 0, null);
    dev.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    dev.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipe_layout, 0, 1, &set, 0, null);
    dev.vkCmdDispatch(cmd, groups, 1, 1);
    const visible = [_]vk.VkBufferMemoryBarrier{
        .{
            .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
            .buffer = o_buf,
        },
    };
    dev.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, visible.len, &visible, 0, null);
    try vkCheck(dev.vkEndCommandBuffer(cmd), "endCmd th");

    const fence_ci = vk.VkFenceCreateInfo{};
    var fence: vk.VkFence = undefined;
    try vkCheck(dev.vkCreateFence(dev.handle, &fence_ci, null, &fence), "createFence th");
    defer dev.vkDestroyFence(dev.handle, fence, null);
    const submit = vk.VkSubmitInfo{ .commandBufferCount = 1, .pCommandBuffers = &[_]vk.VkCommandBuffer{cmd} };
    const t0 = std.Io.Timestamp.now(io, .awake);
    try vkCheck(dev.vkQueueSubmit(q, 1, &submit, fence), "queueSubmit th");
    const t_submit = std.Io.Timestamp.now(io, .awake);
    const wr = dev.vkWaitForFences(dev.handle, 1, &fence, 1, 30_000_000_000);
    try vkCheck(wr, "waitForFences th");
    const t1 = std.Io.Timestamp.now(io, .awake);

    var ro_ptr: *anyopaque = undefined;
    try vkCheck(dev.vkMapMemory(dev.handle, o_mem, 0, vk.VK_WHOLE_SIZE, 0, &ro_ptr), "remap out th");
    defer dev.vkUnmapMemory(dev.handle, o_mem);
    const got = @as([*]const u32, @ptrCast(@alignCast(ro_ptr)))[0..expect.len];

    if (firstMismatch(expect, got)) |idx| {
        const ns = t0.durationTo(t1).nanoseconds;
        try out.print(
            "gpu-probe: THRESHOLD MISMATCH [{s}] at [{d}]: expect {d} got {d} (dispatch+wait {d} ns)\n",
            .{ label, idx, expect[idx], got[idx], @max(0, ns) },
        );
        try out.flush();
        return error.ThresholdMismatch;
    }
    const ns = t0.durationTo(t1).nanoseconds;
    const submit_ns = t0.durationTo(t_submit).nanoseconds;
    try out.print(
        "gpu-probe: threshold PASS [{s}] ({d} cells bit-identical, dispatch+wait {d} ns, submit {d} ns)\n",
        .{ label, expect.len, @max(0, ns), @max(0, submit_ns) },
    );
}

/// Soup mode: bit-soup q + transcribed-`fillChunk` oracle (kernel-level
/// proof, maximal float-edge sensitivity).
fn runThresholdSoup(
    io: std.Io,
    out: *std.Io.Writer,
    inst: *const vk.Instance,
    phys: vk.VkPhysicalDevice,
    family: u32,
    dev: *vk.Device,
    q: vk.VkQueue,
) !void {
    var soup: [th.q_len]f64 = undefined;
    fillDensityQ(&soup);
    var expect: [th.cells]u32 = undefined;
    fillOracle(&soup, &expect, 63, 1, 9, 0);
    try runFillCore(io, out, inst, phys, family, dev, q, &soup, &expect, 63, 1, 9, 0, &th.words, th.groups, "soup");
}

/// Real-q mode: q + expected blocks from a genq_dump file (game-data proof:
/// the q is JVM-verified via the shaper goldens, `expected` is the REAL
/// fillChunk output — no transcription involved on this path).
/// Open a probe input file: absolute paths directly, relative paths
/// against the process working directory.
fn openInput(io: std.Io, path: []const u8) std.Io.File.OpenError!std.Io.File {
    if (path.len > 0 and path[0] == '/') return std.Io.Dir.openFileAbsolute(io, path, .{});
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn runRealQ(
    io: std.Io,
    out: *std.Io.Writer,
    inst: *const vk.Instance,
    phys: vk.VkPhysicalDevice,
    family: u32,
    dev: *vk.Device,
    q: vk.VkQueue,
    path: []const u8,
) !void {
    var f = openInput(io, path) catch {
        try out.print("gpu-probe: cannot open {s}\n", .{path});
        try out.flush();
        return error.RealQOpen;
    };
    defer f.close(io);
    var fr_buf: [65536]u8 = undefined;
    var fr: std.Io.File.Reader = .initStreaming(f, io, &fr_buf);
    const r = &fr.interface;
    const magic = try r.takeInt(u32, .little);
    if (magic != 0x47514e44) {
        try out.print("gpu-probe: bad magic in {s}\n", .{path});
        try out.flush();
        return error.RealQMagic;
    }
    const q_len = try r.takeInt(u32, .little);
    const cells = try r.takeInt(u32, .little);
    if (q_len != th.q_len or cells != th.cells) {
        try out.print("gpu-probe: bad dims in {s}\n", .{path});
        try out.flush();
        return error.RealQDims;
    }
    const sea = try r.takeInt(u32, .little);
    const stone = try r.takeInt(u32, .little);
    const water = try r.takeInt(u32, .little);
    const air = try r.takeInt(u32, .little);
    var real_q: [th.q_len]f64 = undefined;
    for (&real_q) |*v| {
        v.* = @bitCast(try r.takeInt(u64, .little));
    }
    var expect: [th.cells]u32 = undefined;
    for (&expect) |*v| {
        v.* = try r.takeInt(u32, .little);
    }
    var label_buf: [256]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "realq {s}", .{path}) catch "realq";
    try runFillCore(io, out, inst, phys, family, dev, q, &real_q, &expect, @bitCast(sea), stone, water, air, &th.words, th.groups, label);
}

/// Batch mode: N real-q files in ONE dispatch (amortization proof).
/// Reads every file, asserts identical params, stages chunk-major q and
/// per-chunk expected, dispatches groupsFor(N) with the batch kernel.
/// `--groups G` (debug/diagnostic only) caps the dispatch size to isolate
/// driver scaling cliffs; uncomputed tail chunks then mismatch by design.
fn runBatch(
    io: std.Io,
    out: *std.Io.Writer,
    inst: *const vk.Instance,
    phys: vk.VkPhysicalDevice,
    family: u32,
    dev: *vk.Device,
    q: vk.VkQueue,
    paths: []const []const u8,
    arena: std.mem.Allocator,
    groups_override: ?u32,
) !void {
    const n = paths.len;
    if (n == 0 or n > bth.MAXBATCH) {
        try out.print("gpu-probe: --batchq needs 1..{d} files\n", .{bth.MAXBATCH});
        try out.flush();
        return error.BatchCount;
    }
    const q_all = try arena.alloc(f64, n * bth.Q_PER_CHUNK);
    const expect_all = try arena.alloc(u32, n * bth.CELLS_PER_CHUNK);
    var sea0: u32 = 0;
    var stone0: u32 = 0;
    var water0: u32 = 0;
    var air0: u32 = 0;
    for (paths, 0..) |path, k| {
        var f = openInput(io, path) catch {
            try out.print("gpu-probe: cannot open {s}\n", .{path});
            try out.flush();
            return error.RealQOpen;
        };
        defer f.close(io);
        var fr_buf: [65536]u8 = undefined;
        var fr: std.Io.File.Reader = .initStreaming(f, io, &fr_buf);
        const r = &fr.interface;
        if ((try r.takeInt(u32, .little)) != 0x47514e44) {
            try out.print("gpu-probe: bad magic in {s}\n", .{path});
            try out.flush();
            return error.RealQMagic;
        }
        if ((try r.takeInt(u32, .little)) != th.q_len or (try r.takeInt(u32, .little)) != th.cells) {
            try out.print("gpu-probe: bad dims in {s}\n", .{path});
            try out.flush();
            return error.RealQDims;
        }
        const sea = try r.takeInt(u32, .little);
        const stone = try r.takeInt(u32, .little);
        const water = try r.takeInt(u32, .little);
        const air = try r.takeInt(u32, .little);
        if (k == 0) {
            sea0 = sea;
            stone0 = stone;
            water0 = water;
            air0 = air;
        } else if (sea != sea0 or stone != stone0 or water != water0 or air != air0) {
            try out.print("gpu-probe: param mismatch in {s} (batch needs uniform params)\n", .{path});
            try out.flush();
            return error.BatchParams;
        }
        const qk = q_all[k * bth.Q_PER_CHUNK ..][0..bth.Q_PER_CHUNK];
        for (qk) |*v| v.* = @bitCast(try r.takeInt(u64, .little));
        const ek = expect_all[k * bth.CELLS_PER_CHUNK ..][0..bth.CELLS_PER_CHUNK];
        for (ek) |*v| v.* = try r.takeInt(u32, .little);
    }
    var label_buf: [512]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "batchN={d}", .{n}) catch "batchN=?";
    const groups = groups_override orelse bth.groupsFor(@intCast(n));
    try runFillCore(io, out, inst, phys, family, dev, q, q_all, expect_all, @bitCast(sea0), stone0, water0, air0, &bth.words, groups, label);
}

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const out = &stdout_file.interface;

    var loader = vk.Loader.open() catch |err| switch (err) {
        error.NoVulkanLibrary => {
            try out.print("gpu-probe: no Vulkan loader found (tried {d} paths), GPU unavailable\n", .{vk.lib_candidates.len});
            try out.flush();
            std.process.exit(2);
        },
        else => return err,
    };
    defer loader.close();
    try out.print("gpu-probe: loader {s}\n", .{loader.lib_path});

    var inst = loader.createHeadlessInstance(APP_NAME) catch {
        try out.print("gpu-probe: vkCreateInstance failed, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    defer inst.destroy();

    const n = try inst.deviceCount();
    try out.print("gpu-probe: {d} physical device(s)\n", .{n});
    if (n == 0) {
        try out.flush();
        std.process.exit(2);
    }

    const max_devs = 16;
    var devs: [max_devs]vk.VkPhysicalDevice = undefined;
    const ngot = try inst.enumDevices(devs[0..@min(n, max_devs)]);

    var scratch: [vk.device_id_scratch_bytes]u8 align(4) = undefined;
    var families: [32]vk.VkQueueFamilyProperties = undefined;
    var best: ?usize = null;
    var best_tier: u8 = 255;

    for (devs[0..ngot], 0..) |phys, i| {
        const id = inst.getDeviceId(phys, &scratch);
        const name = std.mem.sliceTo(id.deviceName[0..], 0);
        const fam = inst.pickComputeFamily(phys, &families);
        const nfam = inst.familyCount(phys);
        var famq: [32]u32 = [_]u32{0} ** 32;
        if (nfam > 0 and nfam <= families.len) {
            var m: u32 = nfam;
            inst.vkGetPhysicalDeviceQueueFamilyProperties(phys, &m, &families);
            for (families[0..m], 0..) |f, k| famq[k] = f.queueCount;
        }
        const tier: u8 = switch (id.deviceType) {
            .discrete_gpu => 0,
            .integrated_gpu => 1,
            .virtual_gpu => 2,
            .cpu => 3,
            else => 4,
        };
        try out.print(
            "dev {d}: type={s} vendor=0x{x:0>4} dev=0x{x:0>4} api={d}.{d}.{d} families={d} qcounts={any} compute_family={any} name={s}\n",
            .{
                i,
                id.deviceType.name(),
                id.vendorID,
                id.deviceID,
                id.apiVersion >> 22,
                (id.apiVersion >> 12) & 0x3ff,
                id.apiVersion & 0xfff,
                nfam,
                famq[0..@min(nfam, families.len)],
                fam,
                name,
            },
        );
        // Prefer discrete > integrated > virtual > CPU > other; first wins
        // within a tier (device order is driver-defined anyway).
        if (fam != null and tier < best_tier) {
            best = i;
            best_tier = tier;
        }
    }

    if (best == null) {
        try out.print("gpu-probe: no compute queue on any device, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    }
    try out.flush();

    // Prove the full headless path: logical device + queue acquisition.
    // shaderFloat64 is required from here on (threshold kernel); request
    // the queried feature set with float64 forced. A zero bit here means
    // the device genuinely lacks f64 (soft fail, not a binding bug).
    const phys = devs[best.?];
    const fam = inst.pickComputeFamily(phys, &families) orelse unreachable;
    const feats = inst.features(phys);
    try out.print("gpu-probe: shaderFloat64={d}\n", .{feats[vk.VK_FEATURE_SHADER_FLOAT64]});
    if (feats[vk.VK_FEATURE_SHADER_FLOAT64] == 0) {
        try out.print("gpu-probe: no float64 support, GPU unavailable\n", .{});
        try out.flush();
        std.process.exit(2);
    }
    var dev = try inst.createComputeDeviceWithFeatures(phys, fam, 1.0, &feats);
    defer dev.destroy();
    const q = dev.queue(fam, 0);
    try out.print("gpu-probe: device+queue ok on dev {d} family {d}\n", .{ best.?, fam });

    // Stage 2: echo dispatch + bit-compare.
    try runEcho(init.io, out, &inst, phys, fam, &dev, q);
    // Stage 3: threshold dispatch. Default is the soup oracle; `--realq`
    // <file> proves one real game chunk; `--batchq` f1..fN proves N chunks
    // in one dispatch (amortization curve).
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--realq")) {
        try runRealQ(init.io, out, &inst, phys, fam, &dev, q, args[2]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "--batchq")) {
        var file_args = args[2..];
        var groups_override: ?u32 = null;
        if (file_args.len >= 2 and std.mem.eql(u8, file_args[0], "--groups")) {
            groups_override = try std.fmt.parseInt(u32, file_args[1], 0);
            file_args = file_args[2..];
        }
        try runBatch(init.io, out, &inst, phys, fam, &dev, q, file_args, init.arena.allocator(), groups_override);
    } else {
        try runThresholdSoup(init.io, out, &inst, phys, fam, &dev, q);
    }
    try out.flush();
}
