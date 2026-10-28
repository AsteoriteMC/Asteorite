//! OS shutdown signals -> save + flush + exit pipeline.
//!
//! Installs one tiny async-signal-safe handler per platform that only sets
//! an atomic flag (never touches locks, IO, or the allocator). The server's
//! ticker loop polls the flag and calls `Server.finishStop()` — the exact
//! same pipeline as `/stop` (save players + redstone, flush store,
//! restore terminal, exit).
//!
//! Covered signals:
//! - POSIX (Linux, macOS, *BSD, ...): SIGINT, SIGTERM, SIGHUP, SIGQUIT.
//!   SIGPIPE is ignored (sockets already use MSG_NOSIGNAL; this covers the
//!   rest of the process).
//! - Windows: CTRL_C, CTRL_BREAK, CTRL_CLOSE, CTRL_LOGOFF, CTRL_SHUTDOWN
//!   via SetConsoleCtrlHandler.
//! - Other targets (wasi, uefi, ...): no OS hook available; the flag API
//!   still works (a second caller can `request()` directly).
//!
//! A second signal while a shutdown is already in progress force-exits
//! immediately (save may be hung — the operator asked twice).

const std = @import("std");
const builtin = @import("builtin");

/// Set by the OS handler; polled by the ticker loop + serve accept loop.
var requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// True once any shutdown signal arrived (or `request()` was called).
pub fn isRequested() bool {
    return requested.load(.seq_cst);
}

/// Request a graceful shutdown (async-signal-safe: atomic store only).
/// A second request force-exits: the first save may be hung.
pub fn request() void {
    if (requested.load(.seq_cst)) std.process.exit(1);
    requested.store(true, .seq_cst);
}

/// Test hook: clear a previous `request()` (never used by production code;
/// the flag is one-way once the OS handler fires).
pub fn resetForTest() void {
    requested.store(false, .seq_cst);
}

// ---------------------------------------------------------------------------
// POSIX
// ---------------------------------------------------------------------------

const have_sig_int = std.posix.SIG != void and @hasField(std.posix.SIG, "INT");
const have_sig_term = std.posix.SIG != void and @hasField(std.posix.SIG, "TERM");
const have_sig_hup = std.posix.SIG != void and @hasField(std.posix.SIG, "HUP");
const have_sig_quit = std.posix.SIG != void and @hasField(std.posix.SIG, "QUIT");
const have_sig_pipe = std.posix.SIG != void and @hasField(std.posix.SIG, "PIPE");

fn posixHandler(_: std.posix.SIG) callconv(.c) void {
    request();
}

fn installPosix() void {
    if (std.posix.Sigaction == void) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = posixHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    if (have_sig_int) std.posix.sigaction(.INT, &act, null);
    if (have_sig_term) std.posix.sigaction(.TERM, &act, null);
    if (have_sig_hup) std.posix.sigaction(.HUP, &act, null);
    if (have_sig_quit) std.posix.sigaction(.QUIT, &act, null);
    // Broken-pipe writes must never kill the server; sockets already send
    // with MSG_NOSIGNAL, this covers any other fd.
    if (have_sig_pipe) {
        const ign: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.PIPE, &ign, null);
    }
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

const windows = std.os.windows;
const WIN_BOOL = windows.BOOL;
const WIN_DWORD = windows.DWORD;

const CTRL_C_EVENT: WIN_DWORD = 0;
const CTRL_BREAK_EVENT: WIN_DWORD = 1;
const CTRL_CLOSE_EVENT: WIN_DWORD = 2;
const CTRL_LOGOFF_EVENT: WIN_DWORD = 5;
const CTRL_SHUTDOWN_EVENT: WIN_DWORD = 6;

extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (WIN_DWORD) callconv(.winapi) WIN_BOOL,
    Add: WIN_BOOL,
) callconv(.winapi) WIN_BOOL;

fn winHandler(ctrl_type: WIN_DWORD) callconv(.winapi) WIN_BOOL {
    switch (ctrl_type) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT => {
            request();
            return WIN_BOOL.TRUE; // handled: don't run the default killer.
        },
        else => return WIN_BOOL.FALSE, // let the system handle it.
    }
}

fn installWindows() void {
    _ = SetConsoleCtrlHandler(&winHandler, WIN_BOOL.TRUE);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

var installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Install OS shutdown hooks (idempotent, thread-safe). Async-signal-safe handlers only
/// set the atomic flag — the ticker loop performs the actual save+exit.
pub fn install() void {
    if (installed.swap(true, .acq_rel)) return;
    if (builtin.os.tag == .windows) {
        installWindows();
    } else if (std.posix.Sigaction != void) {
        installPosix();
    }
}

test "shutdown flag is one-way (request sticks until test reset)" {
    resetForTest();
    try std.testing.expect(!isRequested());
    requested.store(true, .seq_cst);
    try std.testing.expect(isRequested());
    resetForTest();
    try std.testing.expect(!isRequested());
}
