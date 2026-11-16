//! The JSON the guard reads and writes, with the two string encodings the
//! Python guard used:
//! - cache: json.dumps(ensure_ascii=True) of text decoded with
//!   surrogateescape, so a byte that is not UTF-8 is a lone \udcXX;
//! - wire: the restore helper's request and reply, one character per byte
//!   (latin-1), so every byte is \u00XX or itself.
//! Strings are kept as their raw JSON text until a codec decodes them.
const std = @import("std");
const text = @import("pytext.zig");

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    bool: bool,
    /// The number's JSON text.
    number: []const u8,
    /// The string's JSON text between the quotes, escapes not yet decoded.
    string: []const u8,
    array: []const Value,
    /// Members in order; a later duplicate key wins, as json.loads keeps it.
    object: []const Member,

    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .object) return null;
        var found: ?Value = null;
        for (v.object) |m| {
            if (keyEql(m.key, key)) found = m.value;
        }
        return found;
    }
};

pub const Member = struct { key: []const u8, value: Value };

/// A raw JSON key equals `want` (ASCII, as every key the guard looks up
/// is) once its escapes are decoded.
fn keyEql(raw: []const u8, want: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len) {
        var c: u21 = raw[i];
        if (c == '\\') {
            if (i + 1 >= raw.len) return false;
            const e = raw[i + 1];
            if (e == 'u') {
                c = hex4(raw, i + 2) catch return false;
                i += 6;
            } else {
                c = switch (e) {
                    'b' => 0x08,
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => e,
                };
                i += 2;
            }
        } else i += 1;
        if (j >= want.len or c != want[j]) return false;
        j += 1;
    }
    return j == want.len;
}

fn isHex(s: []const u8) bool {
    if (s.len != 4) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The four hex digits of a \u escape at `raw[i..]`; parseInt alone would
/// also take a sign.
fn hex4(raw: []const u8, i: usize) error{Encoding}!u16 {
    if (i + 4 > raw.len or !isHex(raw[i .. i + 4])) return error.Encoding;
    return std.fmt.parseInt(u16, raw[i .. i + 4], 16) catch unreachable;
}

pub const ParseError = Allocator.Error || error{Syntax};

const max_depth = 32;

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    arena: Allocator,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    fn lit(p: *Parser, l: []const u8) bool {
        if (std.mem.startsWith(u8, p.s[p.i..], l)) {
            p.i += l.len;
            return true;
        }
        return false;
    }

    fn value(p: *Parser, depth: usize) ParseError!Value {
        if (depth > max_depth) return error.Syntax;
        p.ws();
        if (p.i >= p.s.len) return error.Syntax;
        switch (p.s[p.i]) {
            'n' => return if (p.lit("null")) .null else error.Syntax,
            't' => return if (p.lit("true")) .{ .bool = true } else error.Syntax,
            'f' => return if (p.lit("false")) .{ .bool = false } else error.Syntax,
            '"' => return .{ .string = try p.string() },
            '[' => {
                p.i += 1;
                var items: std.ArrayList(Value) = .empty;
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == ']') {
                    p.i += 1;
                    return .{ .array = &.{} };
                }
                while (true) {
                    try items.append(p.arena, try p.value(depth + 1));
                    p.ws();
                    if (p.i >= p.s.len) return error.Syntax;
                    if (p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.s[p.i] == ']') {
                        p.i += 1;
                        return .{ .array = items.items };
                    }
                    return error.Syntax;
                }
            },
            '{' => {
                p.i += 1;
                var members: std.ArrayList(Member) = .empty;
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == '}') {
                    p.i += 1;
                    return .{ .object = &.{} };
                }
                while (true) {
                    p.ws();
                    if (p.i >= p.s.len or p.s[p.i] != '"') return error.Syntax;
                    const key = try p.string();
                    p.ws();
                    if (p.i >= p.s.len or p.s[p.i] != ':') return error.Syntax;
                    p.i += 1;
                    const v = try p.value(depth + 1);
                    try members.append(p.arena, .{ .key = key, .value = v });
                    p.ws();
                    if (p.i >= p.s.len) return error.Syntax;
                    if (p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.s[p.i] == '}') {
                        p.i += 1;
                        return .{ .object = members.items };
                    }
                    return error.Syntax;
                }
            },
            '-', '0'...'9' => {
                const start = p.i;
                if (p.s[p.i] == '-') p.i += 1;
                const digits = p.i;
                while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
                if (p.i == digits) return error.Syntax;
                // JSON has no leading zeros: 0 alone, or 1-9 then digits.
                if (p.s[digits] == '0' and p.i - digits > 1) return error.Syntax;
                if (p.i < p.s.len and p.s[p.i] == '.') {
                    p.i += 1;
                    const f = p.i;
                    while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
                    if (p.i == f) return error.Syntax;
                }
                if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
                    p.i += 1;
                    if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
                    const e = p.i;
                    while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
                    if (p.i == e) return error.Syntax;
                }
                return .{ .number = p.s[start..p.i] };
            },
            else => return error.Syntax,
        }
    }

    /// The raw text of a string; escapes are checked for shape here.
    fn string(p: *Parser) ParseError![]const u8 {
        p.i += 1;
        const start = p.i;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '"') {
                const raw = p.s[start..p.i];
                p.i += 1;
                return raw;
            }
            if (c < 0x20) return error.Syntax;
            if (c == '\\') {
                if (p.i + 1 >= p.s.len) return error.Syntax;
                switch (p.s[p.i + 1]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => p.i += 2,
                    'u' => {
                        if (p.i + 6 > p.s.len) return error.Syntax;
                        if (!isHex(p.s[p.i + 2 .. p.i + 6])) return error.Syntax;
                        p.i += 6;
                    },
                    else => return error.Syntax,
                }
                continue;
            }
            p.i += 1;
        }
        return error.Syntax;
    }
};

/// Parse one JSON document; all memory comes from `arena`.
pub fn parse(arena: Allocator, s: []const u8) ParseError!Value {
    var p: Parser = .{ .s = s, .arena = arena };
    const v = try p.value(0);
    p.ws();
    if (p.i != s.len) return error.Syntax;
    return v;
}

pub const DecodeError = Allocator.Error || error{Encoding};

/// Code points of a raw JSON string, surrogate pairs joined; a lone
/// surrogate is returned as itself. An escape json.loads refuses (cut off,
/// unknown, or \u without four hex digits) is an error.
fn codePoints(arena: Allocator, raw: []const u8) DecodeError![]u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '\\') {
            const ch = text.nextChar(raw[i..]);
            const cp = ch.cp orelse return error.Encoding; // json.loads takes text
            try out.append(arena, cp);
            i += ch.len;
            continue;
        }
        if (i + 1 >= raw.len) return error.Encoding;
        const e = raw[i + 1];
        i += 2;
        const simple: ?u21 = switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => null,
            else => return error.Encoding,
        };
        if (simple) |s| {
            try out.append(arena, s);
            continue;
        }
        var cp: u21 = try hex4(raw, i);
        i += 4;
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
            const lo = try hex4(raw, i + 2);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 6;
            }
        }
        try out.append(arena, cp);
    }
    return out.toOwnedSlice(arena);
}

/// Cache text: code points as UTF-8, a lone surrogate U+DC80..U+DCFF as the
/// byte it escapes; any other lone surrogate cannot be written to the
/// environment and is an error.
pub fn decodeCache(arena: Allocator, raw: []const u8) DecodeError![]u8 {
    const cps = try codePoints(arena, raw);
    defer arena.free(cps);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (cps) |cp| {
        if (cp >= 0xDC80 and cp <= 0xDCFF) {
            try out.append(arena, @intCast(cp - 0xDC00));
        } else if (cp >= 0xD800 and cp <= 0xDFFF) {
            return error.Encoding;
        } else {
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &b) catch return error.Encoding;
            try out.appendSlice(arena, b[0..n]);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Wire text: every code point must be at most U+00FF and is one byte.
pub fn decodeWire(arena: Allocator, raw: []const u8) DecodeError![]u8 {
    const cps = try codePoints(arena, raw);
    defer arena.free(cps);
    const out = try arena.alloc(u8, cps.len);
    errdefer arena.free(out);
    for (cps, 0..) |cp, i| {
        if (cp > 0xFF) return error.Encoding;
        out[i] = @intCast(cp);
    }
    return out;
}

fn escapeCp(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) Allocator.Error!void {
    switch (cp) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x08 => try out.appendSlice(gpa, "\\b"),
        0x0c => try out.appendSlice(gpa, "\\f"),
        ' '...'!', '#'...'[', ']'...'~' => try out.append(gpa, @intCast(cp)),
        else => {
            var b: [12]u8 = undefined;
            if (cp >= 0x10000) {
                const v = cp - 0x10000;
                const s = std.mem.print(&b, "\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) }) catch unreachable;
                try out.appendSlice(gpa, s);
            } else {
                const s = std.mem.print(&b, "\\u{x:0>4}", .{cp}) catch unreachable;
                try out.appendSlice(gpa, s);
            }
        },
    }
}

/// A JSON string of `bytes` as the Python guard wrote cache text.
pub fn writeCacheString(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < bytes.len) {
        const ch = text.nextChar(bytes[i..]);
        if (ch.cp) |cp| try escapeCp(out, gpa, cp) else try escapeCp(out, gpa, 0xDC00 + @as(u21, bytes[i]));
        i += ch.len;
    }
    try out.append(gpa, '"');
}

/// A JSON string of `bytes` as wire text: one code point per byte.
pub fn writeWireString(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (bytes) |b| try escapeCp(out, gpa, b);
    try out.append(gpa, '"');
}

test "cache strings round-trip bytes that are not UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeCacheString(&out, a, "a\"\xff\u{e9}\u{1F600}\n\x7f");
    try std.testing.expectEqualStrings("\"a\\\"\\udcff\\u00e9\\ud83d\\ude00\\n\\u007f\"", out.items);
    const v = try parse(a, out.items);
    try std.testing.expectEqualStrings("a\"\xff\u{e9}\u{1F600}\n\x7f", try decodeCache(a, v.string));
    try std.testing.expectError(error.Encoding, decodeCache(a, "\\ud800"));
    // A truncated escape is an encoding error. It must not panic, and the
    // bytes allocated before the error are freed when the caller did not
    // pass an arena.
    try std.testing.expectError(error.Encoding, decodeCache(std.testing.allocator, "a\\"));
    try std.testing.expectError(error.Encoding, decodeCache(std.testing.allocator, "\\u12"));
    const broken: Value = .{ .object = &.{.{ .key = "\\", .value = .null }} };
    try std.testing.expect(broken.get("x") == null);
}

test "wire strings are one byte per code point" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeWireString(&out, a, "x\xff\xc3\xa9");
    try std.testing.expectEqualStrings("\"x\\u00ff\\u00c3\\u00a9\"", out.items);
    const v = try parse(a, out.items);
    try std.testing.expectEqualStrings("x\xff\xc3\xa9", try decodeWire(a, v.string));
    try std.testing.expectError(error.Encoding, decodeWire(a, "\\u0100"));
}

test "a truncated or malformed escape is an encoding error" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "abc\\", "\\u12", "\\ud83d\\ude0", "\\u+123", "\\x0041" }) |raw| {
        try std.testing.expectError(error.Encoding, decodeCache(gpa, raw));
        try std.testing.expectError(error.Encoding, decodeWire(gpa, raw));
    }
    const obj: Value = .{ .object = &.{.{ .key = "a\\", .value = .null }} };
    try std.testing.expect(obj.get("a") == null);
}

test "parse objects, duplicates and nesting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try parse(a, " {\"v\": 1, \"k\": [true, null, -1.5e3], \"v\": 2} ");
    try std.testing.expectEqualStrings("2", v.get("v").?.number);
    try std.testing.expectEqual(@as(usize, 3), v.get("k").?.array.len);
    try std.testing.expectError(error.Syntax, parse(a, "{\"a\":1,}"));
    try std.testing.expectError(error.Syntax, parse(a, "{\"v\":01}"));
    try std.testing.expectError(error.Syntax, parse(a, "\"\\u+123\""));
    const e = try parse(a, "{\"\\u006bind\": \"x\"}");
    try std.testing.expect(e.get("kind") != null);
    try std.testing.expectError(error.Syntax, parse(a, "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]"));
}

// ---- Python values and json.dumps -----------------------------------------

/// A value as a Python program built it for json.dumps. Strings are byte
/// strings meant as Python text (surrogateescape for invalid bytes).
pub const Py = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    list: []const Py,
    dict: []const Entry,

    pub const Entry = struct { key: []const u8, value: Py };

    pub fn s(v: []const u8) Py {
        return .{ .str = v };
    }

    pub fn opt(v: ?[]const u8) Py {
        return if (v) |x| .{ .str = x } else .null;
    }
};

/// The parsed document as Python values, strings decoded as cache text.
pub fn toPy(arena: Allocator, v: Value) DecodeError!Py {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .number => |n| if (std.fmt.parseInt(i64, n, 10)) |i| .{ .int = i } else |_| .{ .float = std.fmt.parseFloat(f64, n) catch return error.Encoding },
        .string => |raw| .{ .str = try decodeCache(arena, raw) },
        .array => |items| blk: {
            const out = try arena.alloc(Py, items.len);
            for (items, 0..) |it, i| out[i] = try toPy(arena, it);
            break :blk .{ .list = out };
        },
        .object => |members| blk: {
            // A later duplicate key replaces the earlier one, in its place.
            var m: std.StringArrayHashMapUnmanaged(Py) = .empty;
            for (members) |mem| try m.put(arena, try decodeCache(arena, mem.key), try toPy(arena, mem.value));
            const out = try arena.alloc(Py.Entry, m.count());
            for (m.keys(), m.values(), 0..) |k, val, i| out[i] = .{ .key = k, .value = val };
            break :blk .{ .dict = out };
        },
    };
}

fn lessKey(_: void, a: Py.Entry, b: Py.Entry) bool {
    return pyTextLess(a.key, b.key);
}

/// Python str ordering: by code point; an invalid byte is U+DC80..U+DCFF.
pub fn pyTextLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = text.nextChar(a[i..]);
        const cb = text.nextChar(b[j..]);
        const pa: u21 = ca.cp orelse 0xDC00 + @as(u21, a[i]);
        const pb: u21 = cb.cp orelse 0xDC00 + @as(u21, b[j]);
        if (pa != pb) return pa < pb;
        i += ca.len;
        j += cb.len;
    }
    return a.len - i < b.len - j and i >= a.len;
}

/// repr(float): the shortest digits that round-trip; positional when the
/// decimal exponent is in [-4, 16), else d.ddde+XX with at least two
/// exponent digits.
fn writeFloat(out: *std.ArrayList(u8), gpa: Allocator, f: f64) Allocator.Error!void {
    if (std.math.isNan(f)) return out.appendSlice(gpa, "NaN");
    if (std.math.isInf(f)) return out.appendSlice(gpa, if (f > 0) "Infinity" else "-Infinity");
    var buf: [64]u8 = undefined;
    const sci = std.mem.print(&buf, "{e}", .{f}) catch unreachable;
    // sci is [-]D[.DDD]e[-]X
    const e_at = std.mem.findScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch 0;
    const neg = sci[0] == '-';
    const mant = sci[@intFromBool(neg)..e_at];
    var digits: [32]u8 = undefined;
    var nd: usize = 0;
    for (mant) |c| if (c != '.') {
        digits[nd] = c;
        nd += 1;
    };
    if (neg) try out.append(gpa, '-');
    if (exp >= -4 and exp < 16) {
        if (exp < 0) {
            try out.appendSlice(gpa, "0.");
            try out.appendNTimes(gpa, '0', @intCast(-exp - 1));
            try out.appendSlice(gpa, digits[0..nd]);
        } else {
            const int_len: usize = @intCast(exp + 1);
            if (nd <= int_len) {
                try out.appendSlice(gpa, digits[0..nd]);
                try out.appendNTimes(gpa, '0', int_len - nd);
                try out.appendSlice(gpa, ".0");
            } else {
                try out.appendSlice(gpa, digits[0..int_len]);
                try out.append(gpa, '.');
                try out.appendSlice(gpa, digits[int_len..nd]);
            }
        }
    } else {
        try out.append(gpa, digits[0]);
        if (nd > 1) {
            try out.append(gpa, '.');
            try out.appendSlice(gpa, digits[1..nd]);
        }
        var eb: [8]u8 = undefined;
        const es = std.mem.print(&eb, "e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch unreachable;
        try out.appendSlice(gpa, es);
    }
}

test "writeFloat is Python's repr" {
    const cases = [_]struct { f: f64, s: []const u8 }{
        .{ .f = 2.0, .s = "2.0" },
        .{ .f = 0.5, .s = "0.5" },
        .{ .f = 1794549600.123456, .s = "1794549600.123456" },
        .{ .f = 1e16, .s = "1e+16" },
        .{ .f = 1.5e-5, .s = "1.5e-05" },
        .{ .f = 0.0001, .s = "0.0001" },
        .{ .f = 123456789012345.6, .s = "123456789012345.6" },
        .{ .f = -0.25, .s = "-0.25" },
        .{ .f = 1e100, .s = "1e+100" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try writeFloat(&out, std.testing.allocator, c.f);
        try std.testing.expectEqualStrings(c.s, out.items);
    }
}

fn dumpsInner(out: *std.ArrayList(u8), gpa: Allocator, v: Py, indent: usize, level: usize, sort: bool) Allocator.Error!void {
    switch (v) {
        .null => try out.appendSlice(gpa, "null"),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .int => |i| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(gpa, std.mem.print(&buf, "{d}", .{i}) catch unreachable);
        },
        .float => |f| try writeFloat(out, gpa, f),
        .str => |s| try writeCacheString(out, gpa, s),
        .list => |items| {
            if (items.len == 0) return out.appendSlice(gpa, "[]");
            try out.append(gpa, '[');
            for (items, 0..) |it, i| {
                if (i > 0) try out.append(gpa, ',');
                try newline(out, gpa, indent, level + 1);
                try dumpsInner(out, gpa, it, indent, level + 1, sort);
            }
            try newline(out, gpa, indent, level);
            try out.append(gpa, ']');
        },
        .dict => |entries| {
            if (entries.len == 0) return out.appendSlice(gpa, "{}");
            const sorted = try gpa.dupe(Py.Entry, entries);
            defer gpa.free(sorted);
            if (sort) std.mem.sort(Py.Entry, sorted, {}, lessKey);
            try out.append(gpa, '{');
            for (sorted, 0..) |e, i| {
                if (i > 0) try out.append(gpa, ',');
                try newline(out, gpa, indent, level + 1);
                try writeCacheString(out, gpa, e.key);
                try out.appendSlice(gpa, ": ");
                try dumpsInner(out, gpa, e.value, indent, level + 1, sort);
            }
            try newline(out, gpa, indent, level);
            try out.append(gpa, '}');
        },
    }
}

fn newline(out: *std.ArrayList(u8), gpa: Allocator, indent: usize, level: usize) Allocator.Error!void {
    try out.append(gpa, '\n');
    try out.appendNTimes(gpa, ' ', indent * level);
}

/// json.dumps(v, indent=indent, sort_keys=sort), ensure_ascii as Python's
/// default.
pub fn dumps(gpa: Allocator, v: Py, indent: usize, sort: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try dumpsInner(&out, gpa, v, indent, 0, sort);
    return out.toOwnedSlice(gpa);
}

test "dumps matches json.dumps(indent=2, sort_keys=True)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v: Py = .{ .dict = &.{
        .{ .key = "b", .value = .{ .list = &.{ .{ .int = 1 }, .null, .{ .bool = true } } } },
        .{ .key = "a", .value = .{ .str = "\u{e9}\xff" } },
        .{ .key = "c", .value = .{ .dict = &.{} } },
        .{ .key = "d", .value = .{ .list = &.{} } },
        .{ .key = "e", .value = .{ .float = 2.0 } },
    } };
    const s = try dumps(a, v, 2, true);
    try std.testing.expectEqualStrings(
        "{\n  \"a\": \"\\u00e9\\udcff\",\n  \"b\": [\n    1,\n    null,\n    true\n  ],\n  \"c\": {},\n  \"d\": [],\n  \"e\": 2.0\n}",
        s,
    );
    const parsed = try toPy(a, try parse(a, s));
    try std.testing.expectEqualStrings(s, try dumps(a, parsed, 2, true));
}
