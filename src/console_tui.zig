const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// ANSI escape sequences
const CSI = "\u{1b}[";

/// Log levels with colors
pub const Level = std.log.Level;

/// Stored log capacity
const MAX_LOG_LINES = 300;
/// Stored message bytes per line
const MAX_MSG = 512;
/// Pending messages from other threads
const MAX_LOG_QUEUE = 256;
/// Command history entries
const MAX_HISTORY = 100;
/// Input line length
const MAX_INPUT_LEN = 1024;

/// One fully-owned pending message from any thread.
const LogMessage = struct {
    level: Level,
    timestamp: i64,
    message: [MAX_MSG]u8 = undefined,
    message_len: usize = 0,
};

/// MPSC queue: many producers (any thread via log()), single consumer
/// (the console thread in run()). Guarded by q_lock.
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

/// Fullscreen raw-mode console needs termios + poll + ioctl. Windows has
/// none of these in std.posix (termios is void, poll is a compileError),
/// so it always uses plain line mode. Linux and libc-backed POSIX targets
/// (macOS, *BSD) get the full TUI.
const have_tty = builtin.os.tag != .windows;

/// Seconds since epoch, for HH:MM:SS stamps (portable: the old
/// linux.clock_gettime(CLOCK.REALTIME) is Linux-only; Io .real is the same
/// wall clock on every target, Windows included).
fn getTimestamp(io: ?std.Io) i64 {
    const io_val = io orelse return 0;
    return std.Io.Timestamp.now(io_val, .real).toSeconds();
}

/// A single display line (owned copy, never a slice into temp buffers).
const LogLine = struct {
    level: Level,
    timestamp: i64,
    message: [MAX_MSG]u8 = undefined,
    message_len: usize = 0,

    pub fn format(self: *const LogLine, buf: []u8) []const u8 {
        var time_buf: [8]u8 = undefined;
        const time_str = formatTimestamp(self.timestamp, &time_buf);
        const level_str = levelToString(self.level);
        const level_color = levelToColor(self.level);
        const reset = CSI ++ "0m";
        const dim = CSI ++ "2m";
        if (self.level == .err) {
            // Errors: the entire line stays red.
            return std.fmt.bufPrint(buf, "{s}{s}[{s}] {s}{s}\n", .{
                level_color, time_str, level_str,
                self.message[0..self.message_len], reset,
            }) catch buf[0..0];
        }
        // Normal lines: dim timestamp, colored [LEVEL] tag, plain message.
        return std.fmt.bufPrint(buf, "{s}{s}{s} {s}[{s}]{s} {s}\n", .{
            dim, time_str, reset,
            level_color, level_str, reset,
            self.message[0..self.message_len],
        }) catch buf[0..0];
    }
};

/// Ring of display lines. Only touched by the console thread, no lock needed.
const LogBuffer = struct {
    lines: [MAX_LOG_LINES]LogLine = undefined,
    head: usize = 0, // next write slot
    count: usize = 0,

    pub fn push(self: *LogBuffer, line: LogLine) void {
        self.lines[self.head] = line;
        self.head = (self.head + 1) % MAX_LOG_LINES;
        if (self.count < MAX_LOG_LINES) self.count += 1;
    }

    /// Index from oldest: 0 == oldest stored line.
    pub fn atFromOldest(self: *const LogBuffer, idx: usize) *const LogLine {
        const oldest = (self.head + MAX_LOG_LINES - self.count) % MAX_LOG_LINES;
        return &self.lines[(oldest + idx) % MAX_LOG_LINES];
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

/// Terminal dimensions via ioctl.
const TermSize = struct {
    cols: usize = 80,
    rows: usize = 24,

    pub fn refresh(self: *TermSize) void {
        if (comptime have_tty) {
            var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            // Per-OS request code (Linux 0x5413 differs from macOS/*BSD);
            // raw Linux syscall on Linux, libc ioctl elsewhere.
            const ok = if (comptime builtin.os.tag == .linux)
                linux.ioctl(1, linux.T.IOCGWINSZ, @intFromPtr(&ws)) == 0
            else
                std.c.ioctl(1, std.posix.T.IOCGWINSZ, &ws) == 0;
            if (ok and ws.col > 0 and ws.row > 0) {
                self.cols = @intCast(ws.col);
                self.rows = @intCast(ws.row);
            }
        }
    }
};

/// Editable input line (used by the raw-mode console thread only).
const InputLine = struct {
    buf: [MAX_INPUT_LEN]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    history_index: ?usize = null,

    pub fn clear(self: *InputLine) void {
        self.len = 0;
        self.cursor = 0;
        self.history_index = null;
    }

    pub fn insertByte(self: *InputLine, b: u8) void {
        if (self.len >= MAX_INPUT_LEN) return;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[self.cursor] = b;
        self.len += 1;
        self.cursor += 1;
    }

    pub fn backspace(self: *InputLine) void {
        if (self.cursor == 0) return;
        var i: usize = self.cursor;
        while (i < self.len) : (i += 1) {
            self.buf[i - 1] = self.buf[i];
        }
        self.len -= 1;
        self.cursor -= 1;
    }

    pub fn deleteAtCursor(self: *InputLine) void {
        if (self.cursor >= self.len) return;
        var i: usize = self.cursor + 1;
        while (i < self.len) : (i += 1) {
            self.buf[i - 1] = self.buf[i];
        }
        self.len -= 1;
    }

    pub fn killToEnd(self: *InputLine) void {
        self.len = self.cursor;
    }

    pub fn killLine(self: *InputLine) void {
        self.len = 0;
        self.cursor = 0;
        self.history_index = null;
    }

    pub fn killWordBackward(self: *InputLine) void {
        if (self.cursor == 0) return;
        var pos = self.cursor;
        while (pos > 0 and self.buf[pos - 1] == ' ') pos -= 1;
        while (pos > 0 and self.buf[pos - 1] != ' ') pos -= 1;
        const n = self.cursor - pos;
        var i: usize = self.cursor;
        while (i < self.len) : (i += 1) {
            self.buf[i - n] = self.buf[i];
        }
        self.len -= n;
        self.cursor = pos;
    }

    pub fn getLine(self: *const InputLine) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn setText(self: *InputLine, text: []const u8) void {
        const n = @min(text.len, MAX_INPUT_LEN);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
        self.cursor = n;
    }
};

/// The main console. All display state is owned by the console thread;
/// other threads only touch log_queue (under q_lock).
pub const Console = struct {
    allocator: std.mem.Allocator,
    log_buffer: LogBuffer = .{},
    history: History = .{},
    input: InputLine = .{},
    term_size: TermSize = .{},
    scroll_offset: usize = 0, // 0 == pinned to bottom
    running: bool = true,
    prompt: []const u8 = "> ",
    status_buf: [192]u8 = undefined,
    status_len: usize = 0,
    input_callback: ?*const fn (*Console, []const u8) void = null,
    log_callback: ?*const fn (*Console, Level, []const u8) void = null,
    user_data: ?*anyopaque = null,
    io: ?std.Io = null,
    q_lock: std.atomic.Mutex = .unlocked,
    log_queue: LogQueue = .{},
    tty_mode: ?bool = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Console {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn setIo(self: *Console, io: std.Io) void {
        self.io = io;
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

    fn statusText(self: *const Console) []const u8 {
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
                const ok = self.q_lockPush(level, timestamp, seg);
                std.atomic.Mutex.unlock(&self.q_lock);
                _ = ok; // drop when full; stats spam must not OOM
                any = true;
            }
            if (end >= msg.len) break;
            start = end + 1;
        }
        if (!any and msg.len == 0) {
            while (!std.atomic.Mutex.tryLock(&self.q_lock)) std.atomic.spinLoopHint();
            _ = self.q_lockPush(level, timestamp, "");
            std.atomic.Mutex.unlock(&self.q_lock);
        }
        if (self.log_callback) |cb| cb(self, level, msg);
    }

    fn q_lockPush(self: *Console, level: Level, timestamp: i64, seg: []const u8) bool {
        return self.log_queue.push(level, timestamp, seg);
    }

    pub fn logf(self: *Console, level: Level, comptime format: []const u8, args: anytype) void {
        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, format, args) catch "[log format error]";
        self.log(level, msg);
    }

    pub fn printLog(self: *Console, msg: []const u8) void {
        self.log(.info, msg);
    }

    /// Synchronously drain + display everything queued so far.
    /// Safe to call from the console thread (e.g. right before exit).
    /// No-op from any other thread.
    pub fn flush(self: *Console) void {
        if (self.tty_mode == true) {
            _ = self.drainQueue();
            self.drawFull();
        } else if (self.tty_mode == false) {
            self.flushPlain();
        }
    }

    pub fn stop(self: *Console) void {
        self.running = false;
    }

    pub fn deinit(self: *Console) void {
        self.history.deinit(self.allocator);
    }

    /// Move queued messages into the display buffer. Console thread only.
    fn drainQueue(self: *Console) bool {
        var any = false;
        while (true) {
            while (!std.atomic.Mutex.tryLock(&self.q_lock)) std.atomic.spinLoopHint();
            const m = self.log_queue.pop();
            std.atomic.Mutex.unlock(&self.q_lock);
            const msg = m orelse break;
            any = true;
            var line = LogLine{
                .level = msg.level,
                .timestamp = msg.timestamp,
                .message_len = msg.message_len,
            };
            @memcpy(line.message[0..msg.message_len], msg.message[0..msg.message_len]);
            self.log_buffer.push(line);
        }
        return any;
    }

    fn writer(self: *Console, out_buf: []u8) std.Io.File.Writer {
        const io = self.io.?;
        var stdout = std.Io.File.stdout();
        return stdout.writer(io, out_buf);
    }

    fn clearScreen(self: *Console) void {
        var out_buf: [64]u8 = undefined;
        var w = self.writer(&out_buf);
        _ = w.interface.writeAll(CSI ++ "2J" ++ CSI ++ "H") catch {};
        w.interface.flush() catch {};
    }

    /// Full redraw: logs + status + input. Console thread only.
    fn drawFull(self: *Console) void {
        const io = self.io orelse return;
        var stdout = std.Io.File.stdout();
        var out_buf: [1024]u8 = undefined;
        var w = stdout.writer(io, &out_buf);
        const out = &w.interface;

        self.term_size.refresh();
        const rows = self.term_size.rows;
        const log_height = if (rows > 2) rows - 2 else 1;

        _ = out.writeAll(CSI ++ "2J" ++ CSI ++ "H") catch {};

        // Which slice of history to show. Newest at bottom.
        const total = self.log_buffer.count;
        const off = @min(self.scroll_offset, total);
        const show = @min(log_height, total - off);
        const start = total - off - show; // index from oldest
        var fmt_buf: [2048]u8 = undefined;
        var i: usize = 0;
        while (i < show) : (i += 1) {
            const line = self.log_buffer.atFromOldest(start + i);
            const text = line.format(&fmt_buf);
            _ = out.writeAll(text) catch {};
        }
        // Pad so status/input land on fixed rows.
        var pad = log_height;
        while (pad > show) : (pad -= 1) {
            _ = out.writeAll("\n") catch {};
        }

        // Status row.
        var row_buf: [16]u8 = undefined;
        const srow = std.fmt.bufPrint(&row_buf, "{d}", .{rows - 1}) catch "1";
        _ = out.writeAll(CSI) catch {};
        _ = out.writeAll(srow) catch {};
        _ = out.writeAll(";1H") catch {};
        _ = out.writeAll(CSI ++ "2K") catch {};
        const dim = CSI ++ "2m";
        const reset = CSI ++ "0m";
        if (off > 0) {
            _ = out.print("{s}[scrolled up ({d}) - PgDn/End to follow]{s}", .{ dim, off, reset }) catch {};
        } else if (self.status_len > 0) {
            _ = out.print("{s}{s}{s}", .{ dim, self.statusText(), reset }) catch {};
        } else {
            _ = out.print("{s}log lines: {d}{s}", .{ dim, total, reset }) catch {};
        }

        // Input row.
        var irow: [16]u8 = undefined;
        const irows = std.fmt.bufPrint(&irow, "{d}", .{rows}) catch "1";
        _ = out.writeAll(CSI) catch {};
        _ = out.writeAll(irows) catch {};
        _ = out.writeAll(";1H") catch {};
        _ = out.writeAll(CSI ++ "2K") catch {};
        const bold = CSI ++ "1m";
        _ = out.print("{s}{s}{s}", .{ bold, self.prompt, reset }) catch {};
        _ = out.writeAll(self.input.buf[0..self.input.len]) catch {};

        // Place cursor inside the input.
        var crow: [16]u8 = undefined;
        var ccol: [16]u8 = undefined;
        const crows = std.fmt.bufPrint(&crow, "{d}", .{rows}) catch "1";
        const ccols = std.fmt.bufPrint(&ccol, "{d}", .{self.prompt.len + self.input.cursor + 1}) catch "1";
        _ = out.writeAll(CSI) catch {};
        _ = out.writeAll(crows) catch {};
        _ = out.writeAll(";") catch {};
        _ = out.writeAll(ccols) catch {};
        _ = out.writeAll("H") catch {};

        out.flush() catch {};
    }

    /// Plain (non-TTY) output: one formatted line per queued message.
    fn flushPlain(self: *Console) void {
        const io = self.io orelse return;
        var stdout = std.Io.File.stdout();
        var out_buf: [1024]u8 = undefined;
        var w = stdout.writer(io, &out_buf);
        const out = &w.interface;
        var fmt_buf: [2048]u8 = undefined;
        var any = false;
        while (true) {
            while (!std.atomic.Mutex.tryLock(&self.q_lock)) std.atomic.spinLoopHint();
            const m = self.log_queue.pop();
            std.atomic.Mutex.unlock(&self.q_lock);
            const msg = m orelse break;
            any = true;
            var line = LogLine{
                .level = msg.level,
                .timestamp = msg.timestamp,
                .message_len = msg.message_len,
            };
            @memcpy(line.message[0..msg.message_len], msg.message[0..msg.message_len]);
            self.log_buffer.push(line);
            const text = line.format(&fmt_buf);
            _ = out.writeAll(text) catch {};
        }
        if (any) out.flush() catch {};
    }

    pub fn run(self: *Console) !void {
        if (comptime builtin.os.tag == .windows) {
            // No termios/poll/ioctl on Windows: plain line mode only.
            return self.runPlain();
        } else {
            return self.runPosix();
        }
    }

    /// TTY probe + fullscreen raw mode (POSIX only; Windows never calls
    /// this, so the termios/poll/ioctl references below are never analyzed
    /// there).
    fn runPosix(self: *Console) !void {
        const stdin_fd: std.posix.fd_t = 0;
        // TTY? If stdin has no termios, fall back to plain line mode.
        const orig = std.posix.tcgetattr(stdin_fd) catch {
            return self.runPlain();
        };
        // Also require stdout to be a terminal for fullscreen.
        _ = std.posix.tcgetattr(1) catch {
            return self.runPlain();
        };
        return self.runTty(orig);
    }

    /// Piped / redirected stdin: blocking line reads, plain log output.
    /// Never touches cursor addressing, so `echo help | server` works and
    /// `stop` still shuts the server down.
    fn runPlain(self: *Console) !void {
        self.tty_mode = false;
        const io = self.io orelse return error.InvalidState;
        var stdin = std.Io.File.stdin();
        var line_buf: [MAX_INPUT_LEN]u8 = undefined;
        var reader = stdin.reader(io, &line_buf);
        const rin = &reader.interface;
        var cmd_buf: [MAX_INPUT_LEN]u8 = undefined;
        var cmd_len: usize = 0;

        self.flushPlain();
        while (self.running) {
            self.flushPlain();
            const b = std.Io.Reader.takeByte(@constCast(rin)) catch break;
            if (b == '\n') {
                if (cmd_len > 0) {
                    const cmd = cmd_buf[0..cmd_len];
                    cmd_len = 0;
                    self.history.push(self.allocator, cmd) catch {};
                    // Echo first so it prints before the command's output.
                    self.logf(.info, "{s}{s}", .{ self.prompt, cmd });
                    if (self.input_callback) |cb| cb(self, cmd);
                    self.flushPlain();
                    if (!self.running) break;
                }
            } else if (b == '\r') {
                continue;
            } else if (cmd_len < MAX_INPUT_LEN and b >= 0x20 and b < 0x7f) {
                cmd_buf[cmd_len] = b;
                cmd_len += 1;
            }
        }
        self.flushPlain();
    }

    /// Interactive fullscreen console with raw line editing.
    fn runTty(self: *Console, orig: std.posix.termios) !void {
        const stdin_fd: std.posix.fd_t = 0;
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = true;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        // NOTE: .DRAIN, not .FLUSH: FLUSH would discard input bytes that
        // arrived during startup (e.g. a piped "help\n"), eating commands.
        std.posix.tcsetattr(stdin_fd, .DRAIN, raw) catch {
            return self.runPlain();
        };
        defer std.posix.tcsetattr(stdin_fd, .DRAIN, orig) catch {};
        self.tty_mode = true;
        // Remember for restoreTerminal(): stop exits the process directly
        // and would otherwise skip the defer above, leaving the shell
        // without echo.
        noteRawMode(orig);

        self.term_size.refresh();
        self.clearScreen();
        _ = self.drainQueue();
        self.drawFull();

        var poll_fds: [1]std.posix.pollfd = undefined;
        poll_fds[0] = .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 };
        var read_buf: [64]u8 = undefined;
        var esc_state: u8 = 0; // 0 normal, 1 got ESC, 2 got ESC[, 3 got ESC[<digit>
        var esc_param: u8 = 0;
        var input_closed = false;

        while (self.running) {
            if (self.drainQueue()) self.drawFull();

            const nready = std.posix.poll(&poll_fds, 50) catch break;
            if (nready == 0) continue;
            const re = poll_fds[0].revents;
            if ((re & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
                input_closed = true;
            }
            if ((re & std.posix.POLL.IN) == 0) {
                if (input_closed) {
                    // No more input will ever arrive; keep serving logs.
                    var idle: u32 = 0;
                    while (self.running and idle < 20) {
                        if (self.drainQueue()) {
                            self.drawFull();
                            idle = 0;
                        } else {
                            idle += 1;
                        }
                        _ = std.posix.poll(&poll_fds, 50) catch break;
                    }
                    if (!self.running) break;
                    // Stay alive for logs but don't spin forever in tests:
                    // keep draining at 1Hz until stopped externally.
                    while (self.running) {
                        if (self.drainQueue()) self.drawFull();
                        _ = std.posix.poll(&poll_fds, 1000) catch break;
                    }
                    break;
                }
                continue;
            }

            const n = std.posix.read(stdin_fd, &read_buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
            if (n == 0) {
                input_closed = true;
                continue;
            }
            var dirty = false;
            for (read_buf[0..n]) |b| {
                if (self.handleRawByte(b, &esc_state, &esc_param)) dirty = true;
                if (!self.running) break;
            }
            // Command callbacks queue their replies; show them immediately.
            if (self.drainQueue()) dirty = true;
            if (dirty) self.drawFull();
        }
    }

    /// Returns true if the display needs a redraw. Handles one raw byte.
    /// esc/esc_param carry ESC-sequence state across calls.
    fn handleRawByte(self: *Console, b: u8, esc: *u8, esc_param: *u8) bool {
        // Inside an escape sequence.
        if (esc.* == 1) {
            if (b == '[') {
                esc.* = 2;
            } else {
                esc.* = 0;
            }
            return false;
        }
        if (esc.* == 2) {
            switch (b) {
                'A' => { // Up: history older (or scroll if pinned up?)
                    esc.* = 0;
                    if (self.scroll_offset > 0) {
                        self.scroll_offset += 1;
                    } else if (self.history.count > 0) {
                        const next = (self.input.history_index orelse MAX_HISTORY) + 1;
                        // next==MAX_HISTORY sentinel means "before newest"
                        const idx = if (self.input.history_index == null) @as(usize, 0) else next;
                        if (idx < self.history.count) {
                            self.input.history_index = idx;
                            if (self.history.get(idx)) |h| self.input.setText(h);
                        }
                    }
                    return true;
                },
                'B' => { // Down
                    esc.* = 0;
                    if (self.scroll_offset > 0) {
                        self.scroll_offset -= 1;
                        return true;
                    }
                    if (self.input.history_index) |idx| {
                        if (idx == 0) {
                            self.input.history_index = null;
                            self.input.clear();
                        } else {
                            self.input.history_index = idx - 1;
                            if (self.history.get(idx - 1)) |h| self.input.setText(h);
                        }
                        return true;
                    }
                    return false;
                },
                'C' => { // Right
                    esc.* = 0;
                    if (self.input.cursor < self.input.len) {
                        self.input.cursor += 1;
                        return true;
                    }
                    return false;
                },
                'D' => { // Left
                    esc.* = 0;
                    if (self.input.cursor > 0) {
                        self.input.cursor -= 1;
                        return true;
                    }
                    return false;
                },
                'H' => {
                    esc.* = 0;
                    self.input.cursor = 0;
                    return true;
                },
                'F' => {
                    esc.* = 0;
                    self.input.cursor = self.input.len;
                    return true;
                },
                '3', '5', '6', '1', '4', '7', '8' => {
                    esc_param.* = b;
                    esc.* = 3;
                    return false;
                },
                else => {
                    esc.* = 0;
                    return false;
                },
            }
        }
        if (esc.* == 3) {
            esc.* = 0;
            if (b != '~') return false;
            switch (esc_param.*) {
                '3' => {
                    self.input.deleteAtCursor();
                    return true;
                },
                '5' => { // PgUp
                    const page = if (self.term_size.rows > 3) self.term_size.rows - 3 else 10;
                    self.scroll_offset = @min(self.scroll_offset + page, self.log_buffer.count);
                    return true;
                },
                '6' => { // PgDn
                    const page = if (self.term_size.rows > 3) self.term_size.rows - 3 else 10;
                    if (self.scroll_offset >= page) self.scroll_offset -= page else self.scroll_offset = 0;
                    return true;
                },
                '1', '7' => {
                    self.input.cursor = 0;
                    return true;
                },
                '4', '8' => {
                    self.input.cursor = self.input.len;
                    return true;
                },
                else => return false,
            }
        }

        // Normal byte.
        switch (b) {
            0x1b => {
                esc.* = 1;
                return false;
            },
            '\r', '\n' => {
                const cmd = self.input.getLine();
                if (cmd.len == 0) {
                    // Empty enter: snap back to live tail.
                    if (self.scroll_offset != 0) {
                        self.scroll_offset = 0;
                        return true;
                    }
                    return false;
                }
                var echo: [MAX_INPUT_LEN]u8 = undefined;
                const n = @min(cmd.len, echo.len);
                @memcpy(echo[0..n], cmd[0..n]);
                self.history.push(self.allocator, echo[0..n]) catch {};
                self.input.clear();
                self.scroll_offset = 0;
                // Echo before running so it renders above the output.
                self.logf(.info, "{s}{s}", .{ self.prompt, echo[0..n] });
                if (self.input_callback) |cb| cb(self, echo[0..n]);
                return true;
            },
            0x03 => { // Ctrl-C: graceful stop
                self.input.clear();
                if (self.input_callback) |cb| cb(self, "stop");
                self.log(.info, "]^C (stop)");
                return true;
            },
            0x04 => { // Ctrl-D: stop when line empty
                if (self.input.len == 0) {
                    if (self.input_callback) |cb| cb(self, "stop");
                    self.log(.info, "]^D (stop)");
                    return true;
                }
                return false;
            },
            0x01 => { // Ctrl-A
                self.input.cursor = 0;
                return true;
            },
            0x05 => { // Ctrl-E
                self.input.cursor = self.input.len;
                return true;
            },
            0x0b => { // Ctrl-K
                self.input.killToEnd();
                return true;
            },
            0x15 => { // Ctrl-U
                self.input.killLine();
                return true;
            },
            0x17 => { // Ctrl-W
                self.input.killWordBackward();
                return true;
            },
            0x0c => { // Ctrl-L
                return true; // full redraw
            },
            0x7f, 0x08 => { // Backspace/DEL
                self.input.backspace();
                return true;
            },
            0x09 => return false, // Tab (completion TODO)
            else => {
                if (b >= 0x20 and b < 0x7f) {
                    // Any edit snaps back to live tail.
                    self.scroll_offset = 0;
                    self.input.insertByte(b);
                    return true;
                }
                return false;
            },
        }
    }
};

/// Global console for std.log integration.
var global_console: ?*Console = null;

pub fn setGlobal(c: *Console) void {
    global_console = c;
}

pub fn getGlobal() ?*Console {
    return global_console;
}

/// Termios saved when raw mode is enabled. Kept in a global (not on the
/// Console struct) so ANY stop path — console, RCON, in-game — can restore
/// the terminal even though std.process.exit() skips defers.
var saved_termios: ?std.posix.termios = null;

pub fn noteRawMode(orig: std.posix.termios) void {
    saved_termios = orig;
}

/// Restore the terminal if we put it in raw mode. Idempotent and safe to
/// call from any thread right before process.exit(). Also emits a newline
/// so the shell prompt lands on a fresh line. No-op on Windows (which never
/// enters raw mode).
pub fn restoreTerminal() void {
    if (comptime have_tty) {
        if (saved_termios) |orig| {
            saved_termios = null;
            std.posix.tcsetattr(0, .DRAIN, orig) catch {};
            // Fresh line so the shell prompt doesn't sit on the status row
            // (stderr: unbuffered and always a terminal here).
            std.debug.print("\n", .{});
        }
    }
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

/// HH:MM:SS into the caller's 8-byte buffer.
fn formatTimestamp(ts: i64, buf: []u8) []const u8 {
    const secs_per_day: i64 = 86400;
    const day_secs = @mod(ts, secs_per_day);
    const hour = @as(u8, @intCast(@divTrunc(day_secs, 3600)));
    const minute = @as(u8, @intCast(@divTrunc(@mod(day_secs, 3600), 60)));
    const second = @as(u8, @intCast(@mod(day_secs, 60)));
    buf[0] = '0' + (hour / 10);
    buf[1] = '0' + (hour % 10);
    buf[2] = ':';
    buf[3] = '0' + (minute / 10);
    buf[4] = '0' + (minute % 10);
    buf[5] = ':';
    buf[6] = '0' + (second / 10);
    buf[7] = '0' + (second % 10);
    return buf[0..8];
}

fn levelToString(level: Level) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
}

fn levelToColor(level: Level) []const u8 {
    return switch (level) {
        .debug => CSI ++ "36m",
        .info => CSI ++ "32m",
        .warn => CSI ++ "33m",
        .err => CSI ++ "31m",
    };
}

test "log line colors: tag colored, body plain, errors fully red" {
    var info_line = LogLine{ .level = .info, .timestamp = 0, .message_len = 3 };
    @memcpy(info_line.message[0..3], "hey");
    var buf: [256]u8 = undefined;
    const info_text = info_line.format(&buf);
    // Tag colored green...
    try std.testing.expect(std.mem.indexOf(u8, info_text, CSI ++ "32m[INFO]" ++ CSI ++ "0m") != null);
    // ...body plain (no color code immediately before it).
    try std.testing.expect(std.mem.indexOf(u8, info_text, CSI ++ "0m hey\n") != null);

    var err_line = LogLine{ .level = .err, .timestamp = 0, .message_len = 3 };
    @memcpy(err_line.message[0..3], "bad");
    var ebuf: [256]u8 = undefined;
    const err_text = err_line.format(&ebuf);
    // Whole error line wrapped in red.
    try std.testing.expect(std.mem.startsWith(u8, err_text, CSI ++ "31m"));
    try std.testing.expect(std.mem.endsWith(u8, err_text, "bad" ++ CSI ++ "0m\n"));
}
