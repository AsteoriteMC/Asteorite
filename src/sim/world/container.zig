//! Shared container click primitives (C3).
//!
//! Window layout and packet framing stay at the profile/network edge. This
//! module owns only the item-conservation rules: pickup/place/merge, quick
//! move, number-key swap, crafting-result consumption, and insertion into a
//! player range. All stacks here are owned canonical stacks; callers pass
//! their allocator for NBT deep-copies/frees.
//!
//! The module deliberately does not import `proto/**` or `net/**`.
//! Stack limits are profile game data (`profile.game.item_data`, like the
//! other shared engines) — not wire bytes. Window 0/1/2 alias maps remain
//! in `conn.zig`/`server.zig`.

const std = @import("std");
const item_mod = @import("../../item.zig");
const profile = @import("../../version.zig");

/// Decrement a stack by `n`, freeing it at zero. The single home for the
/// "shrink + free-if-empty" pattern used by every click path below.
fn shrink(alloc: std.mem.Allocator, cell: *?item_mod.Stack, n: i8) void {
    cell.*.?.count -= n;
    if (cell.*.?.count <= 0) item_mod.freeStack(alloc, cell);
}

/// Merge src into non-empty mergeable dst (caller checked canMerge).
/// Returns true when anything moved.
fn mergeCells(alloc: std.mem.Allocator, dst: *?item_mod.Stack, src: *?item_mod.Stack, limit: u8) bool {
    const room: i16 = @as(i16, limit) - dst.*.?.count;
    const n: i16 = @min(room, @as(i16, src.*.?.count));
    if (n <= 0) return false;
    dst.*.?.count += @as(i8, @intCast(n));
    shrink(alloc, src, @as(i8, @intCast(n)));
    return true;
}

/// True when range index `i` is the skipped source slot.
fn skipped(skip: ?usize, i: usize) bool {
    const s = skip orelse return false;
    return i == s;
}

/// Mode-0 click on one resolved cell (window 0 or table/furnace alias).
/// `button` 0 = left (whole/merge-all), 1 = right (one/merge-one).
/// Returns true when anything moved; callers sync the slot and cursor.
pub fn pickup(alloc: std.mem.Allocator, cell: *?item_mod.Stack, cursor: *?item_mod.Stack, button: i8) !bool {
    if (button != 0 and button != 1) return false;
    if (cell.* == null and cursor.* == null) return false;
    if (cell.* == null) {
        // Place from cursor.
        if (button == 0) {
            cell.* = cursor.*;
            cursor.* = null;
        } else {
            const c = cursor.*.?;
            cell.* = try item_mod.cloneStack(alloc, c);
            cell.*.?.count = 1;
            shrink(alloc, cursor, 1);
        }
        return true;
    }
    if (cursor.* == null) {
        // Pick up from slot.
        if (button == 0) {
            cursor.* = cell.*;
            cell.* = null;
        } else {
            const st = cell.*.?;
            const take: i8 = @divTrunc(st.count + 1, 2); // ceil half
            cursor.* = try item_mod.cloneStack(alloc, st);
            cursor.*.?.count = take;
            shrink(alloc, cell, take);
        }
        return true;
    }
    // Both sides occupied: merge, otherwise swap.
    const dst = cell.*.?;
    const src = cursor.*.?;
    const limit = profile.game.item_data.maxStackSize(dst.id);
    if (item_mod.canMerge(dst, src) and dst.count < limit) {
        const want: i16 = if (button == 0) src.count else 1;
        if (want <= 0) return false;
        const room: i16 = @as(i16, limit) - dst.count;
        const n: i16 = @min(room, @min(want, @as(i16, src.count)));
        if (n <= 0) return false;
        cell.*.?.count += @as(i8, @intCast(n));
        shrink(alloc, cursor, @as(i8, @intCast(n)));
        return true;
    }
    if (!item_mod.canMerge(dst, src)) {
        const t = cell.*;
        cell.* = cursor.*;
        cursor.* = t;
        return true;
    }
    return false;
}

/// Merge a borrowed source into `dst`, transferring ownership when `dst` is
/// empty. Returns true when anything moved. Used by furnace shift routing.
pub fn mergeInto(alloc: std.mem.Allocator, src: *?item_mod.Stack, dst: *?item_mod.Stack) bool {
    const s = src.* orelse return false;
    if (dst.* == null) {
        dst.* = s;
        src.* = null;
        return true;
    }
    const d = dst.*.?;
    if (!item_mod.canMerge(d, s)) return false;
    const limit = profile.game.item_data.maxStackSize(d.id);
    if (d.count >= limit) return false;
    return mergeCells(alloc, dst, src, limit);
}

/// Shift-click a source cell into a destination range: merge into compatible
/// stacks first, then move the remainder into the first empty. `skip` is the
/// source's index when `src` aliases `dst` (the slot must not receive itself).
/// `reverse` scans hi→lo (vanilla mergeItemStack reverse pass): into-player
/// moves fill from the hotbar end backwards (slot 44 first); into-container
/// moves scan forward.
pub fn quickMove(
    alloc: std.mem.Allocator,
    src: *?item_mod.Stack,
    dst: []?item_mod.Stack,
    lo: usize,
    hi: usize,
    skip: ?usize,
    reverse: bool,
) bool {
    if (src.* == null) return false;
    std.debug.assert(lo <= hi and hi < dst.len);
    var moved = false;
    const n = hi - lo + 1;
    // Merge pass (existing stacks, in scan order).
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const idx = if (reverse) hi - k else lo + k;
        if (skipped(skip, idx)) continue;
        const s = src.* orelse break;
        const d = dst[idx] orelse continue;
        if (!item_mod.canMerge(d, s)) continue;
        if (mergeCells(alloc, &dst[idx], src, profile.game.item_data.maxStackSize(d.id))) moved = true;
        if (src.* == null) break;
    }
    if (src.* != null) {
        // Empty-slot pass, same scan order (vanilla fills hotbar-end first
        // when reversed).
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const idx = if (reverse) hi - j else lo + j;
            if (skipped(skip, idx)) continue;
            if (dst[idx] != null) continue;
            dst[idx] = src.*;
            src.* = null;
            moved = true;
            break;
        }
    }
    return moved;
}

/// Number-key swap between a resolved cell and the hotbar cell. The caller
/// must reject this while the cursor is non-empty (vanilla rule).
pub fn swap(cell: *?item_mod.Stack, hotbar_cell: *?item_mod.Stack) bool {
    if (cell == hotbar_cell) return false;
    const t = cell.*;
    cell.* = hotbar_cell.*;
    hotbar_cell.* = t;
    return true;
}

/// Shift-click a source cell across SEVERAL destination lists (e.g. a
/// double chest's two halves): merge into compatible stacks first (across
/// everything, in order), then move the remainder into the first empty.
/// `reverse` walks back-to-front (vanilla mergeItemStack reverse pass for
/// into-player moves); forward otherwise (into-container moves).
pub fn quickMoveLists(alloc: std.mem.Allocator, src: *?item_mod.Stack, dsts: []const []?item_mod.Stack, reverse: bool) bool {
    if (src.* == null) return false;
    var moved = false;
    var total: usize = 0;
    for (dsts) |l| total += l.len;
    const at = struct {
        fn cell(d: []const []?item_mod.Stack, total_n: usize, k: usize, rev: bool) *?item_mod.Stack {
            // Caller guarantees k < total_n; find the owning list/cell.
            var idx = if (rev) total_n - 1 - k else k;
            for (d) |l| {
                if (idx < l.len) return &l[idx];
                idx -= l.len;
            }
            unreachable;
        }
    }.cell;
    // Merge pass.
    var k: usize = 0;
    while (k < total) : (k += 1) {
        const cell = at(dsts, total, k, reverse);
        const s = src.* orelse break;
        const d = cell.* orelse continue;
        if (!item_mod.canMerge(d, s)) continue;
        if (mergeCells(alloc, cell, src, profile.game.item_data.maxStackSize(d.id))) moved = true;
        if (src.* == null) break;
    }
    // Empty pass.
    var j: usize = 0;
    while (src.* != null and j < total) : (j += 1) {
        const cell = at(dsts, total, j, reverse);
        if (cell.* != null) continue;
        cell.* = src.*;
        src.* = null;
        moved = true;
    }
    return moved;
}

/// Distributes the cursor stack across resolved drag cells (vanilla 1.7.10
/// mode-5 "painting"). Left-drag splits evenly (remainder +1 to the earliest
/// slots); right-drag puts one item per slot. Only mergeable cells up to
/// their max stack take items; anything undistributable stays on the cursor
/// (totals are conserved by construction). Returns true when anything moved.
pub fn dragDistribute(alloc: std.mem.Allocator, cursor: *?item_mod.Stack, cells: []const *?item_mod.Stack, right: bool) bool {
    const cur = cursor.* orelse return false;
    if (cells.len == 0) return false;
    const limit: i32 = profile.game.item_data.maxStackSize(cur.id);
    var moved = false;
    if (right) {
        var remaining: i32 = cur.count;
        for (cells) |cell| {
            if (remaining <= 0) break;
            if (cell.*) |have| {
                if (!item_mod.canMerge(have, cur)) continue;
                if (have.count >= limit) continue;
                cell.*.?.count += 1;
            } else {
                const duped = cloneNbtOpt(alloc, cur.nbt) catch continue;
                cell.* = .{ .id = cur.id, .count = 1, .damage = cur.damage, .nbt = duped };
            }
            remaining -= 1;
            moved = true;
        }
        if (remaining <= 0) {
            item_mod.freeStack(alloc, cursor);
            cursor.* = null;
        } else {
            cursor.*.?.count = @intCast(remaining);
        }
        return moved;
    }
    // Left-drag: even split with the remainder dealt +1 to the earliest
    // slots first (vanilla var6/var7 distribution).
    const n: i32 = @intCast(cells.len);
    const base: i32 = @divFloor(cur.count, n);
    var extra: i32 = @mod(cur.count, n);
    var remaining: i32 = cur.count;
    for (cells) |cell| {
        var want: i32 = base;
        if (extra > 0) {
            want += 1;
            extra -= 1;
        }
        if (want <= 0) continue;
        if (cell.*) |have| {
            if (!item_mod.canMerge(have, cur)) continue;
            const room: i32 = limit - @as(i32, have.count);
            const give = @min(want, room);
            if (give <= 0) continue;
            cell.*.?.count += @intCast(give);
            remaining -= give;
        } else {
            const give = @min(want, limit);
            if (give <= 0) continue;
            const duped = cloneNbtOpt(alloc, cur.nbt) catch continue;
            cell.* = .{ .id = cur.id, .count = @intCast(give), .damage = cur.damage, .nbt = duped };
            remaining -= give;
        }
        moved = true;
        if (remaining <= 0) break;
    }
    if (remaining <= 0) {
        item_mod.freeStack(alloc, cursor);
        cursor.* = null;
    } else {
        cursor.*.?.count = @intCast(remaining);
    }
    return moved;
}

/// Drag-spread (paint) state machine for vanilla 1.7.10 mode-5 clicks.
/// Client protocol: start (slot -999, button 0/4), any number of add-slot
/// (button 1/5), end (slot -999, button 2/6). Duplicates are ignored. Any
/// other click, a window change, or death cancels the drag (vanilla drops
/// it). Slots are window slots; the owner resolves them to cells (with
/// validity) at END time so mid-drag edits can't desync the distribution.
pub const DragPaint = struct {
    active: bool = false,
    right: bool = false,
    win: i8 = -1,
    slots: [128]u8 = undefined,
    n: usize = 0,

    pub fn reset(self: *DragPaint) void {
        self.active = false;
        self.right = false;
        self.win = -1;
        self.n = 0;
    }

    /// Begin a drag on `win` (caller: requires non-empty cursor).
    pub fn begin(self: *DragPaint, win: i8, right: bool) void {
        self.active = true;
        self.right = right;
        self.win = win;
        self.n = 0;
    }

    /// Record a dragged-over slot. False = ignore (inactive, wrong
    /// window, duplicate, or table full).
    pub fn add(self: *DragPaint, win: i8, slot: usize) bool {
        if (!self.active or win != self.win) return false;
        if (slot > 255) return false;
        const s: u8 = @intCast(slot);
        for (self.slots[0..self.n]) |have| if (have == s) return false;
        if (self.n >= self.slots.len) return false;
        self.slots[self.n] = s;
        self.n += 1;
        return true;
    }
};

/// Clone an optional NBT buffer (drag distribution duplicates the cursor's
/// tag into fresh cells; merge targets keep their own equal tag).
fn cloneNbtOpt(alloc: std.mem.Allocator, nbt: ?[]const u8) !?[]u8 {
    const n = nbt orelse return null;
    return try alloc.dupe(u8, n);
}

/// Take a crafting/furnace result into an empty cursor. Consumes one unit
/// from each non-empty grid cell (crafting) or clears `result` (furnace).
/// Callers are responsible for recomputing recipe results and sending sync.
pub fn takeResult(alloc: std.mem.Allocator, cursor: *?item_mod.Stack, result: *?item_mod.Stack, grid: []?item_mod.Stack) bool {
    if (cursor.* != null) return false;
    const res = result.* orelse return false;
    cursor.* = res;
    result.* = null;
    consumeGrid(alloc, grid);
    return true;
}

/// Take a furnace output (no grid consumption; the tick already consumed
/// the input). Requires an empty cursor.
pub fn takeOutput(cursor: *?item_mod.Stack, output: *?item_mod.Stack) bool {
    if (cursor.* != null) return false;
    const out = output.* orelse return false;
    cursor.* = out;
    output.* = null;
    return true;
}

test "quickMoveLists merges across lists before filling empties" {
    const a = std.testing.allocator;
    const ids = @import("../../ids.zig");
    var l0: [3]?item_mod.Stack = .{ .{ .id = ids.stone, .count = 60, .damage = 0, .nbt = null }, null, null };
    var l1: [3]?item_mod.Stack = .{ .{ .id = ids.stone, .count = 60, .damage = 0, .nbt = null }, null, null };
    var src: ?item_mod.Stack = .{ .id = ids.stone, .count = 64, .damage = 0, .nbt = null };
    // Merge pass fills both partials first (stone caps at 64): l0 -> 64
    // (src 60), l1 -> 64 (src 56); remainder lands in the first empty
    // (l0[1]). Empties never fill while merges are still possible.
    const lists = [_][]?item_mod.Stack{ l0[0..], l1[0..] };
    try std.testing.expect(quickMoveLists(a, &src, &lists, false));
    try std.testing.expectEqual(@as(i8, 64), l0[0].?.count);
    try std.testing.expectEqual(@as(i8, 64), l1[0].?.count);
    try std.testing.expect(src == null);
    try std.testing.expectEqual(@as(i8, 56), l0[1].?.count);
    try std.testing.expect(l1[1] == null);
    // Empty source is a no-op.
    var empty: ?item_mod.Stack = null;
    try std.testing.expect(!quickMoveLists(a, &empty, &lists, false));
}

test "quickMove reverse fills from the end (vanilla hotbar order)" {
    const a = std.testing.allocator;
    const ids = @import("../../ids.zig");
    // Merge pass prefers the LAST partial stack.
    var dst: [5]?item_mod.Stack = .{ .{ .id = ids.dirt, .count = 32, .damage = 0, .nbt = null }, null, null, null, .{ .id = ids.dirt, .count = 32, .damage = 0, .nbt = null } };
    var src: ?item_mod.Stack = .{ .id = ids.dirt, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect(quickMove(a, &src, &dst, 0, 4, null, true));
    try std.testing.expect(src == null);
    try std.testing.expectEqual(@as(i8, 32), dst[0].?.count); // untouched
    try std.testing.expectEqual(@as(i8, 42), dst[4].?.count); // merged here
    // Empty pass lands on the last empty slot.
    var dst2: [5]?item_mod.Stack = .{ null, .{ .id = ids.stone, .count = 1, .damage = 0, .nbt = null }, null, null, null };
    var src2: ?item_mod.Stack = .{ .id = ids.dirt, .count = 7, .damage = 0, .nbt = null };
    try std.testing.expect(quickMove(a, &src2, &dst2, 0, 4, null, true));
    try std.testing.expect(src2 == null);
    try std.testing.expectEqual(@as(i8, 7), dst2[4].?.count);
    try std.testing.expect(dst2[2] == null);
    // Forward keeps the old order (first empty wins).
    var dst3: [5]?item_mod.Stack = .{ null, .{ .id = ids.stone, .count = 1, .damage = 0, .nbt = null }, null, null, null };
    var src3: ?item_mod.Stack = .{ .id = ids.dirt, .count = 7, .damage = 0, .nbt = null };
    try std.testing.expect(quickMove(a, &src3, &dst3, 0, 4, null, false));
    try std.testing.expect(src3 == null);
    try std.testing.expectEqual(@as(i8, 7), dst3[0].?.count);
}

test "dragDistribute splits evenly, remainder first, conserves" {
    const a = std.testing.allocator;
    const ids = @import("../../ids.zig");
    // 10 dirt over 3 empty slots: 4/3/3, cursor emptied.
    var c0: ?item_mod.Stack = null;
    var c1: ?item_mod.Stack = null;
    var c2: ?item_mod.Stack = null;
    var cells = [_]*?item_mod.Stack{ &c0, &c1, &c2 };
    var cur: ?item_mod.Stack = .{ .id = ids.dirt, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect(dragDistribute(a, &cur, &cells, false));
    try std.testing.expect(cur == null);
    try std.testing.expectEqual(@as(i8, 4), c0.?.count);
    try std.testing.expectEqual(@as(i8, 3), c1.?.count);
    try std.testing.expectEqual(@as(i8, 3), c2.?.count);
    // Right-drag: one per slot.
    c0 = null;
    c1 = null;
    c2 = null;
    cur = .{ .id = ids.dirt, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect(dragDistribute(a, &cur, &cells, true));
    try std.testing.expectEqual(@as(i8, 7), cur.?.count);
    try std.testing.expectEqual(@as(i8, 1), c0.?.count);
    try std.testing.expectEqual(@as(i8, 1), c1.?.count);
    try std.testing.expectEqual(@as(i8, 1), c2.?.count);
    // Merging + caps: partial stack tops up first (capped at 64),
    // remainder spreads onward and leftovers stay on the cursor.
    // 10 over [60, empty, other]: 4 -> c0 (64), 3 -> c1, 3 stay.
    c0 = .{ .id = ids.dirt, .count = 60, .damage = 0, .nbt = null };
    c1 = null;
    c2 = .{ .id = ids.stone, .count = 5, .damage = 0, .nbt = null }; // different item: skipped
    cur = .{ .id = ids.dirt, .count = 10, .damage = 0, .nbt = null };
    try std.testing.expect(dragDistribute(a, &cur, &cells, false));
    try std.testing.expectEqual(@as(i8, 3), cur.?.count);
    try std.testing.expectEqual(@as(i8, 64), c0.?.count);
    try std.testing.expectEqual(@as(i8, 3), c1.?.count);
    try std.testing.expectEqual(@as(i8, 5), c2.?.count);
    // NBT tags duplicate into fresh cells without aliasing (heap tag:
    // the consumed cursor is freed, so stack memory would be invalid).
    const tag = [_]u8 { 1, 2, 3 };
    c0 = null;
    c1 = null;
    var one = [_]*?item_mod.Stack{&c0};
    cur = .{ .id = ids.diamond, .count = 1, .damage = 0, .nbt = try a.dupe(u8, &tag) };
    try std.testing.expect(dragDistribute(a, &cur, &one, false));
    try std.testing.expect(cur == null);
    try std.testing.expect(c0.?.nbt != null);
    try std.testing.expect(c0.?.nbt.?.ptr != &tag);
    item_mod.freeStack(a, &c0);
}

/// Insert one whole stack into a range, merging into compatible non-full
/// stacks first and then cloning into the first empty slot. Used by the
/// crafting shift-click loop; returns false when the stack does not fit.
pub fn insertWhole(
    alloc: std.mem.Allocator,
    dst: []?item_mod.Stack,
    lo: usize,
    hi: usize,
    stack: item_mod.Stack,
) !bool {
    std.debug.assert(lo <= hi and hi < dst.len);
    var i = lo;
    while (i <= hi) : (i += 1) {
        const d = dst[i] orelse continue;
        if (!item_mod.canMerge(d, stack)) continue;
        const limit = profile.game.item_data.maxStackSize(d.id);
        if (@as(u16, @intCast(d.count)) + @as(u16, @intCast(stack.count)) > limit) continue;
        dst[i].?.count += stack.count;
        return true;
    }
    i = lo;
    while (i <= hi) : (i += 1) {
        if (dst[i] != null) continue;
        dst[i] = try item_mod.cloneStack(alloc, stack);
        return true;
    }
    return false;
}

/// Consume one unit from every non-empty grid cell (crafting result taken).
pub fn consumeGrid(alloc: std.mem.Allocator, grid: []?item_mod.Stack) void {
    for (grid) |*cell| {
        if (cell.* != null) shrink(alloc, cell, 1);
    }
}