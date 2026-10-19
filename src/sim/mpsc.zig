//! Lock-free multi-producer single-consumer queue for cross-region handoff.
//!
//! Region threads push `Transfer` messages without blocking; the owning
//! region thread drains its inbox once per tick. Treiber stack + reversal
//! gives FIFO order per drain. Single consumer only.

const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            next: ?*Node,
            value: T,
        };

        allocator: std.mem.Allocator,
        head: std.atomic.Value(?*Node) = std.atomic.Value(?*Node).init(null),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            // free any undrained nodes (values are plain data; no payload free)
            var n = self.head.load(.acquire);
            while (n) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                n = next;
            }
            self.* = undefined;
        }

        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{ .next = null, .value = value };
            var h = self.head.load(.acquire);
            while (true) {
                node.next = h;
                if (self.head.cmpxchgWeak(h, node, .release, .acquire)) |actual| {
                    h = actual;
                    continue;
                }
                break;
            }
        }

        /// Drain all messages in FIFO order. Caller owns the slice.
        pub fn drain(self: *Self) ![]T {
            var rev: ?*Node = self.head.swap(null, .acq_rel);
            // reverse to FIFO
            var fwd: ?*Node = null;
            var count: usize = 0;
            while (rev) |node| {
                const next = node.next;
                node.next = fwd;
                fwd = node;
                rev = next;
                count += 1;
            }
            const out = try self.allocator.alloc(T, count);
            var i: usize = 0;
            while (fwd) |node| {
                out[i] = node.value;
                i += 1;
                const next = node.next;
                self.allocator.destroy(node);
                fwd = next;
            }
            return out;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head.load(.acquire) == null;
        }
    };
}

test "push/drain FIFO single-threaded" {
    const a = std.testing.allocator;
    var q = Queue(u32).init(a);
    defer q.deinit();
    try std.testing.expect(q.isEmpty());
    try q.push(1);
    try q.push(2);
    try q.push(3);
    const out = try q.drain();
    defer a.free(out);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3 }, out);
    try std.testing.expect(q.isEmpty());
    const empty = try q.drain();
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "concurrent producers, single drain" {
    const a = std.testing.allocator;
    var q = Queue(u32).init(a);
    defer q.deinit();
    const Producer = struct {
        fn run(queue: *@TypeOf(q), base: u32) !void {
            var i: u32 = 0;
            while (i < 250) : (i += 1) try queue.push(base + i);
        }
    };
    const t0 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 0 });
    const t1 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 1000 });
    const t2 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 2000 });
    const t3 = try std.Thread.spawn(.{}, Producer.run, .{ &q, 3000 });
    t0.join();
    t1.join();
    t2.join();
    t3.join();
    const out = try q.drain();
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 1000), out.len);
    // all values present exactly once
    var seen = std.AutoHashMap(u32, void).init(a);
    defer seen.deinit();
    for (out) |v| try seen.put(v, {});
    try std.testing.expectEqual(@as(usize, 1000), seen.count());
}
