//! Operator console TUI built on the ZigZag framework (Model-Update-View).
//!
//! Same process role as before: the console owns a background thread
//! (`run`, spawned detached from main), every other thread logs through a
//! lock-guarded MPSC queue, and stdin commands dispatch to
//! `Server.handleCommand` via the input callback. Only the TTY rendering
//! and input editing moved to ZigZag — RichLog (level colors, scrollback),
//! TextInput (editing, suggestions), a Logs/Status/Help tab strip, and a
//! status bar, all with diff rendering instead of full-screen rewrites.
//!
//! Layout (terminal W x H):
//!   row 0:      header ("Asteorite" + boot status string)
//!   row 1:      tab strip (F1 Logs / F2 Status / F3 Help)
//!   rows 2..H-3: active panel (log window, status panel, or help)
//!   row H-2:    status bar (log count, follow state, key hints)
//!   row H-1:    command input (prompt "> ", Tab accepts suggestion)
//!
//! Keys: Enter runs the line, Up/Down walks history, PgUp/PgDn/Home/End
//! scroll the log, F1/F2/F3 switch tabs, Ctrl-C (or Ctrl-D on an empty
//! line) issues `stop`. j/k/g/G deliberately do NOT scroll — they are
//! command text.
//!
//! Shutdown: every stop path (console/RCON/in-game/SIGINT) ends in
//! `restoreTerminal()` + `exit(0)`. The console-initiated path stops the
//! Program cleanly first (`.quit` unwinds through `Program.deinit`, which
//! restores the terminal), and `restoreTerminal()` re-emits the leave-alt-
//! screen/show-cursor sequences directly so the RCON/in-game paths — which
//! never touch the Program — restore the terminal too. All of it is safe
//! from any thread and idempotent.

const std = @import("std");
const zz = @import("zigzag");

/// Log levels (mirrors std.log so the logFn hook needs no translation table
/// beyond RichLog's own enum).
pub const Level = std.log.Level;

/// Stored log capacity (owned copies in the queue, then owned by RichLog).
const MAX_LOG_LINES = 500;
/// Stored message bytes per line.
const MAX_MSG = 512;
/// Pending messages from other threads.
const MAX_LOG_QUEUE = 256;
/// Command history entries.
const MAX_HISTORY = 100;
/// Input line length (matches the server command buffer: 1 + 1024).
const MAX_INPUT_LEN = 1024;

/// One fully-owned pending message from any thread.
const LogMessage = struct {
    level: Level,
    timestamp: i64,
    message: [MAX_MSG]u8 = undefined,
    message_len: usize = 0,
};

/// MPSC queue: many producers (any thread via log()), single consumer
/// (the console thread in the tick handler). Guarded by q_lock.
const LogQueue = struct {
    buffer: [MAX_LOG_QUEUE]LogMessage = undefined,
    head: usize = 0,
    tail: usize = 0,
    full: bool = false,

    pub fn push(self: *LogQueue, level: Level, timestamp: i64, msg: []const u8) bool {
        if (self.full) return false;
        var entry = &self.buffer[self.tail];
        entry.level = level;
        entry.timestamp = timestamp;
        entry.message_len = @min(msg.len, MAX_MSG);
        @memcpy(entry.message[0..entry.message_len], msg[0..entry.message_len]);
        self.tail = (self.tail + 1) % MAX_LOG_QUEUE;
        if (self.tail == self.head) self.full = true;
        return true;
    }

    pub fn pop(self: *LogQueue) ?LogMessage {
        if (!self.full and self.head == self.tail) return null;
        const entry = self.buffer[self.head];
        self.head = (self.head + 1) % MAX_LOG_QUEUE;
        self.full = false;
        return entry;
    }

    pub fn isEmpty(self: *const LogQueue) bool {
        return !self.full and self.head == self.tail;
    }
};

/// Command history (owned copies).
const History = struct {
    entries: [MAX_HISTORY]?[]const u8 = undefined,
    count: usize = 0,
    head: usize = 0,

    pub fn push(self: *History, allocator: std.mem.Allocator, cmd: []const u8) !void {
        if (cmd.len == 0) return;
        if (self.count > 0) {
            const last_idx = (self.head + MAX_HISTORY - 1) % MAX_HISTORY;
            if (self.entries[last_idx]) |last| {
                if (std.mem.eql(u8, last, cmd)) return;
            }
        }
        const copy = try allocator.dupe(u8, cmd);
        if (self.count == MAX_HISTORY) {
            if (self.entries[self.head]) |old| allocator.free(old);
        } else {
            self.count += 1;
        }
        self.entries[self.head] = copy;
        self.head = (self.head + 1) % MAX_HISTORY;
    }

    /// index 0 == newest
    pub fn get(self: *History, index: usize) ?[]const u8 {
        if (index >= self.count) return null;
        const idx = (self.head + MAX_HISTORY - 1 - index) % MAX_HISTORY;
        return self.entries[idx];
    }

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (0..self.count) |i| {
            const idx = (self.head + MAX_HISTORY - 1 - i) % MAX_HISTORY;
            if (self.entries[idx]) |e| allocator.free(e);
        }
        self.count = 0;
        self.head = 0;
    }
};

/// Seconds since epoch, for the queue (RichLog timestamps the entries
/// itself on append; this stamps queue transit only for potential loss
/// accounting — currently unused beyond parity with the old path).
fn getTimestamp(io: ?std.Io) i64 {
    const io_val = io orelse return 0;
    return std.Io.Timestamp.now(io_val, .real).toSeconds();
}

/// Slash-command suggestions for Tab completion in the input row.
const suggestions: []const []const u8 = &.{
    "help", "list", "stop", "save-all", "save-on", "save-off",
    "op ", "deop ", "gamemode ", "difficulty ", "time ", "weather ",
    "give ", "tp ", "spawnpoint ", "setworldspawn ", "gamerule ",
    "whitelist ", "ban ", "ban-ip ", "pardon ", "kick ", "say ",
    "tell ", "seed ", "netstat ", "status ",
};

/// The console. Display state (RichLog/TextInput/tabs) lives in the TUI
/// model on the console thread; other threads only touch log_queue
/// (under q_lock).
pub const Console = struct {
    allocator: std.mem.Allocator,
    history: History = .{},
    prompt: []const u8 = "> ",
    status_buf: [192]u8 = undefined,
    status_len: usize = 0,
    input_callback: ?*const fn (*Console, []const u8) void = null,
    log_callback: ?*const fn (*Console, Level, []const u8) void = null,
    user_data: ?*anyopaque = null,
    io: ?std.Io = null,
    environ_map: ?*const std.process.Environ.Map = null,
    q_lock: std.atomic.Mutex = .unlocked,
    log_queue: LogQueue = .{},
    running: bool = true,
    /// Set by the console input callback when it issues `stop`: tells the
    /// thread wrapper to exit(0) after the Program unwinds cleanly.
    exit_after_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Console {
        // Snapshot the shell's termios BEFORE the TUI thread flips stdin
        // raw: restoreTerminal() puts it back on every exit(0) path that
        // skips the Program's own restore defer. Non-tty stdin (tests,
        // piped runs) fails here and restores as a no-op.
        saved_termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch null;
        return .{ .allocator = allocator, .io = io };
    }

    pub fn setIo(self: *Console, io: std.Io) void {
        self.io = io;
    }

    pub fn setEnvironMap(self: *Console, map: *const std.process.Environ.Map) void {
        self.environ_map = map;
    }

    pub fn setUserData(self: *Console, data: *anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Console) ?*anyopaque {
        return self.user_data;
    }

    pub fn setInputCallback(self: *Console, cb: fn (*Console, []const u8) void) void {
        self.input_callback = &cb;
    }

    pub fn setLogCallback(self: *Console, cb: fn (*Console, Level, []const u8) void) void {
        self.log_callback = &cb;
    }

    pub fn setStatus(self: *Console, text: []const u8) void {
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
    }

    pub fn statusText(self: *const Console) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    /// Thread-safe: split multi-line messages so one queue entry == one row.
    pub fn log(self: *Console, level: Level, msg: []const u8) void {
        const timestamp = getTimestamp(self.io);
        var start: usize = 0;
        var any = false;
        while (start <= msg.len) {
            var end = start;
            while (end < msg.len and msg[end] != '\n') : (end += 1) {}
            var seg = msg[start..end];
            if (seg.len > 0 and seg[seg.len - 1] == '\r') seg = seg[0 .. seg.len - 1];
            if (seg.len > 0) {
                while (!std.atomic.Mutex.tryLock(&self.q_lock)) std.atomic.spinLoopHint();
                const ok = self.log_queue.push(level, timestamp, seg);
                std.atomic.Mutex.unlock(&self.q_lock);
                _ = ok; // drop when full; stats spam must not OOM
                any = true;
            }
            if (end >= msg.len) break;
            start = end + 1;
        }
        if (!any and msg.len == 0) {
            while (!std.atomic.Mutex.tryLock(&self.q_lock)) std.atomic.spinLoopHint();
            _ = self.log_queue.push(level, timestamp, "");
            std.atomic.Mutex.unlock(&self.q_lock);
        }
        if (self.log_callback) |cb| cb(self, level, msg);
    }

    pub fn logf(self: *Console, level: Level, comptime format: []const u8, args: anytype) void {
        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, format, args) catch "[log format error]";
        self.log(level, msg);
    }

    pub fn printLog(self: *Console, msg: []const u8) void {
        self.log(.info, msg);
    }

    /// Stop-path helper: the console callback logs its goodbye line into the
    /// queue and `update` drains it on the next tick before quitting, so the
    /// bye renders before exit. This only yields briefly: draining happens
    /// on the TUI thread's ticks, never here.
    pub fn flush(self: *Console) void {
        var spins: u32 = 0;
        while (spins < 1000) : (spins += 1) {
            while (!std.atomic.Mutex.tryLock(&self.q_lock)) std.atomic.spinLoopHint();
            const empty = self.log_queue.isEmpty();
            std.atomic.Mutex.unlock(&self.q_lock);
            if (empty) break;
            std.atomic.spinLoopHint();
        }
    }

    pub fn stop(self: *Console) void {
        self.running = false;
    }

    pub fn deinit(self: *Console) void {
        self.history.deinit(self.allocator);
    }

    /// Console thread entry: owns the ZigZag Program (terminal init, input,
    /// diff rendering, restore-on-return). All other threads keep logging
    /// into the queue while this runs.
    pub fn run(self: *Console) !void {
        const io = self.io orelse return error.InvalidState;
        const env = self.environ_map orelse return error.InvalidState;
        var program = zz.Program(TuiModel).initWithModel(self.allocator, io, env, .{
            .console = self,
        }, .{
            .title = "Asteorite",
            .alt_screen = true,
            .fps = 30,
        });
        defer program.deinit();
        try program.run();
    }
};

/// Map std.log levels onto RichLog levels.
fn mapLevel(l: Level) zz.RichLogLevel {
    return switch (l) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
}

/// ZigZag application model. Owned by the Program on the console thread.
/// `console` is pre-set by `initWithModel`; everything else is built in
/// `init` from the persistent allocator and torn down in `deinit`.
const TuiModel = struct {
    console: *Console,
    log: zz.RichLog = undefined,
    input: zz.TextInput = undefined,
    tabs: zz.TabGroup = undefined,
    status_bar: zz.StatusBar = undefined,
    history_nav: ?usize = null,
    log_count: usize = 0,
    /// Set when a stop arrives mid-frame: one more tick renders the goodbye
    /// line before `.quit` unwinds the Program (terminal restored by deinit).
    quit_armed: bool = false,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *TuiModel, ctx: *zz.Context) !zz.Cmd(Msg) {
        const p = ctx.persistent_allocator;
        self.log = zz.RichLog.init(p, MAX_LOG_LINES);
        self.log.show_timestamps = true;
        errdefer self.log.deinit();
        self.input = zz.TextInput.init(p);
        self.input.setPrompt("> ");
        self.input.setPlaceholder("command…  Tab completes  F1/F2/F3 tabs  PgUp/PgDn scrolls");
        self.input.setCharLimit(MAX_INPUT_LEN);
        self.input.setSuggestions(suggestions);
        errdefer self.input.deinit();
        self.tabs = zz.TabGroup.init(p);
        // Render-only strip: we switch tabs on F-keys explicitly so number
        // keys stay command text (number_shortcuts would eat 1/2/3 while
        // typing) and Tab stays completion.
        self.tabs.focused = false;
        self.tabs.number_shortcuts = false;
        self.tabs.show_numbers = true;
        errdefer self.tabs.deinit();
        _ = try self.tabs.addTab(.{ .id = "logs", .title = "Logs" });
        _ = try self.tabs.addTab(.{ .id = "status", .title = "Status" });
        _ = try self.tabs.addTab(.{ .id = "help", .title = "Help" });
        _ = self.tabs.setActive(0, .init);
        self.status_bar = zz.StatusBar.init(p);
        errdefer self.status_bar.deinit();
        self.status_bar.setSeparator(" · ");
        self.history_nav = null;
        self.log_count = 0;
        // Drain anything queued during boot before the first frame.
        self.drainQueue(ctx);
        return zz.Cmd(Msg).tickMs(50);
    }

    pub fn deinit(self: *TuiModel) void {
        self.status_bar.deinit();
        self.tabs.deinit();
        self.input.deinit();
        self.log.deinit();
    }

    /// Move every queued message into the RichLog. TUI thread only.
    fn drainQueue(self: *TuiModel, ctx: *zz.Context) void {
        const c = self.console;
        while (true) {
            while (!std.atomic.Mutex.tryLock(&c.q_lock)) std.atomic.spinLoopHint();
            const m = c.log_queue.pop();
            std.atomic.Mutex.unlock(&c.q_lock);
            const msg = m orelse break;
            const lvl = mapLevel(msg.level);
            self.log.append(ctx.io, lvl, msg.message[0..msg.message_len]) catch {
                // OOM in the log view must never kill the console: drop.
                continue;
            };
            self.log_count += 1;
        }
    }

    /// Submit one input line: history + echo + server dispatch.
    fn submitLine(self: *TuiModel, raw: []const u8) void {
        const c = self.console;
        if (raw.len == 0) {
            self.log.scrollToEnd();
            return;
        }
        var echo: [MAX_INPUT_LEN + 4]u8 = undefined;
        const n = @min(raw.len, MAX_INPUT_LEN);
        @memcpy(echo[0..n], raw[0..n]);
        const line = echo[0..n];
        c.history.push(c.allocator, line) catch {};
        self.history_nav = null;
        self.input.setValue("") catch {};
        self.log.appendFmt(c.io orelse return, .info, "{s}{s}", .{ c.prompt, line }) catch {};
        if (c.input_callback) |cb| cb(c, line);
    }

    pub fn update(self: *TuiModel, msg: Msg, ctx: *zz.Context) !zz.Cmd(Msg) {
        // A stop issued anywhere (console command, RCON path flag) quits
        // the Program: deinit restores the terminal, then the thread
        // wrapper exits the process. The first stop sighting arms one
        // final tick so the goodbye line renders; the second quits.
        if (!self.console.running) {
            self.drainQueue(ctx);
            if (self.quit_armed) return .quit;
            self.quit_armed = true;
            return zz.Cmd(Msg).tickMs(50);
        }
        switch (msg) {
            .tick => {
                self.drainQueue(ctx);
                if (!self.console.running) return .quit;
                return zz.Cmd(Msg).tickMs(50);
            },
            .key => |k| {
                // F-keys switch tabs (never Tab/numbers — those belong to
                // completion and command text).
                if (!k.modifiers.any()) {
                    switch (k.key) {
                        .f1 => {
                            _ = self.tabs.setActive(0, .set_active);
                            return zz.Cmd(Msg).tickMs(50);
                        },
                        .f2 => {
                            _ = self.tabs.setActive(1, .set_active);
                            return zz.Cmd(Msg).tickMs(50);
                        },
                        .f3 => {
                            _ = self.tabs.setActive(2, .set_active);
                            return zz.Cmd(Msg).tickMs(50);
                        },
                        else => {},
                    }
                }
                // Ctrl-C always means stop (even mid-line); Ctrl-D stops on
                // an empty line. Matches the old console exactly.
                if (k.modifiers.ctrl) {
                    switch (k.key) {
                        .char => |ch| switch (ch) {
                            'c' => {
                                self.submitLine("stop");
                                if (!self.console.running) return .quit;
                                return zz.Cmd(Msg).tickMs(50);
                            },
                            'd' => {
                                if (self.input.getValue().len == 0) {
                                    self.submitLine("stop");
                                    if (!self.console.running) return .quit;
                                }
                                return zz.Cmd(Msg).tickMs(50);
                            },
                            else => {},
                        },
                        else => {},
                    }
                }
                switch (k.key) {
                    .enter => {
                        var cmd_buf: [MAX_INPUT_LEN]u8 = undefined;
                        const v = self.input.getValue();
                        const n = @min(v.len, cmd_buf.len);
                        @memcpy(cmd_buf[0..n], v[0..n]);
                        self.submitLine(cmd_buf[0..n]);
                        self.drainQueue(ctx);
                        if (!self.console.running) return .quit;
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    .up => {
                        // History older (no log-scroll hijack: Up is history).
                        const count = self.console.history.count;
                        if (count > 0) {
                            const next = if (self.history_nav) |i| @min(i + 1, count - 1) else @as(usize, 0);
                            self.history_nav = next;
                            if (self.console.history.get(next)) |h| {
                                self.input.setValue(h) catch {};
                            }
                        }
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    .down => {
                        if (self.history_nav) |i| {
                            if (i == 0) {
                                self.history_nav = null;
                                self.input.setValue("") catch {};
                            } else {
                                self.history_nav = i - 1;
                                if (self.console.history.get(i - 1)) |h| {
                                    self.input.setValue(h) catch {};
                                }
                            }
                        }
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    .page_up => {
                        self.log.scrollUp(self.log.height);
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    .page_down => {
                        try self.log.scrollDown(self.log.height);
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    .home => {
                        self.log.scrollToStart();
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    .end => {
                        self.log.scrollToEnd();
                        return zz.Cmd(Msg).tickMs(50);
                    },
                    else => {},
                }
                // Any edit snaps back to the live tail (same as the old
                // console: typing while scrolled up follows new output).
                const before = self.input.getValue().len;
                self.input.handleKey(k);
                if (self.input.getValue().len != before) self.log.scrollToEnd();
                return zz.Cmd(Msg).tickMs(50);
            },
        }
    }

    pub fn view(self: *const TuiModel, ctx: *const zz.Context) ![]const u8 {
        const w: usize = @max(ctx.width, 20);
        const h: usize = @max(ctx.height, 6);
        const body_h: usize = @max(h -| 4, 1);

        // Header: title + boot status string.
        var title_style = zz.Style{};
        title_style = title_style.bold(true);
        title_style = title_style.fg(zz.Color.cyan);
        title_style = title_style.inline_style(true);
        const title = try title_style.render(ctx.allocator, "▚ Asteorite 1.7.10");
        var dim_style = zz.Style{};
        dim_style = dim_style.fg(zz.Color.gray(12));
        dim_style = dim_style.inline_style(true);
        const status_raw = self.console.statusText();
        const status_trim: []const u8 = if (status_raw.len > 0) status_raw else "operator console";
        const status = try dim_style.render(ctx.allocator, status_trim);
        const header = try zz.joinHorizontal(ctx.allocator, &.{ title, "  ", status });

        // Tab strip (render-only; switching is F-key driven).
        const strip = try self.tabs.view(ctx.allocator);

        // Body panel.
        const active = self.tabs.activeIndex() orelse 0;
        const body: []const u8 = switch (active) {
            1 => try self.statusPanel(ctx, w),
            2 => try helpPanel(ctx),
            else => blk: {
                @constCast(&self.log).setSize(@intCast(@min(w, 0xffff)), @intCast(@min(body_h, 0xffff)));
                break :blk try self.log.view(ctx.allocator);
            },
        };
        const padded_body = try padToHeight(ctx.allocator, body, body_h);

        // Status bar: log count + follow state + key hints.
        var foot_style = zz.Style{};
        foot_style = foot_style.fg(zz.Color.gray(12));
        foot_style = foot_style.inline_style(true);
        const follow: []const u8 = "follow";
        const foot_text = try std.fmt.allocPrint(ctx.allocator, "logs {d} · {s} · F1 Logs F2 Status F3 Help · PgUp/PgDn scroll · Enter run", .{ self.log_count, follow });
        const foot = try foot_style.render(ctx.allocator, foot_text);

        // Input row.
        @constCast(&self.input).setWidth(@intCast(@min(w, 0xffff)));
        const input_row = try self.input.view(ctx.allocator);

        return try zz.joinVertical(ctx.allocator, &.{ header, strip, padded_body, foot, input_row });
    }

    /// Status tab: boot status string + what the console offers.
    fn statusPanel(self: *const TuiModel, ctx: *const zz.Context, w: usize) ![]const u8 {
        var box_style = zz.Style{};
        box_style = box_style.borderAll(zz.Border.rounded);
        box_style = box_style.borderForeground(zz.Color.cyan);
        box_style = box_style.paddingAll(1);
        box_style = box_style.width(@min(w -| 2, 72));
        var head_style = zz.Style{};
        head_style = head_style.bold(true);
        head_style = head_style.fg(zz.Color.cyan);
        head_style = head_style.inline_style(true);
        const head = try head_style.render(ctx.allocator, "Server status");
        const status_raw = self.console.statusText();
        const status_line: []const u8 = if (status_raw.len > 0) status_raw else "(no status set yet)";
        const content = try std.fmt.allocPrint(ctx.allocator, "{s}\n\n{s}\n\nType a command below and press Enter.\nF1 returns to the log view.", .{ head, status_line });
        const boxed = try box_style.render(ctx.allocator, content);
        return boxed;
    }
};

/// Static help tab: every key the console understands.
fn helpPanel(ctx: *const zz.Context) ![]const u8 {
    var box_style = zz.Style{};
    box_style = box_style.borderAll(zz.Border.rounded);
    box_style = box_style.borderForeground(zz.Color.green);
    box_style = box_style.paddingAll(1);
    box_style = box_style.width(62);
    var head_style = zz.Style{};
    head_style = head_style.bold(true);
    head_style = head_style.fg(zz.Color.green);
    head_style = head_style.inline_style(true);
    const head = try head_style.render(ctx.allocator, "Console keys");
    const content = try std.fmt.allocPrint(ctx.allocator,
        \\{s}
        \\
        \\  Enter        run command line
        \\  Up / Down    command history
        \\  Tab          accept suggestion
        \\  PgUp / PgDn  scroll log (Home/End jump)
        \\  F1 / F2 / F3  Logs / Status / Help tabs
        \\  Ctrl-C       stop the server (even mid-line)
        \\  Ctrl-D       stop when the line is empty
        \\
        \\Commands run with full console authority: try help, list,
        \\status, save-all, stop. Log lines keep their level colors;
        \\errors render red, warnings yellow.
    , .{head});
    return try box_style.render(ctx.allocator, content);
}

/// Pad a (possibly short) panel with blank rows so the status bar and the
/// input row pin to the bottom of the terminal.
fn padToHeight(allocator: std.mem.Allocator, body: []const u8, want: usize) ![]const u8 {
    const have = zz.height(body);
    if (have >= want) return body;
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    parts[n] = body;
    n += 1;
    var i: usize = have;
    while (i < want and n < parts.len) : (i += 1) {
        parts[n] = "";
        n += 1;
    }
    return try zz.joinVertical(allocator, parts[0..n]);
}

/// Global console for std.log integration.
var global_console: ?*Console = null;

pub fn setGlobal(c: *Console) void {
    global_console = c;
}

pub fn getGlobal() ?*Console {
    return global_console;
}

/// Restore the terminal from ANY stop path (console/RCON/in-game/signal),
/// even though `std.process.exit()` skips the Program's restore defer.
/// Restores termios first (ZigZag runs stdin raw: ECHO/ICANON/ISIG off —
/// escape sequences alone can't bring echo back, which is what stranded
/// shells), then emits the leave-alternate-screen / show-cursor /
/// leave-bracketed-paste sequences directly: safe from any thread,
/// idempotent, and a no-op when output is not a terminal.
var saved_termios: ?std.posix.termios = null;

pub fn restoreTerminal() void {
    if (saved_termios) |t| std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, t) catch {};
    const seq = "\u{1b}[?2004l\u{1b}[?1049l\u{1b}[?25h\n";
    std.debug.print("{s}", .{seq});
}

/// std.log hook: queue the message for the console thread. Never blocks
/// the caller and never writes to stdout directly.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const cptr = global_console orelse {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, format, args) catch "[log format error]";
        std.debug.print("[{s}] {s}: {s}\n", .{ @tagName(level), @tagName(scope), msg });
        return;
    };
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch "[log format error]";
    cptr.logf(level, "{s}", .{msg});
}

test "log queue: push/pop round-trips, full drops" {
    var q = LogQueue{};
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.push(.info, 0, "hello"));
    try std.testing.expect(!q.isEmpty());
    const m = q.pop().?;
    try std.testing.expectEqualStrings("hello", m.message[0..m.message_len]);
    try std.testing.expect(q.pop() == null);
    // Fill to capacity: further pushes fail instead of growing.
    for (0..MAX_LOG_QUEUE) |i| {
        var tmp: [8]u8 = undefined;
        const t = try std.fmt.bufPrint(&tmp, "{d}", .{i});
        _ = q.push(.info, 0, t);
    }
    try std.testing.expect(!q.push(.info, 0, "overflow"));
}

test "history: newest-first, consecutive dedupe" {
    const a = std.testing.allocator;
    var h = History{};
    defer h.deinit(a);
    try h.push(a, "list");
    try h.push(a, "list");
    try h.push(a, "stop");
    try std.testing.expectEqual(@as(usize, 2), h.count);
    try std.testing.expectEqualStrings("stop", h.get(0).?);
    try std.testing.expectEqualStrings("list", h.get(1).?);
}

test "level map covers std.log levels" {
    try std.testing.expect(mapLevel(.debug) == .debug);
    try std.testing.expect(mapLevel(.info) == .info);
    try std.testing.expect(mapLevel(.warn) == .warn);
    try std.testing.expect(mapLevel(.err) == .err);
}
