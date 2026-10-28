//! Minimal Vulkan loader for G1 headless compute (unwired, see README.md).
//!
//! Design notes (from the G1 plan):
//! - No system header: `/usr/include/vulkan/` is absent on this box, so
//!   `cImport(<vulkan/vulkan.h>)` is not an option. Hand-written `extern`
//!   decls + `dlopen("libvulkan.so.1")` cover only the compute-path symbols
//!   we use (~10). Nothing links at build time; a missing driver is a soft
//!   runtime decline, never a build or boot failure.
//! - `std.DynLib` is NOT used: test binaries lack dynamic-linking info and
//!   fail with `MissingDynamicLinkingInformation`. Raw `dlopen`/`dlsym`
//!   externs + `-lc` (or wiring-time `exe.linkLibC()`) is the working path,
//!   verified on this box.
//! - Candidate lib paths are tried in order: `/lib/` here is 32-bit
//!   multilib (dlopen reports `wrong ELF class`), so a hardcoded absolute
//!   path breaks. `libvulkan.so.1` via the linker search path works, with
//!   `/usr/lib64/` and the Debian multiarch path as fallbacks.
//! - Function resolution follows the three tiers, enforced by the type
//!   system: `Loader` (global, null instance) can only create instances;
//!   `Instance` (GIPA with a live instance) enumerates devices; `Device`
//!   (GDPA with a live device) owns queues. GIPA(null) returns ONLY global
//!   functions — loading the rest against null silently yields null on
//!   conformant drivers (caught by test, not by luck).
//! - Only dispatchable handles (`Instance/PhysicalDevice/Device/Queue` =
//!   pointers) appear so far; non-dispatchable handles come with the first
//!   real dispatch (buffers/memory/pipelines) and stay `u64`.
//!
//! Bit-identical rule (hard, per plan): the loader contributes no numerics,
//! and every future kernel behind it must reproduce CPU bytes exactly —
//! integer-exact stages first, no float reimplementation of the noise core.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// C dynamic loader (libc). Caller links `-lc` (standalone) or sets
// `exe.linkLibC()` at wiring time.
// ---------------------------------------------------------------------------

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;

const RTLD_LAZY: c_int = 1;

// ---------------------------------------------------------------------------
// Result codes (subset used; full list lives in the Vulkan spec).
// ---------------------------------------------------------------------------

pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;
pub const VK_NOT_READY: VkResult = 1;
pub const VK_TIMEOUT: VkResult = 2;
pub const VK_INCOMPLETE: VkResult = 5;
pub const VK_ERROR_OUT_OF_HOST_MEMORY: VkResult = -1;
pub const VK_ERROR_OUT_OF_DEVICE_MEMORY: VkResult = -2;
pub const VK_ERROR_INITIALIZATION_FAILED: VkResult = -3;
pub const VK_ERROR_DEVICE_LOST: VkResult = -4;
pub const VK_ERROR_MEMORY_MAP_FAILED: VkResult = -5;
pub const VK_ERROR_LAYER_NOT_PRESENT: VkResult = -6;
pub const VK_ERROR_EXTENSION_NOT_PRESENT: VkResult = -7;
pub const VK_ERROR_FEATURE_NOT_PRESENT: VkResult = -8;
pub const VK_ERROR_INCOMPATIBLE_DRIVER: VkResult = -9;

pub fn resultName(r: VkResult) []const u8 {
    return switch (r) {
        VK_SUCCESS => "SUCCESS",
        VK_NOT_READY => "NOT_READY",
        VK_TIMEOUT => "TIMEOUT",
        VK_INCOMPLETE => "INCOMPLETE",
        VK_ERROR_OUT_OF_HOST_MEMORY => "OUT_OF_HOST_MEMORY",
        VK_ERROR_OUT_OF_DEVICE_MEMORY => "OUT_OF_DEVICE_MEMORY",
        VK_ERROR_INITIALIZATION_FAILED => "INITIALIZATION_FAILED",
        VK_ERROR_DEVICE_LOST => "DEVICE_LOST",
        VK_ERROR_MEMORY_MAP_FAILED => "MEMORY_MAP_FAILED",
        VK_ERROR_LAYER_NOT_PRESENT => "LAYER_NOT_PRESENT",
        VK_ERROR_EXTENSION_NOT_PRESENT => "EXTENSION_NOT_PRESENT",
        VK_ERROR_FEATURE_NOT_PRESENT => "FEATURE_NOT_PRESENT",
        VK_ERROR_INCOMPATIBLE_DRIVER => "INCOMPATIBLE_DRIVER",
        else => "UNKNOWN",
    };
}

// ---------------------------------------------------------------------------
// Handles (dispatchable = pointers; null only where the API allows it).
// ---------------------------------------------------------------------------

pub const VkInstance = *opaque {};
pub const VkPhysicalDevice = *opaque {};
pub const VkDevice = *opaque {};
pub const VkQueue = *opaque {};

/// Non-dispatchable handles are u64 (`VK_NULL_HANDLE` == 0).
pub const VkBuffer = u64;
pub const VkDeviceMemory = u64;
pub const VkDescriptorSetLayout = u64;
pub const VkDescriptorPool = u64;
pub const VkDescriptorSet = u64;
pub const VkPipelineLayout = u64;
pub const VkShaderModule = u64;
pub const VkPipeline = u64;
pub const VkCommandPool = u64;
pub const VkCommandBuffer = u64;
pub const VkFence = u64;

// ---------------------------------------------------------------------------
// Structure types + misc constants.
// ---------------------------------------------------------------------------

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: i32 = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: i32 = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: i32 = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: i32 = 3;

pub const VK_QUEUE_GRAPHICS_BIT: u32 = 0x00000001;
pub const VK_QUEUE_COMPUTE_BIT: u32 = 0x00000002;
pub const VK_QUEUE_TRANSFER_BIT: u32 = 0x00000004;

// --- G1 dispatch tier (echo kernel + future integer-exact combines) ---

pub const VK_NULL_HANDLE: u64 = 0;
pub const VK_WHOLE_SIZE: u64 = 0xFFFFFFFFFFFFFFFF;
pub const VK_QUEUE_FAMILY_IGNORED: u32 = 0xFFFFFFFF;

pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;
pub const VK_MEMORY_PROPERTY_HOST_CACHED_BIT: u32 = 0x00000008;

pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x00000020;
pub const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;

pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;
pub const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;

pub const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 1;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;

pub const VK_ACCESS_SHADER_READ_BIT: u32 = 0x00000020;
pub const VK_ACCESS_SHADER_WRITE_BIT: u32 = 0x00000040;
pub const VK_ACCESS_HOST_READ_BIT: u32 = 0x00002000;
pub const VK_ACCESS_HOST_WRITE_BIT: u32 = 0x00008000;

pub const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT: u32 = 0x00000800;
pub const VK_PIPELINE_STAGE_HOST_BIT: u32 = 0x00004000;

pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: i32 = 4;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: i32 = 5;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO: i32 = 8;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: i32 = 12;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: i32 = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: i32 = 18;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: i32 = 29;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: i32 = 30;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: i32 = 32;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: i32 = 33;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: i32 = 34;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: i32 = 35;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: i32 = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: i32 = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: i32 = 42;
pub const VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER: i32 = 44;

/// VkPhysicalDeviceFeatures is N VkBool32 in fixed spec order (Vulkan 1.0).
/// Count and shaderFloat64 index verified against `vulkaninfo` ground truth
/// on this box (55 members; the struct has no texel-buffer dynamic-indexing
/// pair and includes the 7-member depthClamp block — both easy to
/// misremember, and either mistake shifts every later index).
/// Enabling shaderFloat64 is mandatory before any Float64 capability use
/// (without it, F64 pipeline creation fails or miscompiles).
pub const VK_DEVICE_FEATURE_COUNT: usize = 55;
pub const VK_FEATURE_SHADER_FLOAT64: usize = 39;

pub const VkPhysicalDeviceType = enum(i32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
    _,

    pub fn name(self: VkPhysicalDeviceType) []const u8 {
        return switch (self) {
            .other => "OTHER",
            .integrated_gpu => "INTEGRATED_GPU",
            .discrete_gpu => "DISCRETE_GPU",
            .virtual_gpu => "VIRTUAL_GPU",
            .cpu => "CPU",
            _ => "UNKNOWN",
        };
    }
};

/// `VK_MAKE_VERSION(1,0,0)`. Headless compute targets 1.0 for max driver
/// compat (lavapipe, older proprietary drivers); 1.x features are opt-in.
pub const VK_API_VERSION_1_0: u32 = (1 << 22);

// ---------------------------------------------------------------------------
// Structs (extern layout == C ABI; field order verified against the spec).
// ---------------------------------------------------------------------------

pub const VkApplicationInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_APPLICATION_INFO,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = VK_API_VERSION_1_0,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pApplicationInfo: ?*const VkApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32 = 0,
    queueCount: u32 = 0,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueCreateInfoCount: u32 = 0,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo = undefined,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: [3]u32,
};

// --- G1 dispatch tier structs (extern layout == C ABI) ---

pub const VkMemoryType = extern struct {
    propertyFlags: u32,
    heapIndex: u32,
};

pub const VkMemoryHeap = extern struct {
    size: u64,
    flags: u32,
};

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

/// First host-visible + coherent type index, or null (soft-fail trigger:
/// integrated/UMA parts always have one; a discrete-only heap layout
/// declines the job to CPU instead of staging through invisible memory).
pub fn findHostCoherentMemoryType(
    props: *const VkPhysicalDeviceMemoryProperties,
    type_bits: u32,
) ?u32 {
    const want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    var i: u32 = 0;
    while (i < props.memoryTypeCount and i < 32) : (i += 1) {
        const t = props.memoryTypes[i];
        if ((type_bits & (@as(u32, 1) << @intCast(i))) != 0 and
            (t.propertyFlags & want) == want)
        {
            return i;
        }
    }
    return null;
}

/// Readback-friendly twin of findHostCoherentMemoryType: prefers a
/// HOST_CACHED heap (CPU reads of GPU output go through the cache instead
/// of uncached BAR/WC mappings, which stalled the v1 tripwire at ~45ms per
/// 2MB readback on discrete RADV). Falls back to null (caller uses the
/// coherent picker) where no cached host-visible heap exists.
pub fn findHostCachedMemoryType(
    props: *const VkPhysicalDeviceMemoryProperties,
    type_bits: u32,
) ?u32 {
    const want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    var i: u32 = 0;
    while (i < props.memoryTypeCount and i < 32) : (i += 1) {
        const t = props.memoryTypes[i];
        if ((type_bits & (@as(u32, 1) << @intCast(i))) != 0 and
            (t.propertyFlags & want) == want)
        {
            return i;
        }
    }
    return null;
}

pub const VkBufferCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharingMode: u32 = VK_SHARING_MODE_EXCLUSIVE,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

pub const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque = null,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    setLayoutCount: u32,
    pSetLayouts: [*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?*const anyopaque = null,
};

pub const VkShaderModuleCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque = null,
};

pub const VkComputePipelineCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: VkPipeline = VK_NULL_HANDLE,
    basePipelineIndex: i32 = -1,
};

pub const VkDescriptorPoolSize = extern struct {
    descriptorType: u32,
    descriptorCount: u32,
};

pub const VkDescriptorPoolCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};

pub const VkDescriptorSetAllocateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};

pub const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: u64 = 0,
    range: u64 = VK_WHOLE_SIZE,
};

pub const VkWriteDescriptorSet = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    pNext: ?*const anyopaque = null,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32 = 0,
    descriptorCount: u32 = 1,
    descriptorType: u32,
    pImageInfo: ?*const anyopaque = null,
    pBufferInfo: [*]const VkDescriptorBufferInfo,
    pTexelBufferView: ?*const anyopaque = null,
};

pub const VkCommandPoolCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool,
    level: u32 = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    commandBufferCount: u32,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pInheritanceInfo: ?*const anyopaque = null,
};

pub const VkSubmitInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?*const anyopaque = null,
    pWaitDstStageMask: ?*const u32 = null,
    commandBufferCount: u32,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?*const anyopaque = null,
};

pub const VkFenceCreateInfo = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const VkBufferMemoryBarrier = extern struct {
    sType: i32 = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32,
    dstAccessMask: u32,
    srcQueueFamilyIndex: u32 = VK_QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex: u32 = VK_QUEUE_FAMILY_IGNORED,
    buffer: VkBuffer,
    offset: u64 = 0,
    size: u64 = VK_WHOLE_SIZE,
};

/// Leading prefix of `VkPhysicalDeviceProperties`. The full struct's tail
/// (`limits`, `sparseProperties`) is large and version-dependent, so instead
/// of declaring it we read through this prefix from an oversized buffer
/// (see `Instance.getDeviceId`). The prefix fields (through `deviceName`)
/// have been stable since Vulkan 1.0.
pub const DeviceIdPrefix = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: VkPhysicalDeviceType,
    deviceName: [256]u8,
};

/// Scratch size for `getDeviceId`. The real struct is ~1KB on 1.x drivers;
/// 8KB leaves an order of magnitude of headroom against future growth.
pub const device_id_scratch_bytes: usize = 8192;

// ---------------------------------------------------------------------------
// Function pointer types.
// ---------------------------------------------------------------------------

pub const PFN_vkGetInstanceProcAddr = *const fn (
    instance: ?VkInstance,
    name: [*:0]const u8,
) callconv(.c) ?*anyopaque;

pub const PFN_vkGetDeviceProcAddr = *const fn (
    device: VkDevice,
    name: [*:0]const u8,
) callconv(.c) ?*anyopaque;

pub const PFN_vkCreateInstance = *const fn (
    pCreateInfo: *const VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: *VkInstance,
) callconv(.c) VkResult;

pub const PFN_vkDestroyInstance = *const fn (
    instance: VkInstance,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkEnumeratePhysicalDevices = *const fn (
    instance: VkInstance,
    pCount: *u32,
    pDevices: ?[*]VkPhysicalDevice,
) callconv(.c) VkResult;

pub const PFN_vkGetPhysicalDeviceProperties = *const fn (
    device: VkPhysicalDevice,
    pProperties: *anyopaque,
) callconv(.c) void;

pub const PFN_vkGetPhysicalDeviceQueueFamilyProperties = *const fn (
    device: VkPhysicalDevice,
    pCount: *u32,
    pProps: ?[*]VkQueueFamilyProperties,
) callconv(.c) void;

pub const PFN_vkGetPhysicalDeviceFeatures = *const fn (
    device: VkPhysicalDevice,
    pFeatures: *[VK_DEVICE_FEATURE_COUNT]u32,
) callconv(.c) void;

pub const PFN_vkCreateDevice = *const fn (
    phys: VkPhysicalDevice,
    pCreateInfo: *const VkDeviceCreateInfo,
    pAllocator: ?*const anyopaque,
    pDevice: *VkDevice,
) callconv(.c) VkResult;

pub const PFN_vkDestroyDevice = *const fn (
    device: VkDevice,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkGetDeviceQueue = *const fn (
    device: VkDevice,
    queueFamilyIndex: u32,
    queueIndex: u32,
    pQueue: *VkQueue,
) callconv(.c) void;

// --- G1 dispatch tier: instance-level first (physical-device queries) ---

pub const PFN_vkGetPhysicalDeviceMemoryProperties = *const fn (
    device: VkPhysicalDevice,
    pProperties: *VkPhysicalDeviceMemoryProperties,
) callconv(.c) void;

// --- G1 dispatch tier: device-level (resolved via vkGetDeviceProcAddr) ---

pub const PFN_vkCreateBuffer = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkBufferCreateInfo,
    pAllocator: ?*const anyopaque,
    pBuffer: *VkBuffer,
) callconv(.c) VkResult;

pub const PFN_vkDestroyBuffer = *const fn (
    device: VkDevice,
    buffer: VkBuffer,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkGetBufferMemoryRequirements = *const fn (
    device: VkDevice,
    buffer: VkBuffer,
    pRequirements: *VkMemoryRequirements,
) callconv(.c) void;

pub const PFN_vkAllocateMemory = *const fn (
    device: VkDevice,
    pAllocateInfo: *const VkMemoryAllocateInfo,
    pAllocator: ?*const anyopaque,
    pMemory: *VkDeviceMemory,
) callconv(.c) VkResult;

pub const PFN_vkFreeMemory = *const fn (
    device: VkDevice,
    memory: VkDeviceMemory,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkBindBufferMemory = *const fn (
    device: VkDevice,
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    memoryOffset: u64,
) callconv(.c) VkResult;

pub const PFN_vkMapMemory = *const fn (
    device: VkDevice,
    memory: VkDeviceMemory,
    offset: u64,
    size: u64,
    flags: u32,
    ppData: **anyopaque,
) callconv(.c) VkResult;

pub const PFN_vkUnmapMemory = *const fn (
    device: VkDevice,
    memory: VkDeviceMemory,
) callconv(.c) void;

pub const PFN_vkCreateDescriptorSetLayout = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkDescriptorSetLayoutCreateInfo,
    pAllocator: ?*const anyopaque,
    pSetLayout: *VkDescriptorSetLayout,
) callconv(.c) VkResult;

pub const PFN_vkDestroyDescriptorSetLayout = *const fn (
    device: VkDevice,
    setLayout: VkDescriptorSetLayout,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkCreateDescriptorPool = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkDescriptorPoolCreateInfo,
    pAllocator: ?*const anyopaque,
    pPool: *VkDescriptorPool,
) callconv(.c) VkResult;

pub const PFN_vkDestroyDescriptorPool = *const fn (
    device: VkDevice,
    pool: VkDescriptorPool,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkAllocateDescriptorSets = *const fn (
    device: VkDevice,
    pAllocateInfo: *const VkDescriptorSetAllocateInfo,
    pSets: *VkDescriptorSet,
) callconv(.c) VkResult;

pub const PFN_vkUpdateDescriptorSets = *const fn (
    device: VkDevice,
    descriptorWriteCount: u32,
    pDescriptorWrites: [*]const VkWriteDescriptorSet,
    descriptorCopyCount: u32,
    pDescriptorCopies: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkCreatePipelineLayout = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkPipelineLayoutCreateInfo,
    pAllocator: ?*const anyopaque,
    pLayout: *VkPipelineLayout,
) callconv(.c) VkResult;

pub const PFN_vkDestroyPipelineLayout = *const fn (
    device: VkDevice,
    layout: VkPipelineLayout,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkCreateShaderModule = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkShaderModuleCreateInfo,
    pAllocator: ?*const anyopaque,
    pModule: *VkShaderModule,
) callconv(.c) VkResult;

pub const PFN_vkDestroyShaderModule = *const fn (
    device: VkDevice,
    module: VkShaderModule,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkCreateComputePipelines = *const fn (
    device: VkDevice,
    pipelineCache: VkPipeline,
    createInfoCount: u32,
    pCreateInfos: *const VkComputePipelineCreateInfo,
    pAllocator: ?*const anyopaque,
    pPipelines: *VkPipeline,
) callconv(.c) VkResult;

pub const PFN_vkDestroyPipeline = *const fn (
    device: VkDevice,
    pipeline: VkPipeline,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkCreateCommandPool = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkCommandPoolCreateInfo,
    pAllocator: ?*const anyopaque,
    pPool: *VkCommandPool,
) callconv(.c) VkResult;

pub const PFN_vkDestroyCommandPool = *const fn (
    device: VkDevice,
    pool: VkCommandPool,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkAllocateCommandBuffers = *const fn (
    device: VkDevice,
    pAllocateInfo: *const VkCommandBufferAllocateInfo,
    pCommandBuffers: *VkCommandBuffer,
) callconv(.c) VkResult;

pub const PFN_vkBeginCommandBuffer = *const fn (
    commandBuffer: VkCommandBuffer,
    pBeginInfo: *const VkCommandBufferBeginInfo,
) callconv(.c) VkResult;

pub const PFN_vkEndCommandBuffer = *const fn (
    commandBuffer: VkCommandBuffer,
) callconv(.c) VkResult;

pub const PFN_vkCmdBindPipeline = *const fn (
    commandBuffer: VkCommandBuffer,
    pipelineBindPoint: u32,
    pipeline: VkPipeline,
) callconv(.c) void;

pub const PFN_vkCmdBindDescriptorSets = *const fn (
    commandBuffer: VkCommandBuffer,
    pipelineBindPoint: u32,
    layout: VkPipelineLayout,
    firstSet: u32,
    descriptorSetCount: u32,
    pDescriptorSets: *const VkDescriptorSet,
    dynamicOffsetCount: u32,
    pDynamicOffsets: ?*const u32,
) callconv(.c) void;

pub const PFN_vkCmdDispatch = *const fn (
    commandBuffer: VkCommandBuffer,
    groupCountX: u32,
    groupCountY: u32,
    groupCountZ: u32,
) callconv(.c) void;

pub const PFN_vkCmdPipelineBarrier = *const fn (
    commandBuffer: VkCommandBuffer,
    srcStageMask: u32,
    dstStageMask: u32,
    dependencyFlags: u32,
    memoryBarrierCount: u32,
    pMemoryBarriers: ?*const anyopaque,
    bufferMemoryBarrierCount: u32,
    pBufferMemoryBarriers: [*]const VkBufferMemoryBarrier,
    imageMemoryBarrierCount: u32,
    pImageMemoryBarriers: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkQueueSubmit = *const fn (
    queue: VkQueue,
    submitCount: u32,
    pSubmits: *const VkSubmitInfo,
    fence: VkFence,
) callconv(.c) VkResult;

pub const PFN_vkCreateFence = *const fn (
    device: VkDevice,
    pCreateInfo: *const VkFenceCreateInfo,
    pAllocator: ?*const anyopaque,
    pFence: *VkFence,
) callconv(.c) VkResult;

pub const PFN_vkDestroyFence = *const fn (
    device: VkDevice,
    fence: VkFence,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkWaitForFences = *const fn (
    device: VkDevice,
    fenceCount: u32,
    pFences: *const VkFence,
    waitAll: u32,
    timeout: u64,
) callconv(.c) VkResult;

pub const PFN_vkResetFences = *const fn (
    device: VkDevice,
    fenceCount: u32,
    pFences: *const VkFence,
) callconv(.c) VkResult;

// ---------------------------------------------------------------------------
// Loader tiers.
// ---------------------------------------------------------------------------

pub const LoadError = error{
    NoVulkanLibrary,
    NoGetInstanceProcAddr,
    MissingSymbol,
    VulkanFailed,
    OutOfMemory,
};

/// Library paths tried in order (see header note on `/lib` multilib).
/// macOS first tries the Vulkan SDK loader, then MoltenVK directly
/// (MoltenVK IS a full Vulkan implementation over Metal — same GIPA chain,
/// same shaders, no separate backend; G3 in TODO.md). MoltenVK reports UMA
/// heaps (device-local + host-visible + coherent), so the coherent-memory
/// pick below automatically takes the zero-copy shared path on Apple
/// Silicon — that is the unified-bandwidth story, no special-casing.
pub const lib_candidates: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "libvulkan.1.dylib",
        "libvulkan.dylib",
        "libMoltenVK.dylib",
        "/usr/local/lib/libvulkan.1.dylib",
        "/opt/homebrew/lib/libvulkan.1.dylib",
    },
    else => &.{
        "libvulkan.so.1",
        "/usr/lib64/libvulkan.so.1",
        "/usr/lib/x86_64-linux-gnu/libvulkan.so.1",
        "libvulkan.so",
    },
};

fn loadSym(
    gipa: PFN_vkGetInstanceProcAddr,
    inst: ?VkInstance,
    comptime T: type,
    name: [*:0]const u8,
) LoadError!T {
    const sym = gipa(inst, name) orelse return error.MissingSymbol;
    // NOTE: dlsym/GIPA return code addresses (always instruction-aligned);
    // the explicit alignCast is required on targets where fn pointers carry
    // alignment (aarch64), and is a checked no-op where they don't.
    return @as(T, @ptrCast(@alignCast(sym)));
}

/// Tier 1: owns the lib handle + the two global entry points. Can only
/// create headless instances — everything else needs an `Instance`.
pub const Loader = struct {
    lib: *anyopaque,
    /// Which candidate opened (for diagnostics).
    lib_path: []const u8,
    vkGetInstanceProcAddr: PFN_vkGetInstanceProcAddr,
    vkCreateInstance: PFN_vkCreateInstance,

    pub fn open() LoadError!Loader {
        var lib: ?*anyopaque = null;
        var used: []const u8 = "";
        for (lib_candidates) |cand| {
            var buf: [256]u8 = undefined;
            if (cand.len + 1 > buf.len) continue;
            @memcpy(buf[0..cand.len], cand);
            buf[cand.len] = 0;
            const z: [*:0]const u8 = @ptrCast(buf[0..cand.len]);
            if (dlopen(z, RTLD_LAZY)) |h| {
                lib = h;
                used = cand;
                break;
            }
        }
        const h = lib orelse return error.NoVulkanLibrary;
        errdefer _ = dlclose(h);

        var nbuf: [64]u8 = undefined;
        const gname = "vkGetInstanceProcAddr";
        @memcpy(nbuf[0..gname.len], gname);
        nbuf[gname.len] = 0;
        const gz: [*:0]const u8 = @ptrCast(nbuf[0..gname.len]);
        const gipa_sym = dlsym(h, gz) orelse return error.NoGetInstanceProcAddr;
        const gipa: PFN_vkGetInstanceProcAddr = @as(PFN_vkGetInstanceProcAddr, @ptrCast(@alignCast(gipa_sym)));

        const create: PFN_vkCreateInstance = try loadSym(gipa, null, PFN_vkCreateInstance, "vkCreateInstance");
        return .{
            .lib = h,
            .lib_path = used,
            .vkGetInstanceProcAddr = gipa,
            .vkCreateInstance = create,
        };
    }

    pub fn close(self: *Loader) void {
        _ = dlclose(self.lib);
        self.* = undefined;
    }

    /// Headless instance: no layers, no extensions, no surface. Compute
    /// needs nothing else at 1.0.
    pub fn createHeadlessInstance(
        self: *const Loader,
        app_name: [*:0]const u8,
    ) LoadError!Instance {
        const app = VkApplicationInfo{
            .pApplicationName = app_name,
            .apiVersion = VK_API_VERSION_1_0,
        };
        const ci = VkInstanceCreateInfo{ .pApplicationInfo = &app };
        var handle: VkInstance = undefined;
        const r = self.vkCreateInstance(&ci, null, &handle);
        if (r != VK_SUCCESS) return error.VulkanFailed;
        errdefer {
            if (loadSym(
                self.vkGetInstanceProcAddr,
                handle,
                PFN_vkDestroyInstance,
                "vkDestroyInstance",
            ) catch null) |destroyFn| destroyFn(handle, null);
        }
        const vkDestroyInstance = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkDestroyInstance,
            "vkDestroyInstance",
        );
        const vkEnumeratePhysicalDevices = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkEnumeratePhysicalDevices,
            "vkEnumeratePhysicalDevices",
        );
        const vkGetPhysicalDeviceProperties = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkGetPhysicalDeviceProperties,
            "vkGetPhysicalDeviceProperties",
        );
        const vkGetPhysicalDeviceQueueFamilyProperties = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkGetPhysicalDeviceQueueFamilyProperties,
            "vkGetPhysicalDeviceQueueFamilyProperties",
        );
        const vkCreateDevice = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkCreateDevice,
            "vkCreateDevice",
        );
        const vkGetDeviceProcAddr = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkGetDeviceProcAddr,
            "vkGetDeviceProcAddr",
        );
        const vkGetPhysicalDeviceMemoryProperties = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkGetPhysicalDeviceMemoryProperties,
            "vkGetPhysicalDeviceMemoryProperties",
        );
        const vkGetPhysicalDeviceFeatures = try loadSym(
            self.vkGetInstanceProcAddr,
            handle,
            PFN_vkGetPhysicalDeviceFeatures,
            "vkGetPhysicalDeviceFeatures",
        );
        return .{
            .handle = handle,
            .vkDestroyInstance = vkDestroyInstance,
            .vkEnumeratePhysicalDevices = vkEnumeratePhysicalDevices,
            .vkGetPhysicalDeviceProperties = vkGetPhysicalDeviceProperties,
            .vkGetPhysicalDeviceQueueFamilyProperties = vkGetPhysicalDeviceQueueFamilyProperties,
            .vkCreateDevice = vkCreateDevice,
            .vkGetDeviceProcAddr = vkGetDeviceProcAddr,
            .vkGetPhysicalDeviceMemoryProperties = vkGetPhysicalDeviceMemoryProperties,
            .vkGetPhysicalDeviceFeatures = vkGetPhysicalDeviceFeatures,
        };
    }
};

/// Tier 2: a live instance + its functions. Destroys itself.
pub const Instance = struct {
    handle: VkInstance,
    vkDestroyInstance: PFN_vkDestroyInstance,
    vkEnumeratePhysicalDevices: PFN_vkEnumeratePhysicalDevices,
    vkGetPhysicalDeviceProperties: PFN_vkGetPhysicalDeviceProperties,
    vkGetPhysicalDeviceQueueFamilyProperties: PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    vkCreateDevice: PFN_vkCreateDevice,
    vkGetDeviceProcAddr: PFN_vkGetDeviceProcAddr,
    vkGetPhysicalDeviceMemoryProperties: PFN_vkGetPhysicalDeviceMemoryProperties,
    vkGetPhysicalDeviceFeatures: PFN_vkGetPhysicalDeviceFeatures,

    pub fn destroy(self: *Instance) void {
        self.vkDestroyInstance(self.handle, null);
        self.* = undefined;
    }

    pub fn deviceCount(self: *const Instance) LoadError!u32 {
        var n: u32 = 0;
        const r = self.vkEnumeratePhysicalDevices(self.handle, &n, null);
        if (r != VK_SUCCESS) return error.VulkanFailed;
        return n;
    }

    pub fn enumDevices(
        self: *const Instance,
        out: []VkPhysicalDevice,
    ) LoadError!u32 {
        var n: u32 = @intCast(out.len);
        const r = self.vkEnumeratePhysicalDevices(self.handle, &n, out.ptr);
        if (r != VK_SUCCESS and r != VK_INCOMPLETE) return error.VulkanFailed;
        return n;
    }

    /// Device identity through the stable prefix (see `DeviceIdPrefix`).
    /// `scratch` must be at least `device_id_scratch_bytes`.
    pub fn getDeviceId(
        self: *const Instance,
        phys: VkPhysicalDevice,
        scratch: []align(4) u8,
    ) *const DeviceIdPrefix {
        std.debug.assert(scratch.len >= device_id_scratch_bytes);
        @memset(scratch[0..device_id_scratch_bytes], 0);
        self.vkGetPhysicalDeviceProperties(phys, scratch.ptr);
        return @as(*const DeviceIdPrefix, @ptrCast(@alignCast(scratch.ptr)));
    }

    pub fn familyCount(self: *const Instance, phys: VkPhysicalDevice) u32 {
        var n: u32 = 0;
        self.vkGetPhysicalDeviceQueueFamilyProperties(phys, &n, null);
        return n;
    }

    pub fn memoryProperties(
        self: *const Instance,
        phys: VkPhysicalDevice,
    ) VkPhysicalDeviceMemoryProperties {
        var props: VkPhysicalDeviceMemoryProperties = undefined;
        self.vkGetPhysicalDeviceMemoryProperties(phys, &props);
        return props;
    }

    /// Raw 1.0 feature bits in spec order. Index with VK_FEATURE_*.
    pub fn features(self: *const Instance, phys: VkPhysicalDevice) [VK_DEVICE_FEATURE_COUNT]u32 {
        var f: [VK_DEVICE_FEATURE_COUNT]u32 = undefined;
        self.vkGetPhysicalDeviceFeatures(phys, &f);
        return f;
    }

    /// Queue-family pick: dedicated compute (COMPUTE without GRAPHICS) when
    /// present, else any COMPUTE family. Returns null when no family can do
    /// compute (drivers without a compute queue — the G1 fallback trigger).
    pub fn pickComputeFamily(
        self: *const Instance,
        phys: VkPhysicalDevice,
        families: []VkQueueFamilyProperties,
    ) ?u32 {
        const n = self.familyCount(phys);
        if (n == 0 or n > families.len) return null;
        var m: u32 = n;
        self.vkGetPhysicalDeviceQueueFamilyProperties(phys, &m, families.ptr);
        var fallback: ?u32 = null;
        for (families[0..n], 0..) |f, i| {
            if (f.queueCount == 0) continue;
            if (f.queueFlags & VK_QUEUE_COMPUTE_BIT == 0) continue;
            if (f.queueFlags & VK_QUEUE_GRAPHICS_BIT == 0) return @intCast(i);
            if (fallback == null) fallback = @intCast(i);
        }
        return fallback;
    }

    /// One-queue logical device on `family`. No extensions, no features:
    /// compute at 1.0 needs none. Device-level functions resolve through
    /// `vkGetDeviceProcAddr` per spec (GIPA is not guaranteed for them).
    pub fn createComputeDevice(
        self: *const Instance,
        phys: VkPhysicalDevice,
        family: u32,
        priority: f32,
    ) LoadError!Device {
        const none = [_]u32{0} ** VK_DEVICE_FEATURE_COUNT;
        return self.createComputeDeviceWithFeatures(phys, family, priority, &none);
    }

    /// Same, with 1.0 features enabled (e.g. shaderFloat64 for the
    /// density-threshold kernel). Unsupported bits fail device creation,
    /// which the caller reports as GPU-unavailable (soft fail).
    pub fn createComputeDeviceWithFeatures(
        self: *const Instance,
        phys: VkPhysicalDevice,
        family: u32,
        priority: f32,
        feat: *const [VK_DEVICE_FEATURE_COUNT]u32,
    ) LoadError!Device {
        const prio = [_]f32{priority};
        const q = VkDeviceQueueCreateInfo{
            .queueFamilyIndex = family,
            .queueCount = 1,
            .pQueuePriorities = &prio,
        };
        const qs = [_]VkDeviceQueueCreateInfo{q};
        const ci = VkDeviceCreateInfo{
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &qs,
            .pEnabledFeatures = feat,
        };
        var handle: VkDevice = undefined;
        const r = self.vkCreateDevice(phys, &ci, null, &handle);
        if (r != VK_SUCCESS) return error.VulkanFailed;
        errdefer {
            if (loadDeviceSym(
                self.vkGetDeviceProcAddr,
                handle,
                PFN_vkDestroyDevice,
                "vkDestroyDevice",
            ) catch null) |destroyFn| destroyFn(handle, null);
        }
        const vkDestroyDevice = try loadDeviceSym(
            self.vkGetDeviceProcAddr,
            handle,
            PFN_vkDestroyDevice,
            "vkDestroyDevice",
        );
        const vkGetDeviceQueue = try loadDeviceSym(
            self.vkGetDeviceProcAddr,
            handle,
            PFN_vkGetDeviceQueue,
            "vkGetDeviceQueue",
        );
        // Dispatch tier: every fn resolved here, none assumed present.
        const vkCreateBuffer = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateBuffer, "vkCreateBuffer");
        const vkDestroyBuffer = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyBuffer, "vkDestroyBuffer");
        const vkGetBufferMemoryRequirements = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
        const vkAllocateMemory = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkAllocateMemory, "vkAllocateMemory");
        const vkFreeMemory = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkFreeMemory, "vkFreeMemory");
        const vkBindBufferMemory = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkBindBufferMemory, "vkBindBufferMemory");
        const vkMapMemory = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkMapMemory, "vkMapMemory");
        const vkUnmapMemory = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkUnmapMemory, "vkUnmapMemory");
        const vkCreateDescriptorSetLayout = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateDescriptorSetLayout, "vkCreateDescriptorSetLayout");
        const vkDestroyDescriptorSetLayout = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout");
        const vkCreateDescriptorPool = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateDescriptorPool, "vkCreateDescriptorPool");
        const vkDestroyDescriptorPool = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyDescriptorPool, "vkDestroyDescriptorPool");
        const vkAllocateDescriptorSets = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkAllocateDescriptorSets, "vkAllocateDescriptorSets");
        const vkUpdateDescriptorSets = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkUpdateDescriptorSets, "vkUpdateDescriptorSets");
        const vkCreatePipelineLayout = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreatePipelineLayout, "vkCreatePipelineLayout");
        const vkDestroyPipelineLayout = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyPipelineLayout, "vkDestroyPipelineLayout");
        const vkCreateShaderModule = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateShaderModule, "vkCreateShaderModule");
        const vkDestroyShaderModule = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyShaderModule, "vkDestroyShaderModule");
        const vkCreateComputePipelines = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateComputePipelines, "vkCreateComputePipelines");
        const vkDestroyPipeline = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyPipeline, "vkDestroyPipeline");
        const vkCreateCommandPool = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateCommandPool, "vkCreateCommandPool");
        const vkDestroyCommandPool = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyCommandPool, "vkDestroyCommandPool");
        const vkAllocateCommandBuffers = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
        const vkBeginCommandBuffer = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkBeginCommandBuffer, "vkBeginCommandBuffer");
        const vkEndCommandBuffer = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkEndCommandBuffer, "vkEndCommandBuffer");
        const vkCmdBindPipeline = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
        const vkCmdBindDescriptorSets = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCmdBindDescriptorSets, "vkCmdBindDescriptorSets");
        const vkCmdDispatch = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCmdDispatch, "vkCmdDispatch");
        const vkCmdPipelineBarrier = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCmdPipelineBarrier, "vkCmdPipelineBarrier");
        const vkQueueSubmit = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkQueueSubmit, "vkQueueSubmit");
        const vkCreateFence = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkCreateFence, "vkCreateFence");
        const vkDestroyFence = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkDestroyFence, "vkDestroyFence");
        const vkWaitForFences = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkWaitForFences, "vkWaitForFences");
        const vkResetFences = try loadDeviceSym(self.vkGetDeviceProcAddr, handle, PFN_vkResetFences, "vkResetFences");
        return .{
            .handle = handle,
            .vkDestroyDevice = vkDestroyDevice,
            .vkGetDeviceQueue = vkGetDeviceQueue,
            .vkCreateBuffer = vkCreateBuffer,
            .vkDestroyBuffer = vkDestroyBuffer,
            .vkGetBufferMemoryRequirements = vkGetBufferMemoryRequirements,
            .vkAllocateMemory = vkAllocateMemory,
            .vkFreeMemory = vkFreeMemory,
            .vkBindBufferMemory = vkBindBufferMemory,
            .vkMapMemory = vkMapMemory,
            .vkUnmapMemory = vkUnmapMemory,
            .vkCreateDescriptorSetLayout = vkCreateDescriptorSetLayout,
            .vkDestroyDescriptorSetLayout = vkDestroyDescriptorSetLayout,
            .vkCreateDescriptorPool = vkCreateDescriptorPool,
            .vkDestroyDescriptorPool = vkDestroyDescriptorPool,
            .vkAllocateDescriptorSets = vkAllocateDescriptorSets,
            .vkUpdateDescriptorSets = vkUpdateDescriptorSets,
            .vkCreatePipelineLayout = vkCreatePipelineLayout,
            .vkDestroyPipelineLayout = vkDestroyPipelineLayout,
            .vkCreateShaderModule = vkCreateShaderModule,
            .vkDestroyShaderModule = vkDestroyShaderModule,
            .vkCreateComputePipelines = vkCreateComputePipelines,
            .vkDestroyPipeline = vkDestroyPipeline,
            .vkCreateCommandPool = vkCreateCommandPool,
            .vkDestroyCommandPool = vkDestroyCommandPool,
            .vkAllocateCommandBuffers = vkAllocateCommandBuffers,
            .vkBeginCommandBuffer = vkBeginCommandBuffer,
            .vkEndCommandBuffer = vkEndCommandBuffer,
            .vkCmdBindPipeline = vkCmdBindPipeline,
            .vkCmdBindDescriptorSets = vkCmdBindDescriptorSets,
            .vkCmdDispatch = vkCmdDispatch,
            .vkCmdPipelineBarrier = vkCmdPipelineBarrier,
            .vkQueueSubmit = vkQueueSubmit,
            .vkCreateFence = vkCreateFence,
            .vkDestroyFence = vkDestroyFence,
            .vkWaitForFences = vkWaitForFences,
            .vkResetFences = vkResetFences,
        };
    }
};

fn loadDeviceSym(
    gdpa: PFN_vkGetDeviceProcAddr,
    dev: VkDevice,
    comptime T: type,
    name: [*:0]const u8,
) LoadError!T {
    const sym = gdpa(dev, name) orelse return error.MissingSymbol;
    return @as(T, @ptrCast(@alignCast(sym)));
}

/// Tier 3: a live logical device + its functions. Destroys itself.
pub const Device = struct {
    handle: VkDevice,
    vkDestroyDevice: PFN_vkDestroyDevice,
    vkGetDeviceQueue: PFN_vkGetDeviceQueue,
    vkCreateBuffer: PFN_vkCreateBuffer,
    vkDestroyBuffer: PFN_vkDestroyBuffer,
    vkGetBufferMemoryRequirements: PFN_vkGetBufferMemoryRequirements,
    vkAllocateMemory: PFN_vkAllocateMemory,
    vkFreeMemory: PFN_vkFreeMemory,
    vkBindBufferMemory: PFN_vkBindBufferMemory,
    vkMapMemory: PFN_vkMapMemory,
    vkUnmapMemory: PFN_vkUnmapMemory,
    vkCreateDescriptorSetLayout: PFN_vkCreateDescriptorSetLayout,
    vkDestroyDescriptorSetLayout: PFN_vkDestroyDescriptorSetLayout,
    vkCreateDescriptorPool: PFN_vkCreateDescriptorPool,
    vkDestroyDescriptorPool: PFN_vkDestroyDescriptorPool,
    vkAllocateDescriptorSets: PFN_vkAllocateDescriptorSets,
    vkUpdateDescriptorSets: PFN_vkUpdateDescriptorSets,
    vkCreatePipelineLayout: PFN_vkCreatePipelineLayout,
    vkDestroyPipelineLayout: PFN_vkDestroyPipelineLayout,
    vkCreateShaderModule: PFN_vkCreateShaderModule,
    vkDestroyShaderModule: PFN_vkDestroyShaderModule,
    vkCreateComputePipelines: PFN_vkCreateComputePipelines,
    vkDestroyPipeline: PFN_vkDestroyPipeline,
    vkCreateCommandPool: PFN_vkCreateCommandPool,
    vkDestroyCommandPool: PFN_vkDestroyCommandPool,
    vkAllocateCommandBuffers: PFN_vkAllocateCommandBuffers,
    vkBeginCommandBuffer: PFN_vkBeginCommandBuffer,
    vkEndCommandBuffer: PFN_vkEndCommandBuffer,
    vkCmdBindPipeline: PFN_vkCmdBindPipeline,
    vkCmdBindDescriptorSets: PFN_vkCmdBindDescriptorSets,
    vkCmdDispatch: PFN_vkCmdDispatch,
    vkCmdPipelineBarrier: PFN_vkCmdPipelineBarrier,
    vkQueueSubmit: PFN_vkQueueSubmit,
    vkCreateFence: PFN_vkCreateFence,
    vkDestroyFence: PFN_vkDestroyFence,
    vkWaitForFences: PFN_vkWaitForFences,
    vkResetFences: PFN_vkResetFences,

    pub fn destroy(self: *Device) void {
        self.vkDestroyDevice(self.handle, null);
        self.* = undefined;
    }

    pub fn queue(self: *const Device, family: u32, index: u32) VkQueue {
        var q: VkQueue = undefined;
        self.vkGetDeviceQueue(self.handle, family, index, &q);
        return q;
    }
};

// ---------------------------------------------------------------------------
// Tests (driver-independent parts only; driver tests live in the probe tool
// so `zig build test` never requires a GPU).
// ---------------------------------------------------------------------------

test "result names cover the used codes" {
    try std.testing.expectEqualStrings("SUCCESS", resultName(VK_SUCCESS));
    try std.testing.expectEqualStrings("INCOMPLETE", resultName(VK_INCOMPLETE));
    try std.testing.expectEqualStrings("INITIALIZATION_FAILED", resultName(VK_ERROR_INITIALIZATION_FAILED));
    try std.testing.expectEqualStrings("UNKNOWN", resultName(42));
}

test "device type names" {
    try std.testing.expectEqualStrings("DISCRETE_GPU", VkPhysicalDeviceType.discrete_gpu.name());
    try std.testing.expectEqualStrings("CPU", VkPhysicalDeviceType.cpu.name());
}

test "struct layouts match the C ABI" {
    // Guards the hand-written layouts: the driver writes by C offsets, so a
    // drifted field reads garbage (deviceName) or crashes (pointers). u32
    // before a pointer costs a 4-byte pad — assert it, don't assume it.
    try std.testing.expectEqual(0, @offsetOf(VkInstanceCreateInfo, "sType"));
    try std.testing.expectEqual(8, @offsetOf(VkInstanceCreateInfo, "pNext"));
    try std.testing.expectEqual(24, @offsetOf(VkInstanceCreateInfo, "pApplicationInfo"));
    try std.testing.expectEqual(20, @offsetOf(VkDeviceQueueCreateInfo, "queueFamilyIndex"));
    try std.testing.expectEqual(32, @offsetOf(VkDeviceQueueCreateInfo, "pQueuePriorities"));
    try std.testing.expectEqual(20, @offsetOf(VkDeviceCreateInfo, "queueCreateInfoCount"));
    try std.testing.expectEqual(24, @offsetOf(VkDeviceCreateInfo, "pQueueCreateInfos"));
    try std.testing.expectEqual(16, @offsetOf(DeviceIdPrefix, "deviceType"));
    try std.testing.expectEqual(20, @offsetOf(DeviceIdPrefix, "deviceName"));
    try std.testing.expectEqual(@sizeOf(VkQueueFamilyProperties), 24);
}

test "loader opens when a driver is present, skips otherwise" {
    var loader = Loader.open() catch |err| switch (err) {
        error.NoVulkanLibrary => return error.SkipZigTest,
        else => return err,
    };
    defer loader.close();
    try std.testing.expect(loader.lib_path.len > 0);
}

test "dispatch-tier layouts match the C ABI" {
    try std.testing.expectEqual(@sizeOf(VkMemoryType), 8);
    try std.testing.expectEqual(@sizeOf(VkMemoryHeap), 16);
    try std.testing.expectEqual(@offsetOf(VkPhysicalDeviceMemoryProperties, "memoryTypes"), 4);
    try std.testing.expectEqual(@offsetOf(VkPhysicalDeviceMemoryProperties, "memoryHeapCount"), 260);
    try std.testing.expectEqual(@offsetOf(VkPhysicalDeviceMemoryProperties, "memoryHeaps"), 264);
    try std.testing.expectEqual(@sizeOf(VkPhysicalDeviceMemoryProperties), 520);
    try std.testing.expectEqual(@offsetOf(VkBufferCreateInfo, "size"), 24);
    try std.testing.expectEqual(@offsetOf(VkBufferCreateInfo, "usage"), 32);
    try std.testing.expectEqual(@sizeOf(VkMemoryRequirements), 24);
    try std.testing.expectEqual(@offsetOf(VkMemoryAllocateInfo, "allocationSize"), 16);
    try std.testing.expectEqual(@offsetOf(VkMemoryAllocateInfo, "memoryTypeIndex"), 24);
    try std.testing.expectEqual(@sizeOf(VkDescriptorPoolSize), 8);
    try std.testing.expectEqual(@offsetOf(VkWriteDescriptorSet, "dstBinding"), 24);
    try std.testing.expectEqual(@offsetOf(VkWriteDescriptorSet, "descriptorCount"), 32);
    try std.testing.expectEqual(@offsetOf(VkWriteDescriptorSet, "descriptorType"), 36);
    try std.testing.expectEqual(@offsetOf(VkWriteDescriptorSet, "pBufferInfo"), 48);
    try std.testing.expectEqual(@sizeOf(VkWriteDescriptorSet), 64);
    try std.testing.expectEqual(@offsetOf(VkComputePipelineCreateInfo, "stage"), 24);
    try std.testing.expectEqual(@offsetOf(VkComputePipelineCreateInfo, "layout"), 72);
    try std.testing.expectEqual(@sizeOf(VkComputePipelineCreateInfo), 96);
    try std.testing.expectEqual(@offsetOf(VkSubmitInfo, "commandBufferCount"), 40);
    try std.testing.expectEqual(@offsetOf(VkSubmitInfo, "pCommandBuffers"), 48);
    try std.testing.expectEqual(@offsetOf(VkBufferMemoryBarrier, "buffer"), 32);
    try std.testing.expectEqual(@sizeOf(VkBufferMemoryBarrier), 56);
    try std.testing.expectEqual(@sizeOf(VkDescriptorBufferInfo), 24);
}

test "host-coherent memory pick prefers flags over index" {
    var props = std.mem.zeroes(VkPhysicalDeviceMemoryProperties);
    props.memoryTypeCount = 3;
    // 0: device-local only. 1: host-visible but NOT coherent. 2: both.
    props.memoryTypes[0] = .{ .propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 };
    props.memoryTypes[1] = .{ .propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, .heapIndex = 1 };
    props.memoryTypes[2] = .{
        .propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .heapIndex = 1,
    };
    try std.testing.expectEqual(@as(?u32, 2), findHostCoherentMemoryType(&props, 0b111));
    // Type-bit mask excludes the good one -> null (decline, don't stage).
    try std.testing.expectEqual(@as(?u32, null), findHostCoherentMemoryType(&props, 0b011));
    // Mask with only the incoherent bit set -> null, never settles for it.
    try std.testing.expectEqual(@as(?u32, null), findHostCoherentMemoryType(&props, 0b010));
}

test "host-cached memory pick prefers cached heap, falls back cleanly" {
    var props = std.mem.zeroes(VkPhysicalDeviceMemoryProperties);
    props.memoryTypeCount = 4;
    // 0: device-local only. 1: coherent but NOT cached (WC/GTT first).
    // 2: coherent + cached. 3: cached but NOT coherent (never picked).
    props.memoryTypes[0] = .{ .propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 };
    props.memoryTypes[1] = .{
        .propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .heapIndex = 1,
    };
    props.memoryTypes[2] = .{
        .propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        .heapIndex = 1,
    };
    props.memoryTypes[3] = .{
        .propertyFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        .heapIndex = 0,
    };
    // Cached-capable wins over the earlier coherent-only type.
    try std.testing.expectEqual(@as(?u32, 2), findHostCachedMemoryType(&props, 0b1111));
    // Mask excluding it -> null (caller falls back to the coherent picker).
    try std.testing.expectEqual(@as(?u32, null), findHostCachedMemoryType(&props, 0b1011));
    // Mask with only the incoherent cached type -> null.
    try std.testing.expectEqual(@as(?u32, null), findHostCachedMemoryType(&props, 0b1000));
}

test "device features: 1.0 count covers shaderFloat64" {
    try std.testing.expectEqual(@as(usize, 55), VK_DEVICE_FEATURE_COUNT);
    try std.testing.expectEqual(@as(usize, 39), VK_FEATURE_SHADER_FLOAT64);
    try std.testing.expect(VK_FEATURE_SHADER_FLOAT64 < VK_DEVICE_FEATURE_COUNT);
}
