//! 1.7.10 chat packets (serverbound text + clientbound JSON + escaping).

const std = @import("std");
const codec = @import("../../../net/codec.zig");
const ids = @import("../ids.zig");


/// Serverbound chat 0x01: plain-text message (validated by caller).
pub fn parseChat(body: []const u8) codec.CodecError![]const u8 {
    var r = codec.PacketReader.init(body);
    return try r.readString();
}


/// Clientbound chat 0x02: pre-formatted JSON string.
pub fn frameChat(json: []const u8, out: []u8) codec.CodecError![]const u8 {
    var payload: [4096]u8 = undefined;
    var w = codec.PacketWriter.init(&payload);
    try w.writeString(json);
    return try codec.framePacket(@intFromEnum(ids.PlayClient.chat_message), w.written(), out);
}


/// Escape one raw string for embedding in JSON (quotes, backslashes,
/// control chars). Rejects invalid UTF-8 like formatChatJson does.
pub fn escapeJsonText(in: []const u8, out: []u8) error{ BadMessage, OutOfMemory }![]const u8 {
    if (!std.unicode.utf8ValidateSlice(in)) return error.BadMessage;
    const hex = "0123456789abcdef";
    var p: usize = 0;
    for (in) |c| {
        if (c == '"') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = '"';
            p += 2;
        } else if (c == '\\') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = '\\';
            p += 2;
        } else if (c == '\n') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 'n';
            p += 2;
        } else if (c == '\r') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 'r';
            p += 2;
        } else if (c == '\t') {
            if (p + 2 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 't';
            p += 2;
        } else if (c < 0x20) {
            if (p + 6 > out.len) return error.OutOfMemory;
            out[p] = '\\';
            out[p + 1] = 'u';
            out[p + 2] = '0';
            out[p + 3] = '0';
            out[p + 4] = hex[c >> 4];
            out[p + 5] = hex[c & 0xF];
            p += 6;
        } else {
            if (p + 1 > out.len) return error.OutOfMemory;
            out[p] = c;
            p += 1;
        }
    }
    return out[0..p];
}


/// `<name> message` chat line as JSON with escaping. Rejects invalid UTF-8,
/// overlong messages (>100 code points, mirroring the vanilla client cap),
/// and names with characters outside [A-Za-z0-9_].
pub fn formatChatJson(name: []const u8, msg: []const u8, out: []u8) error{ BadName, BadMessage, OutOfMemory }![]const u8 {
    if (name.len == 0 or name.len > 16) return error.BadName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.BadName;
    }
    if (!std.unicode.utf8ValidateSlice(msg)) return error.BadMessage;
    const points = std.unicode.utf8CountCodepoints(msg) catch return error.BadMessage;
    if (points == 0 or points > 100) return error.BadMessage;
    const hex = "0123456789abcdef";
    var p: usize = 0;
    const put = struct {
        fn s(o: []u8, pp: *usize, s_: []const u8) error{OutOfMemory}!void {
            if (pp.* + s_.len > o.len) return error.OutOfMemory;
            @memcpy(o[pp.*..][0..s_.len], s_);
            pp.* += s_.len;
        }
        fn c(o: []u8, pp: *usize, ch: u8) error{OutOfMemory}!void {
            if (pp.* + 1 > o.len) return error.OutOfMemory;
            o[pp.*] = ch;
            pp.* += 1;
        }
    };
    try put.s(out, &p, "{\"text\":\"<");
    try put.s(out, &p, name);
    try put.s(out, &p, "> ");
    for (msg) |c| {
        if (c == '"') {
            try put.s(out, &p, "\\\"");
        } else if (c == '\\') {
            try put.s(out, &p, "\\\\");
        } else if (c == '\n') {
            try put.s(out, &p, "\\n");
        } else if (c == '\r') {
            try put.s(out, &p, "\\r");
        } else if (c == '\t') {
            try put.s(out, &p, "\\t");
        } else if (c < 0x20) {
            try put.s(out, &p, "\\u00");
            try put.c(out, &p, hex[c >> 4]);
            try put.c(out, &p, hex[c & 0xF]);
        } else {
            try put.c(out, &p, c);
        }
    }
    try put.s(out, &p, "\"}");
    return out[0..p];
}


test "chat format + frame roundtrip" {
    var out: [512]u8 = undefined;
    const j = try formatChatJson("Steve", "hi \"there\" \\ ok", &out);
    try std.testing.expectEqualStrings("{\"text\":\"<Steve> hi \\\"there\\\" \\\\ ok\"}", j);
    // control chars escaped, multibyte preserved
    const j2 = try formatChatJson("Al", "a\nb\x01é", &out);
    try std.testing.expectEqualStrings("{\"text\":\"<Al> a\\nb\\u0001é\"}", j2);
    // rejects: bad name, empty, too long, invalid utf-8
    try std.testing.expectError(error.BadName, formatChatJson("a b", "hi", &out));
    try std.testing.expectError(error.BadName, formatChatJson("", "hi", &out));
    var long: [101]u8 = [_]u8{'x'} ** 101;
    try std.testing.expectError(error.BadMessage, formatChatJson("Al", &long, &out));
    try std.testing.expectError(error.BadMessage, formatChatJson("Al", "\xff\xfe", &out));
    try std.testing.expectError(error.OutOfMemory, formatChatJson("Steve", "hi", out[0..10]));
    // 0x02 frame carries the JSON verbatim (1.7 has no position byte)
    var fb: [512]u8 = undefined;
    const f = try frameChat(j, &fb);
    var r = codec.PacketReader.init(f);
    try std.testing.expectEqual(@as(i32, 0x02), (try codec.decodeFrame(&r)).id);
    try std.testing.expectEqualStrings(j, try r.readString());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // serverbound parse is a plain string
    var sb: [32]u8 = undefined;
    var w = codec.PacketWriter.init(&sb);
    try w.writeString("hello there");
    try std.testing.expectEqualStrings("hello there", try parseChat(w.written()));
}
