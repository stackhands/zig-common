//! Python's view of byte strings: text decoded from UTF-8 with
//! surrogateescape (an invalid byte is one character), the 'replace'
//! decoder, str.isspace/strip/split, and shlex.quote. Tools ported from
//! Python use these so a byte string means what it meant there.
const std = @import("std");

const Allocator = std.mem.Allocator;

fn isAlnumU(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// One character of a byte string, as `nextChar` reads it.
pub const Char = struct {
    /// The code point, or null for a byte that is not part of valid UTF-8.
    cp: ?u21,
    /// Its length in bytes: 1 to 4, and 1 when `cp` is null.
    len: u3,
};

/// The next character of `s` as CPython's UTF-8 decoder sees it: a valid
/// sequence, or an invalid byte run (the maximal subpart of a sequence,
/// returned one byte at a time, as surrogateescape replaces it).
pub fn nextChar(s: []const u8) Char {
    const c0 = s[0];
    if (c0 < 0x80) return .{ .cp = c0, .len = 1 };
    const n: u3 = std.unicode.utf8ByteSequenceLength(c0) catch return .{ .cp = null, .len = 1 };
    if (s.len < n) return .{ .cp = null, .len = 1 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = null, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Length of the maximal subpart of an ill-formed sequence at `s` (Unicode
/// "best practice", which CPython's 'replace' handler follows): the bytes
/// that one U+FFFD stands for.
fn maximalSubpart(s: []const u8) usize {
    const c0 = s[0];
    var need: usize = 0;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    switch (c0) {
        0xC2...0xDF => need = 1,
        0xE0 => {
            need = 2;
            lo = 0xA0;
        },
        0xE1...0xEC, 0xEE...0xEF => need = 2,
        0xED => {
            need = 2;
            hi = 0x9F;
        },
        0xF0 => {
            need = 3;
            lo = 0x90;
        },
        0xF1...0xF3 => need = 3,
        0xF4 => {
            need = 3;
            hi = 0x8F;
        },
        else => return 1,
    }
    var i: usize = 1;
    while (i <= need and i < s.len) : (i += 1) {
        const b = s[i];
        const l: u8 = if (i == 1) lo else 0x80;
        const h: u8 = if (i == 1) hi else 0xBF;
        if (b < l or b > h) break;
    }
    return i;
}

/// bytes.decode("utf-8", "replace"): each maximal ill-formed subpart becomes
/// one U+FFFD.
pub fn decodeReplace(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const ch = nextChar(s[i..]);
        if (ch.cp != null) {
            try out.appendSlice(gpa, s[i .. i + ch.len]);
            i += ch.len;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += maximalSubpart(s[i..]);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// str.isspace for the characters str.strip() removes.
pub fn pyWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r', 0x1c...0x1f, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// str.strip(): `s` without leading and trailing Unicode whitespace.
pub fn pyStrip(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len) {
        const ch = nextChar(s[a..]);
        const cp = ch.cp orelse break;
        if (!pyWhitespace(cp)) break;
        a += ch.len;
    }
    var b: usize = a;
    var i: usize = a;
    while (i < s.len) {
        const ch = nextChar(s[i..]);
        i += ch.len;
        const ws = if (ch.cp) |cp| pyWhitespace(cp) else false;
        if (!ws) b = i;
    }
    return s[a..b];
}

/// str.split() with no separator: the runs between Unicode whitespace.
pub fn pySplit(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    var start: ?usize = null;
    while (i < s.len) {
        const ch = nextChar(s[i..]);
        const ws = if (ch.cp) |cp| pyWhitespace(cp) else false;
        if (ws) {
            if (start) |st| try out.append(arena, s[st..i]);
            start = null;
        } else if (start == null) start = i;
        i += ch.len;
    }
    if (start) |st| try out.append(arena, s[st..]);
    return try out.toOwnedSlice(arena);
}

/// shlex.quote: unchanged when every byte is in [A-Za-z0-9_@%+=:,./-] and
/// the value is not empty; otherwise single-quoted with ' written as '"'"'.
pub fn shellQuote(gpa: Allocator, v: []const u8) Allocator.Error![]u8 {
    if (v.len == 0) return gpa.dupe(u8, "''");
    const safe = for (v) |c| {
        if (!(isAlnumU(c) or std.mem.findScalar(u8, "@%+=:,./-", c) != null)) break false;
    } else true;
    if (safe) return gpa.dupe(u8, v);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (v) |c| {
        if (c == '\'') try out.appendSlice(gpa, "'\"'\"'") else try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

test "decodeReplace uses maximal subparts" {
    const gpa = std.testing.allocator;
    const r = try decodeReplace(gpa, "a\xe2\x82b\xff\xf0\x9f\x98");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}\u{FFFD}", r);
}

test "pyStrip and pySplit use Unicode whitespace" {
    try std.testing.expectEqualStrings("a b", pyStrip("\u{3000} a b\u{a0}\n"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parts = try pySplit(arena_state.allocator(), "avx\u{a0}waitpkg  x\xff");
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("waitpkg", parts[1]);
}

fn splitOwned(a: std.mem.Allocator) !void {
    const parts = try pySplit(a, "a b c");
    defer a.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
}

test "pySplit frees its list when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, splitOwned, .{});
}

test "shellQuote" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "", "''" },
        .{ "/a:b", "/a:b" },
        .{ "a b", "'a b'" },
        .{ "it's", "'it'\"'\"'s'" },
        .{ "\xe9", "'\xe9'" },
    };
    for (cases) |cs| {
        const q = try shellQuote(gpa, cs[0]);
        defer gpa.free(q);
        try std.testing.expectEqualStrings(cs[1], q);
    }
}
