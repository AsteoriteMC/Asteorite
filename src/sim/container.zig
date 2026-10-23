//! Shared container click primitives (C3).
//!
//! Window layout and packet framing stay at the profile/network edge. This
//! module owns only the item-conservation rules: pickup/place/merge, quick
//! move, number-key swap, crafting-result consumption, and insertion into a
//! player range. All stacks here are owned canonical stacks; callers pass
//! their allocator for NBT deep-copies/frees.
//!
//! The module deliberately does not import `proto/**`, `net/**`, or any
//! profile root. Window 0/1/2 alias maps remain in `conn.zig`/`server.zig`.

const std = @import("std");
const item_mod = @import("../item.zig");

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
            cell.* = .{
                .id = c.id,
                .count = 1,
                .damage = c.damage,
                .nbt = if (c.nbt) |n| try alloc.dupe(u8, n) else null,
            };
            cursor.*.?.count -= 1;
            if (cursor.*.?.count <= 0) item_mod.freeStack(alloc, cursor);
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
            cursor.* = .{
                .id = st.id,
                .count = take,
                .damage = st.damage,
                .nbt = if (st.nbt) |n| try alloc.dupe(u8, n) else null,
            };
            cell.*.?.count -= take;
            if (cell.*.?.count <= 0) item_mod.freeStack(alloc, cell);
        }
        return true;
    }
    // Both sides occupied: merge, otherwise swap.
    const dst = cell.*.?;
    const src = cursor.*.?;
    const limit = item_mod.maxStackSize(dst.id);
    if (item_mod.canMerge(dst, src) and dst.count < limit) {
        const space: i16 = @as(i16, limit) - dst.count;
        var n: i16 = if (button == 0) @min(space, @as(i16, src.count)) else 1;
        if (space <= 0 or n <= 0) return false;
        if (n > src.count) n = src.count;
        cell.*.?.count += @as(i8, @intCast(n));
        cursor.*.?.count -= @as(i8, @intCast(n));
        if (cursor.*.?.count <= 0) item_mod.freeStack(alloc, cursor);
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
    const limit = item_mod.maxStackSize(d.id);
    if (d.count >= limit) return false;
    const room: i16 = @as(i16, limit) - d.count;
    const n: i16 = @min(room, @as(i16, s.count));
    if (n <= 0) return false;
    dst.*.?.count += @as(i8, @intCast(n));
    src.*.?.count -= @as(i8, @intCast(n));
    if (src.*.?.count <= 0) item_mod.freeStack(alloc, src);
    return true;
}

/// Shift-click a source cell into a destination range: merge into compatible
/// stacks first, then move the remainder into the first empty. `skip` is the
/// source's index when `src` aliases `dst` (the slot must not receive itself).
pub fn quickMove(
    alloc: std.mem.Allocator,
    src: *?item_mod.Stack,
    dst: []?item_mod.Stack,
    lo: usize,
    hi: usize,
    skip: ?usize,
) bool {
    if (src.* == null) return false;
    std.debug.assert(lo <= hi and hi < dst.len);
    var moved = false;
    var i = lo;
    while (i <= hi) : (i += 1) {
        if (skip) |s| {
            if (i == s) continue;
        }
        const s = src.* orelse break;
        const d = dst[i] orelse continue;
        if (!item_mod.canMerge(d, s)) continue;
        const room: i16 = @as(i16, item_mod.maxStackSize(d.id)) - d.count;
        if (room <= 0) continue;
        const n: i16 = @min(room, @as(i16, s.count));
        if (n <= 0) continue;
        dst[i].?.count += @as(i8, @intCast(n));
        src.*.?.count -= @as(i8, @intCast(n));
        moved = true;
        if (src.*.?.count <= 0) {
            item_mod.freeStack(alloc, src);
            break;
        }
    }
    if (src.* != null) {
        i = lo;
        while (i <= hi) : (i += 1) {
            if (skip) |s| {
                if (i == s) continue;
            }
            if (dst[i] != null) continue;
            dst[i] = src.*;
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

/// Take a crafting/furnace result into an empty cursor. Consumes one unit
/// from each non-empty grid cell (crafting) or clears `result` (furnace).
/// Callers are responsible for recomputing recipe results and sending sync.
pub fn takeResult(alloc: std.mem.Allocator, cursor: *?item_mod.Stack, result: *?item_mod.Stack, grid: []?item_mod.Stack) bool {
    if (cursor.* != null) return false;
    const res = result.* orelse return false;
    cursor.* = res;
    result.* = null;
    for (grid) |*cell| {
        if (cell.*) |_| {
            cell.*.?.count -= 1;
            if (cell.*.?.count <= 0) item_mod.freeStack(alloc, cell);
        }
    }
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
        const limit = item_mod.maxStackSize(d.id);
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
        if (cell.*) |_| {
            cell.*.?.count -= 1;
            if (cell.*.?.count <= 0) item_mod.freeStack(alloc, cell);
        }
    }
}
