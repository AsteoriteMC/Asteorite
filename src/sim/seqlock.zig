//! Seqlock — Phase D "seqlocks for read-heavy shared state (config,
//! time-of-day, player count for status) so region threads never block on
//! a mutex".
//!
//! Classic seqlock: the writer bumps a sequence counter to odd, writes,
//! then bumps it to even. A reader samples the counter, reads the payload,
//! then samples it again; if the counter changed (or is odd) the read is
//! discarded and retried.
//!
//! This is only sound for payloads where a torn read is *detectable*, i.e.
//! the reader re-validates the counter after the read. Use it for small
//! scalar/config snapshots — never for multi-word invariants that must be
//! consistent with each other (use a lock for those).
//!
//! The counter is a relaxed/release atomic; the payload itself is written
//! with ordinary stores. On the supported architectures the stores cannot
//! be reordered past the release store of the counter, which is what makes
//! the reader's validation meaningful.

const std = @import("std");

/// A seqlock protecting one value of type `T`.
///
/// Readers never block: they sample the sequence counter, read the
/// value, and re-check the counter. Writers publish the whole value at
/// once (odd counter while writing).
pub fn Seqlock(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Even = stable, odd = write in progress.
        seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        /// The protected payload. Only valid when read under the protocol
        /// below (readers re-validate `seq`).
        value: T = undefined,

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        /// Publish a new value (writer side). Single writer assumed.
        pub fn store(self: *Self, value: T) void {
            // odd = write in progress
            _ = self.seq.fetchAdd(1, .acq_rel);
            self.value = value;
            // even = stable again
            _ = self.seq.fetchAdd(1, .release);
        }

        /// Read the value (reader side). Retries while a writer is active.
        pub fn load(self: *const Self) T {
            var spins: usize = 0;
            while (true) {
                const s1 = self.seq.load(.acquire);
                if (s1 & 1 != 0) {
                    // Writer in progress: spin (never block on a mutex).
                    spins += 1;
                    if (spins > 1024) std.atomic.spinLoopHint();
                    continue;
                }
                const v = self.value;
                const s2 = self.seq.load(.acquire);
                if (s1 == s2) return v;
                spins += 1;
                if (spins > 1024) std.atomic.spinLoopHint();
            }
        }
    };
}

const Pair = struct { a: u32, b: u32 };

test "seqlock load returns the published value" {
    var l = Seqlock(u64).init(7);
    try std.testing.expectEqual(@as(u64, 7), l.load());
    l.store(9);
    try std.testing.expectEqual(@as(u64, 9), l.load());
}

test "seqlock readers see a consistent value while writers publish" {
    var l = Seqlock(Pair).init(.{ .a = 1, .b = 2 });
    const Writer = struct {
        fn run(lock: *Seqlock(Pair)) void {
            var i: u32 = 0;
            while (i < 20000) : (i += 1) {
                lock.store(.{ .a = i, .b = i * 2 });
            }
        }
    };
    const Reader = struct {
        fn run(lock: *Seqlock(Pair), bad: *std.atomic.Value(u32)) void {
            var i: u32 = 0;
            while (i < 20000) : (i += 1) {
                const v = lock.load();
                if (v.b != v.a * 2) {
                    _ = bad.fetchAdd(1, .acq_rel);
                }
            }
        }
    };
    const th = try std.Thread.spawn(.{}, Writer.run, .{&l});
    var bad = std.atomic.Value(u32).init(0);
    const th2 = try std.Thread.spawn(.{}, Reader.run, .{ &l, &bad });
    th.join();
    th2.join();
    try std.testing.expectEqual(@as(u32, 0), bad.load(.acquire));
}
