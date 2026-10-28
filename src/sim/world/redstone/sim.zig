//! Redstone tick driver: drain, plate polling, scheduler persistence.

const std = @import("std");
const common = @import("common.zig");
const components = @import("components.zig");
const power = @import("power.zig");
const schedule = @import("schedule.zig");
const at = common.at;
const buttonOn = components.buttonOn;
const isButton = components.isButton;
const isPiston = components.isPiston;
const isPlate = components.isPlate;
const isRepeater = components.isRepeater;
const pistonFacing = components.pistonFacing;
const pistonVec = components.pistonVec;
const repeaterDelay = components.repeaterDelay;
const repeaterOn = components.repeaterOn;
const Staged = power.Staged;
const notify = power.notify;
const pistonCanExtend = power.pistonCanExtend;
const pistonExtend = power.pistonExtend;
const pistonPowered = power.pistonPowered;
const pistonRetract = power.pistonRetract;
const repeaterInputPowered = power.repeaterInputPowered;
const repeaterLocked = power.repeaterLocked;
const ActionList = schedule.ActionList;
const BurnoutMap = schedule.BurnoutMap;
const ChangeList = schedule.ChangeList;
const PlatePos = schedule.PlatePos;
const PlateSet = schedule.PlateSet;
const SchedEntry = schedule.SchedEntry;
const SchedKind = schedule.SchedKind;
const Scheduler = schedule.Scheduler;
const SoundList = schedule.SoundList;
const max_scheduled_per_tick = schedule.max_scheduled_per_tick;
const sched_cap = schedule.sched_cap;

// ---------------------------------------------------------------------------
// per-tick work: scheduled queue + pressure plates
// ---------------------------------------------------------------------------
//
// Vanilla plates re-check only via scheduled 20-tick updates while pressed
// (`ajd`: schedule only when fresh level > 0) plus entity-collision
// triggers; the server polls every tick instead (same outcome, faster
// release). Repeater evals and button releases ride the same queue.

pub const Ent = struct { x: f64, y: f64, z: f64 };

/// popDue batch size (the outer max_scheduled_per_tick budget caps the
/// whole drain; this sizes one popDue slice).
pub const drain_batch: usize = 128;

/// Drain due scheduled entries (budgeted) and poll registered plates.
/// Entity slices are player/mob/item positions for plate detection.
pub fn tick(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    plates: *PlateSet,
    changes: *ChangeList,
    sounds: *SoundList,
    now: i64,
    players: []const Ent,
    mobs: []const Ent,
    items: []const Ent,
    actions: ?*ActionList,
) void {
    drainScheduled(world, sched, burn, changes, sounds, now, actions);
    pollPlates(world, sched, burn, plates, changes, sounds, now, players, mobs, items, false);
}

/// Drain due scheduled entries (budgeted). No entity access: safe to run on
/// the fast redstone thread, which passes no entity slices (plates stay on
/// the 1Hz tick that owns the snapshots).
pub fn drainScheduled(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    changes: *ChangeList,
    sounds: *SoundList,
    now: i64,
    actions: ?*ActionList,
) void {
    var stage = Staged(@TypeOf(world)).init(world);
    const w = &stage;
    const bl = w.blocks;
    const rs = w.rules;
    var due: [drain_batch]SchedEntry = undefined;
    var total: usize = 0;
    while (total < max_scheduled_per_tick) {
        const n = sched.popDue(now, &due);
        if (n == 0) break;
        for (due[0..n]) |e| {
            total += 1;
            if (total > max_scheduled_per_tick) break;
            const b = at(w, e.x, e.y, e.z);
            switch (e.kind) {
                .button_release => {
                    if (isButton(bl, b) and buttonOn(bl, b)) {
                        const nm: u4 = b.meta & ~@as(u4, 8);
                        w.set(e.x, e.y, e.z, b.id, nm);
                        sounds.append(.{ .kind = .click_off, .x = e.x, .y = e.y, .z = e.z });
                        notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                    }
                },
                .repeater_eval => {
                    if (isRepeater(bl, b)) {
                        if (repeaterLocked(w, e.x, e.y, e.z, b.meta)) continue;
                        const in_pow = repeaterInputPowered(w, e.x, e.y, e.z, b.meta);
                        if (in_pow != repeaterOn(bl, b)) {
                            const nid = if (in_pow) rs.repeater_on else rs.repeater_off;
                            w.set(e.x, e.y, e.z, nid, b.meta);
                            notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                        }
                    }
                },
                .ore_fade => {
                    if (bl.get(b.id).redstone_kind == .ore_lit) {
                        w.set(e.x, e.y, e.z, rs.ore, b.meta);
                    }
                },
                .piston_extend, .piston_retract => {
                    // `app.a(ahb,IIIIII)` onBlockEventReceived: re-validate
                    // power at fire time, then doMove. Piston writes go
                    // straight through (silent changes; the S24 action
                    // carries the client animation). The stage is flushed
                    // FIRST: doMove writes bypass it, and a stale read memo
                    // would make the post-move recompute see the PRE-move
                    // piston state and schedule a spurious opposite event
                    // (which then blocks the real one via the per-position
                    // scheduler dedupe).
                    if (!isPiston(bl, b)) continue;
                    const facing = pistonFacing(b.meta);
                    const powered = pistonPowered(w, e.x, e.y, e.z, facing);
                    var did = false;
                    if (e.kind == .piston_extend and powered and pistonCanExtend(w, e.x, e.y, e.z, facing)) {
                        stage.commit(changes);
                        did = pistonExtend(world, e.x, e.y, e.z, facing, changes, sounds);
                    } else if (e.kind == .piston_retract and !powered) {
                        stage.commit(changes);
                        pistonRetract(world, e.x, e.y, e.z, facing, changes, sounds);
                        did = true;
                    }
                    if (did) {
                        if (actions) |al| {
                            al.append(.{
                                .x = e.x,
                                .y = e.y,
                                .z = e.z,
                                .event_id = if (e.kind == .piston_extend) 0 else 1,
                                .facing = facing,
                                .id = b.id,
                            });
                        }
                        // Consequences (wire/torch/support updates around
                        // every touched cell) stay client-visible: recompute
                        // via the stage, non-silent — the piston cell plus
                        // the two cells ahead of the head.
                        const v = pistonVec(facing);
                        for ([3]i32{ 0, 1, 2 }) |k| {
                            notify(w, sched, burn, sounds, e.x + k * v.dx, e.y + k * v.dy, e.z + k * v.dz, now);
                        }
                    }
                },
                .wire_check => {
                    // Safety valve: the per-edit budget exhausted mid-decay.
                    notify(w, sched, burn, sounds, e.x, e.y, e.z, now);
                },
            }
        }
        if (n < due.len) break;
    }
    stage.commit(changes);
}

/// Pressure-plate polling: count entities in the vanilla detection box
/// (x+0.125..x+0.875, y..y+0.25, z+0.125..z+0.875); stone senses living
/// (players+mobs), wood senses everything (vanilla: all entities — arrows
/// and XP orbs don't exist yet, so players+mobs+items).
pub fn pollPlates(
    world: anytype,
    sched: *Scheduler,
    burn: *BurnoutMap,
    plates: *PlateSet,
    changes: *ChangeList,
    sounds: *SoundList,
    now: i64,
    players: []const Ent,
    mobs: []const Ent,
    items: []const Ent,
    press_only: bool,
) void {
    var stage = Staged(@TypeOf(world)).init(world);
    const w = &stage;
    var i: usize = 0;
    while (i < plates.n) {
        const p = plates.items[i];
        const b = at(w, p.x, p.y, p.z);
        const k = w.blocks.get(b.id).redstone_kind;
        if (!isPlate(w.blocks, b)) {
            // Stale entry (broken plate): drop it.
            plates.items[i] = plates.items[plates.n - 1];
            plates.pressed[i] = plates.pressed[plates.n - 1];
            plates.n -= 1;
            continue;
        }
        i += 1;
        const wooden = k == .plate_wood;
        const n_ent = countOnPlate(p, players, mobs, items, wooden or k == .plate_light or k == .plate_heavy);
        // amu.d / aol.e: stone/wood meta 0/1; weighted ceil(15*min(n,max)/max).
        const want: u4 = switch (k) {
            .plate_stone, .plate_wood => if (n_ent > 0) 1 else 0,
            .plate_light => @truncate(@min(n_ent, 15)),
            .plate_heavy => @truncate(@min((n_ent + 9) / 10, 15)),
            else => 0,
        };
        // Compare against the STORED meta (not the output level — stone/wood
        // output 15 while storing 1; comparing levels made every poll
        // rewrite + re-notify a pressed plate).
        const have: u4 = b.meta;
        if (want == have) continue;
        // Vanilla minimum press: plates re-check on a 20-tick schedule, so
        // a tap stays pressed for a full second even if vacated instantly.
        // Releasing on the 1Hz poll instead would land phase-dependently
        // (0-1s of jitter on top of occupancy). Hold the release until 20
        // ticks after the rising edge; re-presses while held never shorten
        // it, and the stored meta (not a second write) carries the state.
        if (want != 0 and have == 0) {
            plates.pressed[i] = now;
        } else if (want == 0) {
            if (now -% plates.pressed[i] < 20) continue; // hold: not yet due
        }
        if (press_only and want == 0) continue; // movement hook: press only
        w.set(p.x, p.y, p.z, b.id, want);
        sounds.append(.{ .kind = if (want != 0) .click_on else .click_off, .x = p.x, .y = p.y, .z = p.z });
        notify(w, sched, burn, sounds, p.x, p.y, p.z, now);
    }
    stage.commit(changes);
}

/// Entities standing on a plate (stone senses living only; wood and
/// weighted sense items too).
fn countOnPlate(p: PlatePos, players: []const Ent, mobs: []const Ent, items: []const Ent, sense_items: bool) usize {
    var n: usize = 0;
    for (players) |e| n += @intFromBool(overPlate(e, p));
    for (mobs) |e| n += @intFromBool(overPlate(e, p));
    if (sense_items) {
        for (items) |e| n += @intFromBool(overPlate(e, p));
    }
    return n;
}

/// Vanilla detection-box test (ajd.a): inset plate_inset on XZ,
/// plate_height tall.
pub const plate_inset: f64 = 0.125;
pub const plate_height: f64 = 0.25;

fn overPlate(e: Ent, p: PlatePos) bool {
    // Vanilla detection box (ajd.a): inset 0.125, height 0.25.
    const fx: f64 = @floatFromInt(p.x);
    const fy: f64 = @floatFromInt(p.y);
    const fz: f64 = @floatFromInt(p.z);
    return e.x >= fx + plate_inset and e.x < fx + 1.0 - plate_inset and e.z >= fz + plate_inset and e.z < fz + 1.0 - plate_inset and
        e.y >= fy and e.y < fy + plate_height;
}

// ---------------------------------------------------------------------------
// scheduler persistence (vanilla TileTicks equivalent)
// ---------------------------------------------------------------------------
//
// The scheduler lives in one LSM row so pressed buttons, in-flight
// repeaters and lit ore survive restarts (otherwise a reboot would leave
// buttons pressed forever — nothing would ever re-schedule their release).
// Reserved key dim 253 (254 = perms matrix, 255 = player rows).
// Format: u16 BE count, then per entry x/y/z i32 BE + kind u8 + reserved u8.
// Dues are NOT stored (they live in the rs_tick epoch, which restarts at
// boot); the loader re-derives a fresh delay from the block still present.

pub const sched_key: [9]u8 = .{ 253, 0x80, 0, 0, 0, 0x80, 0, 0, 0 };

/// Legacy world height cap for persisted scheduler rows.
pub const max_world_y: i32 = 255;

/// One persisted scheduler row (x/y/z + kind + reserved).
pub const sched_row_bytes: usize = 14;

/// True for scheduler kinds that persist across restarts (button
/// releases, repeater evals, ore fades — piston events and wire checks
/// are transient).
fn persistedKind(kind: SchedKind) bool {
    return switch (kind) {
        .button_release, .repeater_eval, .ore_fade => true,
        else => false,
    };
}

pub fn encodeSched(alloc: std.mem.Allocator, sched: *const Scheduler) ![]u8 {
    const n = @min(sched.n, sched_cap);
    var kept: usize = 0;
    for (sched.entries[0..n]) |e| {
        if (persistedKind(e.kind)) kept += 1;
    }
    const out = try alloc.alloc(u8, 2 + kept * sched_row_bytes);
    std.mem.writeInt(u16, out[0..2], @intCast(kept), .big);
    var i: usize = 0;
    for (sched.entries[0..n]) |e| {
        if (!persistedKind(e.kind)) continue;
        const o = 2 + i * sched_row_bytes;
        std.mem.writeInt(i32, out[o + 0 ..][0..4], e.x, .big);
        std.mem.writeInt(i32, out[o + 4 ..][0..4], e.y, .big);
        std.mem.writeInt(i32, out[o + 8 ..][0..4], e.z, .big);
        out[o + 12] = @intFromEnum(e.kind);
        out[o + 13] = 0; // reserved
        i += 1;
    }
    return out;
}

/// Load persisted entries, re-deriving dues from the blocks still present.
/// Stale entries (block gone/changed) are skipped. Returns the count
/// restored. Caller holds world_lock (same as all scheduler mutation).
pub fn loadSched(world: anytype, raw: []const u8, sched: *Scheduler, now: i64) usize {
    if (raw.len < 2) return 0;
    const bl = world.blocks;
    const rs = world.rules;
    const n = std.mem.readInt(u16, raw[0..2], .big);
    var restored: usize = 0;
    var i: usize = 0;
    while (i < n and 2 + (i + 1) * sched_row_bytes <= raw.len) : (i += 1) {
        const o = 2 + i * sched_row_bytes;
        const x = std.mem.readInt(i32, raw[o + 0 ..][0..4], .big);
        const y = std.mem.readInt(i32, raw[o + 4 ..][0..4], .big);
        const z = std.mem.readInt(i32, raw[o + 8 ..][0..4], .big);
        if (raw[o + 12] >= @typeInfo(SchedKind).@"enum".fields.len) continue;
        if (raw[o + 12] > 2) continue; // old rows never carry transient kinds
        const kind: SchedKind = @enumFromInt(raw[o + 12]);
        if (y < 0 or y > max_world_y) continue;
        const b = at(world, x, y, z);
        const due: i64 = switch (kind) {
            .button_release => if (!isButton(bl, b) or !buttonOn(bl, b)) continue else now + if (bl.get(b.id).redstone_kind == .button_stone) rs.button_ticks_stone else rs.button_ticks_wood,
            .repeater_eval => if (!isRepeater(bl, b)) continue else now + repeaterDelay(rs, b.meta),
            .ore_fade => if (bl.get(b.id).redstone_kind != .ore_lit) continue else now + rs.ore_fade_ticks,
            // transient kinds never persist; unreachable for well-formed rows
            .piston_extend, .piston_retract, .wire_check => continue,
        };
        sched.schedule(x, y, z, due, kind);
        restored += 1;
    }
    return restored;
}

// ---------------------------------------------------------------------------
// tests (HashMap mock world; set/pop record like the server adapter)
// ---------------------------------------------------------------------------
