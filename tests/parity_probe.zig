//! The parity probe: writes this library's JSON and pytext output for a
//! deterministic case set, one case per line with three tab-separated
//! fields, the kind, the hex input and the hex output. The Python test
//! beside this file recomputes every output with the Python call the
//! module promises to match and compares byte for byte.
//!
//! The case set covers every byte alone, the invalid UTF-8 classes,
//! boundary code points, a fixed-seed sample of strings and doubles and
//! a fixed set of documents over the dump options. It runs in seconds
//! and commits no corpus: the expected bytes live in Python itself.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");

const json = common.json;
const pytext = common.pytext;
const sys = common.sys;

var arena_state: std.heap.ArenaAllocator = undefined;
var A: std.mem.Allocator = undefined;
var all: std.ArrayList(u8) = .empty;

fn hexOf(bytes: []const u8) []const u8 {
    const out = A.alloc(u8, bytes.len * 2) catch unreachable;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}

fn emit(kind: []const u8, in: []const u8, out: []const u8) void {
    all.print(A, "{s}\t{s}\t{s}\n", .{ kind, hexOf(in), hexOf(out) }) catch unreachable;
}

/// A case whose output is already text, not bytes to hex again: the
/// split kind's output is the parts' hex, spaced.
fn emitText(kind: []const u8, in: []const u8, out: []const u8) void {
    all.print(A, "{s}\t{s}\t{s}\n", .{ kind, hexOf(in), out }) catch unreachable;
}

/// One input through the six byte-string cases.
fn textCases(in: []const u8) void {
    {
        var s: std.ArrayList(u8) = .empty;
        json.writeCacheString(&s, A, in) catch unreachable;
        emit("cache", in, s.items);
    }
    {
        var s: std.ArrayList(u8) = .empty;
        json.writeWireString(&s, A, in) catch unreachable;
        emit("wire", in, s.items);
    }
    emit("quote", in, pytext.shellQuote(A, in) catch unreachable);
    emit("strip", in, pytext.pyStrip(in));
    {
        const parts = pytext.pySplit(A, in) catch unreachable;
        var joined: std.ArrayList(u8) = .empty;
        for (parts, 0..) |p, i| {
            if (i > 0) joined.append(A, ' ') catch unreachable;
            joined.appendSlice(A, hexOf(p)) catch unreachable;
        }
        emitText("split", in, joined.items);
    }
    emit("replace", in, pytext.decodeReplace(A, in) catch unreachable);
}

fn floatCaseBits(bits: u64) void {
    const f: f64 = @bitCast(bits);
    const out = json.dumps(A, .{ .float = f }, 0, false) catch unreachable;
    emit("float", std.mem.asBytes(&bits), out);
}

fn dumpsCase(doc: json.Py, indent: usize, sort: bool) void {
    const out = json.dumps(A, doc, indent, sort) catch unreachable;
    const field = std.fmt.allocPrint(A, "{d},{s}", .{ indent, if (sort) "true" else "false" }) catch unreachable;
    emit("dumps", field, out);
}

fn strerrorCase(code: u16) void {
    const e: linux.E = @fromBackingInt(code);
    emit("strerror", std.mem.asBytes(&code), sys.strerror(e));
}

fn osErrorCase(code: u16, path: []const u8) void {
    const e: linux.E = @fromBackingInt(code);
    const in = A.alloc(u8, 2 + path.len) catch unreachable;
    @memcpy(in[0..2], std.mem.asBytes(&code));
    @memcpy(in[2..], path);
    const out = pytext.osErrorErrno(A, e, path) catch unreachable;
    emit("oserror", in, out);
}

/// A seeded random Py document: dicts and lists over strings with
/// escapes and raw bytes, ints and floats, for the compact fuzz.
fn randomPyDoc(rand: std.Random, depth: usize) json.Py {
    const kind = rand.uintLessThan(usize, if (depth >= 3) 4 else 8);
    switch (kind) {
        0 => return .{ .int = @intCast(rand.int(i64)) },
        1 => return .{ .float = @bitCast(rand.int(u64)) },
        2 => return .{ .str = randomJsonString(rand) },
        3 => return if (rand.boolean()) .null else .{ .bool = rand.boolean() },
        4 => {
            const n = rand.uintLessThan(usize, 4);
            const items = A.alloc(json.Py, n) catch unreachable;
            for (items) |*it| it.* = randomPyDoc(rand, depth + 1);
            return .{ .list = items };
        },
        else => {
            const names = [_][]const u8{ "k", "a", "\xff", "\u{e9}z", "long-key-name" };
            const n = 1 + rand.uintLessThan(usize, 3);
            const entries = A.alloc(json.Py.Entry, n) catch unreachable;
            for (entries) |*e| e.* = .{ .key = names[rand.uintLessThan(usize, names.len)], .value = randomPyDoc(rand, depth + 1) };
            return .{ .dict = entries };
        },
    }
}

fn randomJsonString(rand: std.Random) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var n = rand.uintLessThan(usize, 9);
    while (n > 0) : (n -= 1) {
        switch (rand.uintLessThan(usize, 5)) {
            0 => out.append(A, 'a' + @as(u8, @intCast(rand.uintLessThan(u8, 26)))) catch unreachable,
            1 => out.append(A, 0x80 + @as(u8, @intCast(rand.uintLessThan(u8, 0x80)))) catch unreachable,
            2 => out.appendSlice(A, "\\\"") catch unreachable,
            3 => out.appendSlice(A, "\\ud83d\\ude00") catch unreachable,
            else => out.append(A, '\n') catch unreachable,
        }
    }
    return out.items;
}

fn dumpsCompactCase(doc: json.Py, sort: bool) void {
    const out = json.dumpsCompact(A, doc, sort) catch unreachable;
    emit("dumpscompact", if (sort) "true" else "false", out);
}

/// Named sequences around the UTF-8 validity rules and the characters
/// the escapers treat specially.
const named = [_][]const u8{
    "a\xe2\x82b\xff\xf0\x9f\x98",
    "\xf0\x9f\x98",
    "\xe2\x82",
    "\xc2",
    "\xe1\x80",
    "\xf1\x80",
    "\xc0\x80",
    "\xc1\xbf",
    "\xe0\x80\x80",
    "\xe0\x9f\xbf",
    "\xf0\x80\x80\x80",
    "\xf0\x8f\xbf\xbf",
    "\xed\xa0\x80",
    "\xed\xbf\xbf",
    "\xed\x9f\xbf",
    "\xee\x80\x80",
    "\xef\xbf\xbf",
    "\xf4\x8f\xbf\xbf",
    "\xf4\x90\x80\x80",
    "\xf5\x80\x80\x80",
    "\xf7\xbf\xbf\xbf",
    "\xf8\x88\x80\x80\x80",
    "\xfc\x84\x80\x80\x80\x80",
    "\xfd\xbf\xbf\xbf\xbf",
    "\xfe\xbf\xbf\xbf\xbf\xbf",
    "\xff\xfe",
    "caf\xc3\xa9",
    "caf\xe9",
    "\xe2\x80\xa8",
    "\xe2\x80\xa9",
    "\xc2\xa0",
    "\xc2\xad",
    "x\x80y",
    "a\xc3",
    "a\xc3\xa9",
    "\"\\\x08\x0c\n\r\t/",
    "a/b",
    "it's",
    "EESSI/2026.06",
    "owned space",
};

/// Code points at the boundaries the escapers and sorters care about.
const boundary_cps = [_]u21{
    0x1c,    0x1f,    0x20,     0x22,     0x5c,   0x7e,   0x7f,   0x80,
    0x85,    0x9f,    0xa0,     0xa1,     0xad,   0xae,   0xff,   0x100,
    0x7ff,   0x800,   0xd7ff,   0xe000,   0xf8ff, 0xfffd, 0xfffe, 0xffff,
    0x10000, 0x1f600, 0x10fffe, 0x10ffff, 0x1680, 0x2000, 0x200a, 0x200b,
    0x2028,  0x2029,  0x202f,   0x205f,   0x3000,
};

const edge_floats = [_]f64{
    0.0,                    -0.0,                    1.0,                 0.5,
    2.0,                    0.1,                     1e15,                1e16,
    9.999999999999999e15,   1.5e-5,                  1e-4,                1e-3,
    1e-5,                   1e100,                   1e-100,              5e-324,
    1.7976931348623157e308, 2.2250738585072014e-308, 1.0000000000000002,  1794549600.123456,
    123456789012345.6,      1234567890123456.0,      12345678901234567.0, 0.3333333333333333,
    6.02214076e23,          -0.25,                   -1.5e-5,             123456789012345678901234567890.0,
    std.math.nan(f64),      std.math.inf(f64),       -std.math.inf(f64),
};

const doc_floats = [_]json.Py{
    .{ .float = 2.0 },    .{ .float = 0.5 },               .{ .float = 1e16 },
    .{ .float = 1.5e-5 }, .{ .float = 5e-324 },            .{ .float = 1e100 },
    .{ .float = -0.25 },  .{ .float = 1794549600.123456 },
};

const doc_ints = [_]json.Py{
    .{ .int = 0 },
    .{ .int = -1 },
    .{ .int = std.math.minInt(i64) },
    .{ .int = std.math.maxInt(i64) },
};

const doc_bools = [_]json.Py{ .null, .{ .bool = true }, .{ .bool = false } };

var doc_long_key: []const u8 = &.{};
var doc_long_value: []const u8 = &.{};

fn initDocStrings() void {
    const key = A.alloc(u8, 201) catch unreachable;
    @memset(key[0..200], 'k');
    key[200] = 0xff;
    doc_long_key = key;
    const value = A.alloc(u8, 600) catch unreachable;
    @memset(value, 'v');
    doc_long_value = value;
}

fn deepList(n: usize) json.Py {
    if (n == 0) return .{ .int = 1 };
    const items = A.alloc(json.Py, 1) catch unreachable;
    items[0] = deepList(n - 1);
    return .{ .list = items };
}

const str_doc_items = [_]json.Py.Entry{
    .{ .key = "empty", .value = .{ .str = "" } },
    .{ .key = "controls", .value = .{ .str = "\x00\x01\x08\x09\x0a\x0b\x0c\x0d\x1f\x7f" } },
    .{ .key = "separators", .value = .{ .str = "\u{2028}\u{2029}\u{a0}\u{ad}\u{85}" } },
    .{ .key = "astral", .value = .{ .str = "\u{1F600}\u{10000}\u{10FFFE}" } },
    .{ .key = "invalid", .value = .{ .str = "caf\xe9\xff\xfe\xf0\x9f\x98" } },
    .{ .key = "quotes", .value = .{ .str = "\"\\/'`$" } },
    .{ .key = "plain", .value = .{ .str = "x86_64/amd/zen4" } },
};

fn strDoc() json.Py {
    return .{ .dict = &str_doc_items };
}

const sort_doc_items = [_]json.Py.Entry{
    .{ .key = "b", .value = .{ .int = 2 } },
    .{ .key = "a", .value = .{ .int = 1 } },
    .{ .key = "\xff", .value = .{ .int = 3 } },
    .{ .key = "\u{e9}", .value = .{ .int = 4 } },
    .{ .key = "\u{100}", .value = .{ .int = 5 } },
    .{ .key = "\u{ff}", .value = .{ .int = 6 } },
    .{ .key = "\u{d7ff}", .value = .{ .int = 7 } },
    .{ .key = "\u{e000}", .value = .{ .int = 8 } },
    .{ .key = "A", .value = .{ .int = 9 } },
    .{ .key = "", .value = .{ .int = 10 } },
    .{ .key = "\xffz", .value = .{ .int = 11 } },
    .{ .key = "\u{10000}", .value = .{ .int = 12 } },
};

fn sortDoc() json.Py {
    return .{ .dict = &sort_doc_items };
}

fn longKeyDoc() json.Py {
    // The entries hold runtime-built strings, so the array itself comes
    // from the arena rather than a comptime literal.
    const entries = A.alloc(json.Py.Entry, 2) catch unreachable;
    entries[0] = .{ .key = doc_long_key, .value = .{ .str = doc_long_value } };
    entries[1] = .{ .key = "short", .value = .{ .str = "s" } };
    return .{ .dict = entries };
}

fn documents() [12]json.Py {
    return .{
        sortDoc(),
        .{ .list = &doc_floats },
        .{ .dict = &.{
            .{ .key = "a", .value = .{ .dict = &.{} } },
            .{ .key = "b", .value = .{ .list = &.{} } },
            .{ .key = "c", .value = .{ .list = &.{.{ .list = &.{} }} } },
            .{ .key = "d", .value = .{ .list = &.{.{ .dict = &.{} }} } },
        } },
        strDoc(),
        .{ .list = &doc_ints },
        .{ .list = &doc_bools },
        deepList(31),
        longKeyDoc(),
        .{ .list = &.{ .{ .str = "it's" }, .{ .str = "a\\b" }, .{ .str = "a/b" }, .{ .str = "'" }, .{ .str = "\"" } } },
        .{ .dict = &.{
            .{ .key = "", .value = .{ .int = 1 } },
            .{ .key = " ", .value = .{ .int = 2 } },
            .{ .key = "\t", .value = .{ .int = 3 } },
            .{ .key = "  ", .value = .{ .int = 4 } },
        } },
        .{ .dict = &.{
            .{ .key = "\xff", .value = .{ .str = "\xfe" } },
            .{ .key = "\xfe", .value = .{ .str = "\xff" } },
            .{ .key = "\u{10000}", .value = .{ .str = "\u{10ffff}" } },
        } },
        .{ .list = &.{ .{ .float = std.math.nan(f64) }, .{ .float = std.math.inf(f64) }, .{ .float = -std.math.inf(f64) } } },
    };
}

fn fromHex(line: []const u8) []const u8 {
    std.debug.assert(line.len % 2 == 0);
    const out = A.alloc(u8, line.len / 2) catch unreachable;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = std.fmt.charToDigit(line[i * 2], 16) catch unreachable;
        const lo = std.fmt.charToDigit(line[i * 2 + 1], 16) catch unreachable;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn errnoStdin() !void {
    const input = try common.fsx.readAll(A, 0, 64 << 20);
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const op = fields.next().?;
        const code = std.fmt.parseInt(u16, fields.next().?, 10) catch unreachable;
        const e: linux.E = @fromBackingInt(code);
        if (std.mem.eql(u8, op, "strerror")) {
            all.print(A, "{s}\n", .{hexOf(sys.strerror(e))}) catch unreachable;
        } else if (std.mem.eql(u8, op, "oserror")) {
            const path = fromHex(fields.next().?);
            const msg = try pytext.osErrorErrno(A, e, path);
            all.print(A, "{s}\n", .{hexOf(msg)}) catch unreachable;
        }
    }
    try sys.writeAll(1, all.items);
}

/// pytext.decimalToAscii over every code point that UTF-8 can carry, in
/// blocks of 1024 so that the case set stays small, and over a few strings
/// with bytes that are not UTF-8.
fn digitCases() void {
    var cp: u32 = 0;
    while (cp < 0x110000) : (cp += 1024) {
        var buf: std.ArrayList(u8) = .empty;
        var c = cp;
        while (c < cp + 1024) : (c += 1) {
            if (c >= 0xd800 and c <= 0xdfff) continue;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(c), &enc) catch unreachable;
            buf.appendSlice(A, enc[0..n]) catch unreachable;
        }
        emit("digits", buf.items, pytext.decimalToAscii(A, buf.items) catch unreachable);
    }
    const odd = [_][]const u8{ "\xff", "\xd9\xa3\xff\xd9\xa4", "\xd9", "\xf0\x9d\x9f", "\xef\xbc\x91\xe0\x80\xef\xbc\x92", "1_0", "" };
    for (odd) |in| emit("digits", in, pytext.decimalToAscii(A, in) catch unreachable);
}

pub fn main(init: std.process.Init) !void {
    arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    A = arena_state.allocator();
    const args = try init.minimal.args.toSlice(A);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--errno-stdin")) {
        return errnoStdin();
    }
    initDocStrings();

    // Every byte alone: the exhaustive part, cheap for all six kinds.
    for (0..256) |b| textCases(&[_]u8{@intCast(b)});

    // The invalid UTF-8 classes as lead byte followed by continuations,
    // at and past each range boundary.
    const pair_leads = [_]u8{ 0xc0, 0xc1, 0xc2, 0xc5, 0xdf, 0xe0, 0xe1, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf4, 0xf5, 0xf7, 0xfb, 0xfd, 0xff, 0x80, 0xbf, 0x41 };
    const pair_conts = [_]u8{ 0x7f, 0x80, 0x9f, 0xa0, 0xbf, 0xc0, 0x01 };
    for (pair_leads) |l| for (pair_conts) |c| textCases(&[_]u8{ l, c });

    const triple_leads = [_]u8{ 0xe0, 0xe3, 0xed, 0xee, 0xf0, 0xf4 };
    const triple_conts = [_]u8{ 0x7f, 0x80, 0x9f, 0xa0, 0xbf, 0xc0 };
    for (triple_leads) |l| {
        for (triple_conts) |c1| for (triple_conts) |c2| textCases(&[_]u8{ l, c1, c2 });
    }

    const quad_leads = [_]u8{ 0xf0, 0xf1, 0xf4, 0xf5 };
    const quad_conts = [_]u8{ 0x8f, 0x90, 0xbf, 0xc0 };
    for (quad_leads) |l| {
        for (quad_conts) |c1| for (quad_conts) |c2| for (quad_conts) |c3| textCases(&[_]u8{ l, c1, c2, c3 });
    }

    for (named) |seq| textCases(seq);

    for (boundary_cps) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        textCases(buf[0..n]);
    }

    // A fixed-seed sample of byte strings, most of them ill-formed in
    // one place or another.
    var prng = std.Random.DefaultPrng.init(0x5EED_0001);
    const rand = prng.random();
    for (0..1000) |_| {
        const len = rand.uintLessThan(usize, 17);
        const buf = A.alloc(u8, len) catch unreachable;
        for (buf) |*p| p.* = rand.int(u8);
        textCases(buf);
    }

    digitCases();
    for (edge_floats) |f| floatCaseBits(@bitCast(f));
    for (0..2000) |_| floatCaseBits(rand.int(u64));

    for (documents()) |doc| {
        for ([_]usize{ 0, 1, 2, 10 }) |indent| {
            for ([_]bool{ true, false }) |sort| dumpsCase(doc, indent, sort);
        }
    }

    for (documents()) |doc| {
        for ([_]bool{ true, false }) |sort| dumpsCompactCase(doc, sort);
    }

    for (0..100) |_| {
        const doc = randomPyDoc(rand, 0);
        for ([_]bool{ true, false }) |sort| dumpsCompactCase(doc, sort);
    }

    for (0..201) |code| strerrorCase(@intCast(code));
    for (0..100) |_| strerrorCase(rand.uintLessThan(u16, 4096));

    const oserror_codes = [_]u16{ 0, 1, 2, 3, 4, 10, 11, 13, 17, 20, 21, 32, 103, 104, 108, 110, 111, 114, 115, 134, 160, 177, 999 };
    const oserror_paths = [_][]const u8{ "/no/such", "a'b", "a'b\"c", "a\nb\xff", "" };
    for (oserror_codes) |code| {
        for (oserror_paths) |path| osErrorCase(code, path);
    }

    try sys.writeAll(1, all.items);
}
