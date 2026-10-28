//! Minimal TOML parser: just enough for the server config file.
//!
//! Supported: `[table]` headers, `key = value` pairs, basic (`"..."`) and
//! literal (`'...'`) strings, integers (decimal/hex/octal/binary,
//! underscores), floats, bools, multiline arrays, inline tables, and `#`
//! comments. Rejected: `[[array tables]]`, dotted keys, dates/times,
//! multi-line strings. Anything malformed is a distinct `Error` variant.
//!
//! All strings, arrays, and tables are allocated from `backing` — pass an
//! arena (the server process arena never frees; tests use a local one),
//! so the result needs no deinit beyond the arena itself.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []Value,
    table: []Entry,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Error = error{
    BadSyntax,
    BadString,
    BadNumber,
    BadValue,
    DuplicateTable,
    DuplicateKey,
    Unsupported,
    OutOfMemory,
};

/// Look up `key` in a table (linear scan; config files are tiny).
pub fn get(table: []const Entry, key: []const u8) ?Value {
    for (table) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

pub fn parse(backing: std.mem.Allocator, text: []const u8) Error![]Entry {
    var p = Parser{ .text = text, .backing = backing };
    return p.parseRoot();
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    backing: std.mem.Allocator,
    tables: std.ArrayList(Table) = .empty,

    const Table = struct {
        name: ?[]const u8,
        entries: std.ArrayList(Entry) = .empty,
    };

    fn eof(p: *const Parser) bool {
        return p.pos >= p.text.len;
    }

    fn peek(p: *const Parser) u8 {
        return p.text[p.pos];
    }

    /// Spaces and tabs only (never newlines).
    fn skipWs(p: *Parser) void {
        while (!p.eof() and (p.peek() == ' ' or p.peek() == '\t')) p.pos += 1;
    }

    /// Whitespace, newlines, and full-line comments (for inside arrays and
    /// inline tables, which may span lines).
    fn skipWsAll(p: *Parser) void {
        while (!p.eof()) {
            const c = p.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.pos += 1;
            } else if (c == '#') {
                p.eatLine();
            } else break;
        }
    }

    /// Consume through the end of the current line (comment or blank tail).
    fn eatLine(p: *Parser) void {
        while (!p.eof() and p.peek() != '\n') p.pos += 1;
        if (!p.eof()) p.pos += 1; // the newline itself
    }

    /// After a value or header: only whitespace, a comment, or EOL may
    /// follow (one pair per line, like TOML requires).
    fn expectEol(p: *Parser) Error!void {
        p.skipWs();
        if (p.eof()) return;
        const c = p.peek();
        if (c == '\n' or c == '\r') {
            p.eatLine();
            return;
        }
        if (c == '#') {
            p.eatLine();
            return;
        }
        return error.BadSyntax;
    }

    fn parseRoot(p: *Parser) Error![]Entry {
        try p.tables.append(p.backing, .{ .name = null });
        var cur: usize = 0;
        while (!p.eof()) {
            p.skipWs();
            if (p.eof()) break;
            const c = p.peek();
            if (c == '\n' or c == '\r') {
                p.eatLine();
                continue;
            }
            if (c == '#') {
                p.eatLine();
                continue;
            }
            if (c == '[') {
                cur = try p.parseTableHeader();
                continue;
            }
            try p.parseKeyval(cur);
        }
        // Finalize: borrow each table's entries; the root entry list is the
        // unnamed table's pairs plus one entry per named table.
        var out = std.ArrayList(Entry).empty;
        errdefer out.deinit(p.backing);
        for (p.tables.items, 0..) |*t, i| {
            if (i == 0) {
                try out.appendSlice(p.backing, t.entries.items);
            } else {
                try out.append(p.backing, .{
                    .key = t.name.?,
                    .value = .{ .table = try t.entries.toOwnedSlice(p.backing) },
                });
            }
        }
        // Free the builder shells (entry storage now owned by `out`).
        for (p.tables.items) |*t| t.entries.deinit(p.backing);
        p.tables.deinit(p.backing);
        return out.toOwnedSlice(p.backing);
    }

    fn parseTableHeader(p: *Parser) Error!usize {
        p.pos += 1; // '['
        if (!p.eof() and p.peek() == '[') return error.Unsupported;
        p.skipWs();
        const name = try p.parseBareKey();
        p.skipWs();
        if (p.eof() or p.peek() != ']') return error.BadSyntax;
        p.pos += 1;
        for (p.tables.items[1..]) |t| {
            if (std.mem.eql(u8, t.name.?, name)) return error.DuplicateTable;
        }
        try p.tables.append(p.backing, .{ .name = name });
        try p.expectEol();
        return p.tables.items.len - 1;
    }

    fn parseKeyval(p: *Parser, cur: usize) Error!void {
        const key = try p.parseKey();
        p.skipWs();
        if (p.eof() or p.peek() != '=') return error.BadSyntax;
        p.pos += 1;
        p.skipWs();
        const val = try p.parseValue();
        try p.expectEol();
        if (get(p.tables.items[cur].entries.items, key) != null) return error.DuplicateKey;
        try p.tables.items[cur].entries.append(p.backing, .{ .key = key, .value = val });
    }

    /// Bare `key` or quoted `"key"` / `'key'`; dotted keys are rejected.
    fn parseKey(p: *Parser) Error![]const u8 {
        if (p.eof()) return error.BadSyntax;
        const c = p.peek();
        if (c == '"' or c == '\'') return p.parseString();
        const key = try p.parseBareKey();
        if (!p.eof() and p.peek() == '.') return error.Unsupported;
        return key;
    }

    fn parseBareKey(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (!p.eof()) {
            const c = p.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                p.pos += 1;
            } else break;
        }
        if (p.pos == start) return error.BadSyntax;
        return p.text[start..p.pos];
    }

    fn parseValue(p: *Parser) Error!Value {
        if (p.eof()) return error.BadValue;
        switch (p.peek()) {
            '"' => return .{ .string = try p.parseString() },
            '\'' => return .{ .string = try p.parseString() },
            '{' => return .{ .table = try p.parseInlineTable() },
            '[' => return .{ .array = try p.parseArray() },
            't' => {
                try p.expectLiteral("true");
                return .{ .boolean = true };
            },
            'f' => {
                try p.expectLiteral("false");
                return .{ .boolean = false };
            },
            '+', '-', '0'...'9' => return try p.parseNumber(),
            else => return error.BadValue,
        }
    }

    fn expectLiteral(p: *Parser, lit: []const u8) Error!void {
        if (p.pos + lit.len > p.text.len) return error.BadValue;
        if (!std.mem.eql(u8, p.text[p.pos..][0..lit.len], lit)) return error.BadValue;
        p.pos += lit.len;
        // Must be delimited: `truex` is not a bool.
        if (!p.eof()) {
            const c = p.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') return error.BadValue;
        }
    }

    fn parseString(p: *Parser) Error![]const u8 {
        const quote = p.peek();
        p.pos += 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(p.backing);
        while (true) {
            if (p.eof()) return error.BadString;
            const c = p.peek();
            if (c == quote) {
                p.pos += 1;
                return out.toOwnedSlice(p.backing);
            }
            if (c == '\n') return error.BadString; // no raw newlines (no """)
            if (quote == '\'' or c != '\\') {
                try out.append(p.backing, c);
                p.pos += 1;
                continue;
            }
            // Basic-string escape.
            p.pos += 1;
            if (p.eof()) return error.BadString;
            switch (p.peek()) {
                '"', '\\', '/' => {
                    try out.append(p.backing, p.peek());
                    p.pos += 1;
                },
                'b' => {
                    try out.append(p.backing, 0x08);
                    p.pos += 1;
                },
                'f' => {
                    try out.append(p.backing, 0x0c);
                    p.pos += 1;
                },
                'n' => {
                    try out.append(p.backing, '\n');
                    p.pos += 1;
                },
                'r' => {
                    try out.append(p.backing, '\r');
                    p.pos += 1;
                },
                't' => {
                    try out.append(p.backing, '\t');
                    p.pos += 1;
                },
                'u', 'U' => try p.parseUnicodeEscape(&out),
                else => return error.BadString,
            }
        }
    }

    fn hexVal(c: u8) Error!u21 {
        if (c >= '0' and c <= '9') return @intCast(c - '0');
        if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
        if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
        return error.BadString;
    }

    fn parseUnicodeEscape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        const wide = p.peek() == 'U';
        const digits: usize = if (wide) 8 else 4;
        p.pos += 1;
        if (p.pos + digits > p.text.len) return error.BadString;
        var cp: u21 = 0;
        for (0..digits) |_| {
            cp = cp * 16 + try hexVal(p.text[p.pos]);
            p.pos += 1;
        }
        // Combine surrogate pairs the way TOML requires.
        if (cp >= 0xd800 and cp <= 0xdbff and !wide) {
            if (p.pos + 6 > p.text.len or p.text[p.pos] != '\\' or (p.text[p.pos + 1] != 'u' and p.text[p.pos + 1] != 'U')) return error.BadString;
            const w2 = p.text[p.pos + 1] == 'U';
            const d2: usize = if (w2) 8 else 4;
            if (p.pos + 2 + d2 > p.text.len) return error.BadString;
            p.pos += 2;
            var lo: u21 = 0;
            for (0..d2) |_| {
                lo = lo * 16 + try hexVal(p.text[p.pos]);
                p.pos += 1;
            }
            if (lo < 0xdc00 or lo > 0xdfff) return error.BadString;
            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        } else if (cp >= 0xd800 and cp <= 0xdfff) {
            return error.BadString;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadString;
        try out.appendSlice(p.backing, buf[0..n]);
    }

    fn parseNumber(p: *Parser) Error!Value {
        const start = p.pos;
        if (p.peek() == '+' or p.peek() == '-') p.pos += 1;
        // inf/nan (signed or bare).
        for ([_][]const u8{ "inf", "nan" }) |word| {
            if (p.pos + word.len <= p.text.len and std.ascii.eqlIgnoreCase(p.text[p.pos..][0..word.len], word)) {
                p.pos += word.len;
                try p.checkNumberDelim();
                const neg = p.text[start] == '-';
                if (word[0] == 'i') return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
                return .{ .float = std.math.nan(f64) };
            }
        }
        var base: u8 = 10;
        if (p.pos + 2 <= p.text.len and p.text[p.pos] == '0') {
            switch (p.text[p.pos + 1]) {
                'x' => base = 16,
                'o' => base = 8,
                'b' => base = 2,
                else => {},
            }
            if (base != 10) p.pos += 2;
        }
        const digits_start = p.pos;
        while (!p.eof()) {
            const c = p.peek();
            const ok = switch (base) {
                16 => std.ascii.isHex(c) or c == '_',
                10 => std.ascii.isDigit(c) or c == '_',
                8 => (c >= '0' and c <= '7') or c == '_',
                else => (c == '0' or c == '1') or c == '_',
            };
            if (!ok) break;
            p.pos += 1;
        }
        if (p.pos == digits_start) return error.BadNumber;
        var is_float = false;
        if (base == 10 and !p.eof() and p.peek() == '.') {
            // A `.` only starts a float with a digit after it.
            if (p.pos + 1 < p.text.len and std.ascii.isDigit(p.text[p.pos + 1])) {
                is_float = true;
                p.pos += 1;
                while (!p.eof() and (std.ascii.isDigit(p.peek()) or p.peek() == '_')) p.pos += 1;
            }
        }
        if (base == 10 and !p.eof() and (p.peek() == 'e' or p.peek() == 'E')) {
            var j = p.pos + 1;
            if (j < p.text.len and (p.text[j] == '+' or p.text[j] == '-')) j += 1;
            if (j < p.text.len and std.ascii.isDigit(p.text[j])) {
                is_float = true;
                p.pos = j + 1;
                while (!p.eof() and (std.ascii.isDigit(p.peek()) or p.peek() == '_')) p.pos += 1;
            }
        }
        if (base != 10 and (is_float or (!p.eof() and (p.peek() == '.' or p.peek() == 'e' or p.peek() == 'E')))) return error.BadNumber;
        try p.checkNumberDelim();
        // Copy without underscores (parseInt/parseFloat reject them).
        var buf: [128]u8 = undefined;
        if (p.pos - start >= buf.len) return error.BadNumber;
        var n: usize = 0;
        for (p.text[start..p.pos]) |c| {
            if (c == '_') continue;
            buf[n] = c;
            n += 1;
        }
        const digits = buf[0..n];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, digits) catch return error.BadNumber;
            return .{ .float = f };
        }
        var d = digits;
        if (d.len > 0 and d[0] == '+') d = d[1..];
        if (base == 10) {
            const v = std.fmt.parseInt(i64, d, 10) catch return error.BadNumber;
            return .{ .int = v };
        }
        // Strip sign + 0x/0o/0b prefix: parseInt takes no prefix.
        var neg = false;
        var dd = d;
        if (dd.len > 0 and (dd[0] == '-' or dd[0] == '+')) {
            neg = dd[0] == '-';
            dd = dd[1..];
        }
        if (dd.len < 3 or dd[0] != '0') return error.BadNumber;
        dd = dd[2..];
        if (dd.len == 0) return error.BadNumber;
        const mag = std.fmt.parseInt(u64, dd, base) catch return error.BadNumber;
        if (!neg and mag > 0x7fff_ffff_ffff_ffff) return error.BadNumber;
        if (neg and mag > 0x8000_0000_0000_0000) return error.BadNumber;
        if (mag == 0x8000_0000_0000_0000) return .{ .int = std.math.minInt(i64) };
        const v: i64 = if (neg) -@as(i64, @intCast(mag)) else @intCast(mag);
        return .{ .int = v };
    }

    /// A number must end at a value boundary (`123abc` and `0x` are errors).
    fn checkNumberDelim(p: *Parser) Error!void {
        if (p.eof()) return;
        const c = p.peek();
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '+' or c == '-') return error.BadSyntax;
    }

    fn parseArray(p: *Parser) Error![]Value {
        p.pos += 1; // '['
        var out = std.ArrayList(Value).empty;
        errdefer out.deinit(p.backing);
        while (true) {
            p.skipWsAll();
            if (p.eof()) return error.BadSyntax;
            if (p.peek() == ']') {
                p.pos += 1;
                return out.toOwnedSlice(p.backing);
            }
            const v = try p.parseValue();
            try out.append(p.backing, v);
            p.skipWsAll();
            if (p.eof()) return error.BadSyntax;
            if (p.peek() == ',') {
                p.pos += 1;
                continue;
            }
            if (p.peek() == ']') {
                p.pos += 1;
                return out.toOwnedSlice(p.backing);
            }
            return error.BadSyntax;
        }
    }

    fn parseInlineTable(p: *Parser) Error![]Entry {
        p.pos += 1; // '{'
        var out = std.ArrayList(Entry).empty;
        errdefer out.deinit(p.backing);
        while (true) {
            p.skipWsAll();
            if (p.eof()) return error.BadSyntax;
            if (p.peek() == '}') {
                p.pos += 1;
                return out.toOwnedSlice(p.backing);
            }
            const key = try p.parseKey();
            p.skipWsAll();
            if (p.eof() or p.peek() != '=') return error.BadSyntax;
            p.pos += 1;
            p.skipWsAll();
            const v = try p.parseValue();
            p.skipWsAll();
            if (get(out.items, key) != null) return error.DuplicateKey;
            try out.append(p.backing, .{ .key = key, .value = v });
            if (p.eof()) return error.BadSyntax;
            if (p.peek() == ',') {
                p.pos += 1;
                continue;
            }
            if (p.peek() == '}') {
                p.pos += 1;
                return out.toOwnedSlice(p.backing);
            }
            return error.BadSyntax;
        }
    }
};

test "toml: sections, scalars, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\# leading comment
        \\[server] # trailing comment
        \\port = 25566 # inline comment
        \\motd = "hello \"quoted\" \u00e9"
        \\lit = 'C:\path\no-escape'
        \\online = true
        \\off = false
        \\neg = -7
        \\hex = 0xFF
        \\big = 1_000_000
        \\ratio = 1.5
        \\exp = 1e3
        \\[world]
        \\seed = 42
        \\
    );
    const srv = get(root, "server").?.table;
    try std.testing.expectEqual(@as(i64, 25566), get(srv, "port").?.int);
    try std.testing.expectEqualStrings("hello \"quoted\" é", get(srv, "motd").?.string);
    try std.testing.expectEqualStrings("C:\\path\\no-escape", get(srv, "lit").?.string);
    try std.testing.expectEqual(true, get(srv, "online").?.boolean);
    try std.testing.expectEqual(false, get(srv, "off").?.boolean);
    try std.testing.expectEqual(@as(i64, -7), get(srv, "neg").?.int);
    try std.testing.expectEqual(@as(i64, 255), get(srv, "hex").?.int);
    try std.testing.expectEqual(@as(i64, 1000000), get(srv, "big").?.int);
    try std.testing.expectEqual(@as(f64, 1.5), get(srv, "ratio").?.float);
    try std.testing.expectEqual(@as(f64, 1000.0), get(srv, "exp").?.float);
    try std.testing.expectEqual(@as(i64, 42), get(get(root, "world").?.table, "seed").?.int);
}

test "toml: arrays and inline tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\[server]
        \\ops = ["alice", # comment inside arrays
        \\  "bob",
        \\]
        \\empty = []
        \\[world]
        \\gamerules = { keepInventory = true, doMobSpawning = false }
        \\
    );
    const ops = get(get(root, "server").?.table, "ops").?.array;
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqualStrings("alice", ops[0].string);
    try std.testing.expectEqualStrings("bob", ops[1].string);
    try std.testing.expectEqual(@as(usize, 0), get(get(root, "server").?.table, "empty").?.array.len);
    const gr = get(get(root, "world").?.table, "gamerules").?.table;
    try std.testing.expectEqual(true, get(gr, "keepInventory").?.boolean);
    try std.testing.expectEqual(false, get(gr, "doMobSpawning").?.boolean);
}

test "toml: malformed inputs fail distinctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unterminated string / bad escape / raw newline.
    try std.testing.expectError(error.BadString, parse(a, "[s]\nk = \"abc"));
    try std.testing.expectError(error.BadString, parse(a, "[s]\nk = \"a\\qb\""));
    try std.testing.expectError(error.BadString, parse(a, "[s]\nk = \"a\nb\""));
    // Bad numbers and values.
    try std.testing.expectError(error.BadNumber, parse(a, "[s]\nk = 0x"));
    try std.testing.expectError(error.BadNumber, parse(a, "[s]\nk = 99999999999999999999999"));
    try std.testing.expectError(error.BadSyntax, parse(a, "[s]\nk = 123abc"));
    try std.testing.expectError(error.BadValue, parse(a, "[s]\nk = tru"));
    try std.testing.expectError(error.BadValue, parse(a, "[s]\nk ="));
    try std.testing.expectError(error.BadSyntax, parse(a, "[s]\nk = 1\nstray"));
    // Duplicates and unsupported constructs.
    try std.testing.expectError(error.DuplicateKey, parse(a, "[s]\nk = 1\nk = 2"));
    try std.testing.expectError(error.DuplicateTable, parse(a, "[s]\n[s]"));
    try std.testing.expectError(error.Unsupported, parse(a, "[[s]]"));
    try std.testing.expectError(error.Unsupported, parse(a, "[s]\na.b = 1"));
    try std.testing.expectError(error.BadSyntax, parse(a, "[s"));
    try std.testing.expectError(error.BadSyntax, parse(a, "[s]\nk 1"));
}
