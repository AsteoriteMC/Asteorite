//! Fixed-size slab allocator — Phase D "slab allocator for entities /
//! block entities (fixed-size, contiguous)".
//!
//! A slab is a list of contiguous pages; every page holds `page_size` slots
//! of `T`. Slots never move: a page is allocated once and stays put, so a
//! `*T` handed out by `create()` stays valid for the slab's lifetime even
//! when the slab grows. That property is what makes it usable for entity
//! lists (the ticker hands `*Mob` pointers around while drops spawn and
//! despawn).
//!
//! Free slots are threaded on an intrusive free list stored in the slot
//! itself (pointer to the next free slot), so allocation is a pop and
//! deallocation is a push: O(1), no side table, no allocation per object.
//! The steady-state allocation rate is zero — entity churn (drops, mobs,
//! projectiles) stops hitting the general-purpose allocator.
//!
//! Not thread-safe: a slab belongs to the thread that owns the entity
//! list (the ticker thread, inside `ent_lock`).

const std = @import("std");

pub fn Slab(comptime T: type) type {
    return struct {
        const Self = @This();

        /// One slot of storage. `next` is used only while the slot is on the
        /// free list.
        const Slot = struct {
            next: ?*Slot,
            data: T,
        };

        allocator: std.mem.Allocator,
        /// Pages of slots. Each page is a separate allocation; pages are
        /// never reallocated, so slot addresses are stable.
        pages: std.ArrayList([]Slot) = .empty,
        /// Head of the intrusive free list.
        free_head: ?*Slot = null,
        /// Slots currently handed out.
        live: usize = 0,
        /// Slots per page (growth step).
        page_size: usize,
        /// Total slots across all pages.
        capacity: usize = 0,

        pub fn init(allocator: std.mem.Allocator, page_size: usize) Self {
            return .{ .allocator = allocator, .page_size = @max(page_size, 1) };
        }

        pub fn deinit(self: *Self) void {
            for (self.pages.items) |page| self.allocator.free(page);
            self.pages.deinit(self.allocator);
            self.free_head = null;
            self.live = 0;
            self.capacity = 0;
        }

        /// Allocate one slot. Returns null when the slab cannot grow (OOM).
        pub fn create(self: *Self) ?*T {
            if (self.free_head == null) {
                self.grow() catch return null;
            }
            const slot = self.free_head.?;
            self.free_head = slot.next;
            slot.next = null;
            self.live += 1;
            return &slot.data;
        }

        /// Free a slot. The slot's contents are NOT zeroed (the caller owns
        /// any heap pointers inside `T` and must release them first).
        pub fn destroy(self: *Self, obj: *T) void {
            const slot: *Slot = @fieldParentPtr("data", obj);
            slot.next = self.free_head;
            self.free_head = slot;
            self.live -= 1;
        }

        /// Total slots in the slab.
        pub fn slots(self: *const Self) usize {
            return self.capacity;
        }

        /// Slots currently in use.
        pub fn inUse(self: *const Self) usize {
            return self.live;
        }

        /// Bytes of storage held by the slab (diagnostics / memory budget).
        pub fn bytes(self: *const Self) usize {
            var total: usize = 0;
            for (self.pages.items) |page| total += page.len * @sizeOf(Slot);
            return total;
        }

        fn grow(self: *Self) !void {
            const want = @max(self.page_size, 8);
            const page = try self.allocator.alloc(Slot, want);
            errdefer self.allocator.free(page);
            try self.pages.append(self.allocator, page);
            // Thread the fresh slots onto the free list.
            var i = want;
            while (i > 0) {
                i -= 1;
                page[i].next = self.free_head;
                self.free_head = &page[i];
            }
            self.capacity += want;
        }
    };
}

const TestObj = struct { a: u64 = 0, b: u32 = 0 };

test "slab alloc/free/reuse" {
    const a = std.testing.allocator;
    var s = Slab(TestObj).init(a, 4);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.inUse());
    const p = s.create().?;
    try std.testing.expectEqual(@as(usize, 1), s.inUse());
    p.a = 42;
    s.destroy(p);
    try std.testing.expectEqual(@as(usize, 0), s.inUse());
    // The freed slot is reused (LIFO free list).
    const q = s.create().?;
    try std.testing.expectEqual(@as(usize, 1), s.inUse());
    try std.testing.expectEqual(p, q);
}

test "slab grows and keeps live objects stable" {
    const a = std.testing.allocator;
    var s = Slab(TestObj).init(a, 2);
    defer s.deinit();

    var objs: [5]*TestObj = undefined;
    for (&objs) |*o| {
        o.* = s.create().?;
        o.*.a = @intFromPtr(o.*);
    }
    try std.testing.expectEqual(@as(usize, 5), s.inUse());
    // Growth added pages: the live pointers must still be valid and hold
    // their data (slot addresses are stable by design).
    for (objs) |o| {
        try std.testing.expectEqual(@intFromPtr(o), o.a);
    }
    // Free them all: the slab must end empty and fully reusable.
    for (objs) |o| s.destroy(o);
    try std.testing.expectEqual(@as(usize, 0), s.inUse());
    const again = s.create().?;
    try std.testing.expectEqual(@as(usize, 1), s.inUse());
    _ = again;
}

test "slab create returns null when the allocator fails" {
    // A failing allocator must not corrupt the slab.
    const F = struct {
        fn alloc(_: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            _ = n;
            return null;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
    };
    var s = Slab(TestObj).init(.{ .ptr = undefined, .vtable = &.{ .alloc = F.alloc, .resize = F.resize, .free = F.free, .remap = F.remap } }, 2);
    defer s.deinit();
    try std.testing.expect(s.create() == null);
    try std.testing.expectEqual(@as(usize, 0), s.inUse());
}
