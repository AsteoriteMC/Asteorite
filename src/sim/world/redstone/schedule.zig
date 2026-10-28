//! Redstone event plumbing: change/sound/action lists, scheduler, burnout, plates.

const std = @import("std");
const ids = @import("../../../ids.zig");
const rules_mod = @import("../../../game/rules.zig");

pub const Change = struct {
    x: i32,
    y: i32,
    z: i32,
    id: ids.Id,
    meta: u4,
    old_id: ids.Id,
    old_meta: u4,
    popped: bool = false,
    /// Piston block-event writes carry the animation in the S24 packet;
    /// an S23 echo would cancel the client's moving-block render.
    silent: bool = false,
};

pub const max_changes: usize = 1024;

/// Bounded change buffer (storm protection: drops beyond cap, flags it).
pub const ChangeList = struct {
    items: [max_changes]Change = undefined,
    n: usize = 0,
    dropped: bool = false,

    pub fn append(self: *ChangeList, c: Change) void {
        if (self.n >= max_changes) {
            self.dropped = true;
            return;
        }
        self.items[self.n] = c;
        self.n += 1;
    }
};

pub const SoundKind = enum { click_on, click_off, door_open, door_close, fizz, piston_out, piston_in };

pub const SoundEv = struct {
    kind: SoundKind,
    x: i32,
    y: i32,
    z: i32,
};

pub const SoundList = struct {
    evs: [64]SoundEv = undefined,
    n: usize = 0,

    pub fn append(self: *SoundList, s: SoundEv) void {
        if (self.n >= self.evs.len) return;
        self.evs[self.n] = s;
        self.n += 1;
    }

    /// S29 voice + pitch (+ volume: pistons play at 0.5, `app` doMove).
    pub const Voice = struct { name: []const u8, pitch: f32, volume: f32 };

    /// S29 voice + pitch (+ volume: pistons play at 0.5, `app` doMove).
    pub fn voice(kind: SoundKind) Voice {
        return switch (kind) {
            .click_on => .{ .name = "random.click", .pitch = 0.6, .volume = 1.0 },
            .click_off => .{ .name = "random.click", .pitch = 0.5, .volume = 1.0 },
            .door_open => .{ .name = "random.door_open", .pitch = 1.0, .volume = 1.0 },
            .door_close => .{ .name = "random.door_close", .pitch = 1.0, .volume = 1.0 },
            .fizz => .{ .name = "random.fizz", .pitch = 2.6, .volume = 1.0 },
            // app.a: playSoundEffectAt(..., 0.5, rand*0.25+0.6) / (..., 0.5, rand*0.15+0.6)
            .piston_out => .{ .name = "tile.piston.out", .pitch = 0.72, .volume = 0.5 },
            .piston_in => .{ .name = "tile.piston.in", .pitch = 0.68, .volume = 0.5 },
        };
    }
};

// Timing values live in `game.rules.RedstoneRules` (profile data).

/// Neighbor fan-out cap per edit (anti-lag-machine; clock loops hit this and
/// self-extinguish via torch burnout instead of recursing forever).
pub const max_updates_per_edit: usize = 4096;
/// Scheduled entries drained per server tick.
pub const max_scheduled_per_tick: usize = 500;

/// Block-action event for S24 (client animation): position, event id, facing,
/// and the vanilla block id of the piston block.
pub const BlockAction = struct {
    x: i32,
    y: i32,
    z: i32,
    event_id: u8,
    facing: u8,
    id: ids.Id,
};

pub const ActionList = struct {
    items: [64]BlockAction = undefined,
    n: usize = 0,

    pub fn append(self: *ActionList, a: BlockAction) void {
        if (self.n >= self.items.len) return;
        self.items[self.n] = a;
        self.n += 1;
    }
};

// ---------------------------------------------------------------------------
// scheduler (vanilla `scheduleBlockUpdate`: per-position dedupe, budgeted drain)
// ---------------------------------------------------------------------------

pub const SchedKind = enum { button_release, repeater_eval, ore_fade, piston_extend, piston_retract, wire_check };

pub const SchedEntry = struct {
    x: i32,
    y: i32,
    z: i32,
    due: i64,
    kind: SchedKind,
};

pub const sched_cap: usize = 1024;

pub const Scheduler = struct {
    entries: [sched_cap]SchedEntry = undefined,
    n: usize = 0,

    /// Schedule (or reschedule: same position replaces the old entry, like
    /// vanilla's per-position dedupe). Full queue evicts the oldest (FIFO).
    pub fn schedule(self: *Scheduler, x: i32, y: i32, z: i32, due: i64, kind: SchedKind) void {
        for (self.entries[0..self.n]) |*e| {
            if (e.x == x and e.y == y and e.z == z) {
                e.* = entry(x, y, z, due, kind);
                return;
            }
        }
        if (self.n < sched_cap) {
            self.entries[self.n] = entry(x, y, z, due, kind);
            self.n += 1;
            return;
        }
        std.mem.copyForwards(SchedEntry, self.entries[0 .. sched_cap - 1], self.entries[1..sched_cap]);
        self.entries[sched_cap - 1] = entry(x, y, z, due, kind);
    }

    fn entry(x: i32, y: i32, z: i32, due: i64, kind: SchedKind) SchedEntry {
        return .{ .x = x, .y = y, .z = z, .due = due, .kind = kind };
    }

    pub fn pendingAt(self: *const Scheduler, x: i32, y: i32, z: i32) bool {
        for (self.entries[0..self.n]) |e| {
            if (e.x == x and e.y == y and e.z == z) return true;
        }
        return false;
    }

    /// Move due entries (due <= now) into `out`, removing them. Returns the
    /// count fired.
    pub fn popDue(self: *Scheduler, now: i64, out: []SchedEntry) usize {
        var fired: usize = 0;
        var i: usize = 0;
        while (i < self.n) {
            if (self.entries[i].due <= now and fired < out.len) {
                out[fired] = self.entries[i];
                fired += 1;
                self.entries[i] = self.entries[self.n - 1];
                self.n -= 1;
            } else {
                i += 1;
            }
        }
        return fired;
    }
};

// ---------------------------------------------------------------------------
// torch burnout (vanilla `anc.a`: per-world list of RedstoneUpdate(x,y,z,t);
// pruned older than 60 ticks on every torch tick; 8 entries = burnt out)
// ---------------------------------------------------------------------------

pub const burn_cap: usize = 256;
/// Maximum per-position flip history an engine instance retains. The
/// profile rule (`torch_burnout_toggles`) selects the active threshold.
pub const burn_hist_cap: usize = 16;

const BurnSlot = struct {
    used: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    hist: [burn_hist_cap]i64 = [_]i64{0} ** burn_hist_cap,
    h_n: usize = 0,
};

pub const BurnoutMap = struct {
    slots: [burn_cap]BurnSlot = [_]BurnSlot{.{}} ** burn_cap,
    cursor: usize = 0,

    /// Occupied slot for (x,y,z), if any (no allocation).
    fn findSlot(self: *BurnoutMap, x: i32, y: i32, z: i32) ?*BurnSlot {
        for (&self.slots) |*s| {
            if (s.used and s.x == x and s.y == y and s.z == z) return s;
        }
        return null;
    }

    fn slotFor(self: *BurnoutMap, x: i32, y: i32, z: i32) *BurnSlot {
        if (self.findSlot(x, y, z)) |s| return s;
        for (&self.slots) |*s| {
            if (!s.used) {
                s.* = .{ .used = true, .x = x, .y = y, .z = z };
                return s;
            }
        }
        const s = &self.slots[self.cursor % burn_cap];
        self.cursor += 1;
        s.* = .{ .used = true, .x = x, .y = y, .z = z };
        return s;
    }

    /// Count of recorded flips still within the 60-tick window (vanilla
    /// prunes older entries on every torch tick).
    fn freshCountSlot(s: *const BurnSlot, now: i64, rules: *const rules_mod.RedstoneRules) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.h_n) : (i += 1) {
            if (now - s.hist[i] <= rules.torch_burnout_window) n += 1;
        }
        return n;
    }

    pub fn isBurnt(self: *BurnoutMap, x: i32, y: i32, z: i32, now: i64, rules: *const rules_mod.RedstoneRules) bool {
        if (!rules.torch_burnout) return false;
        const s = self.findSlot(x, y, z) orelse return false;
        return freshCountSlot(s, now, rules) >= rules.torch_burnout_toggles;
    }

    /// Record one ON→OFF flip (vanilla only records power-offs). Returns
    /// true when this flip trips burnout (8 within 60 ticks by default).
    pub fn noteFlip(self: *BurnoutMap, x: i32, y: i32, z: i32, now: i64, rules: *const rules_mod.RedstoneRules) bool {
        if (!rules.torch_burnout or rules.torch_burnout_toggles == 0) return false;
        const cap = @min(rules.torch_burnout_toggles, burn_hist_cap);
        const s = self.slotFor(x, y, z);
        // ring insert: shift when full (keeps the most recent entries, like
        // the vanilla list before its window prune)
        if (s.h_n < cap) {
            s.hist[s.h_n] = now;
            s.h_n += 1;
        } else {
            std.mem.copyForwards(i64, s.hist[0 .. cap - 1], s.hist[1..cap]);
            s.hist[cap - 1] = now;
        }
        return freshCountSlot(s, now, rules) >= rules.torch_burnout_toggles;
    }
};

// ---------------------------------------------------------------------------
// pressure-plate registry (positions only; polled each server tick)
// ---------------------------------------------------------------------------

pub const plate_cap: usize = 256;

pub const PlatePos = struct { x: i32, y: i32, z: i32 };

pub const PlateSet = struct {
    items: [plate_cap]PlatePos = undefined,
    /// Rising-edge tick (same 20tps `now` the scheduler uses) per slot.
    /// Vanilla plates re-check on a 20-tick schedule, so a tap stays
    /// pressed for a full second; the 1Hz poll would otherwise release
    /// phase-dependently. Parallel to `items` (swap/shift together).
    pressed: [plate_cap]i64 = [_]i64{0} ** plate_cap,
    n: usize = 0,

    pub fn add(self: *PlateSet, x: i32, y: i32, z: i32) void {
        for (self.items[0..self.n]) |p| {
            if (p.x == x and p.y == y and p.z == z) return;
        }
        if (self.n < plate_cap) {
            self.items[self.n] = .{ .x = x, .y = y, .z = z };
            self.pressed[self.n] = 0;
            self.n += 1;
            return;
        }
        std.mem.copyForwards(PlatePos, self.items[0 .. plate_cap - 1], self.items[1..plate_cap]);
        std.mem.copyForwards(i64, self.pressed[0 .. plate_cap - 1], self.pressed[1..plate_cap]);
        self.items[plate_cap - 1] = .{ .x = x, .y = y, .z = z };
        self.pressed[plate_cap - 1] = 0;
    }

    pub fn remove(self: *PlateSet, x: i32, y: i32, z: i32) void {
        var i: usize = 0;
        while (i < self.n) {
            const p = self.items[i];
            if (p.x == x and p.y == y and p.z == z) {
                self.items[i] = self.items[self.n - 1];
                self.pressed[i] = self.pressed[self.n - 1];
                self.n -= 1;
            } else {
                i += 1;
            }
        }
    }
};
