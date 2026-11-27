//! Python's view of byte strings: text decoded from UTF-8 with
//! surrogateescape (an invalid byte is one character), the 'replace'
//! decoder, str.isspace/strip/split, and shlex.quote. Tools ported from
//! Python use these so a byte string means what it meant there.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const nd = @import("pytext_nd.zig");

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

/// The value of the decimal digit `cp`, as unicodedata.decimal gives it, or
/// null when `cp` has no decimal value. These are the characters Python's
/// float() and int() read as digits.
pub fn decimalDigit(cp: u21) ?u4 {
    var lo: usize = 0;
    var hi: usize = nd.zeros.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nd.zeros[mid] <= cp) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const offset = cp - nd.zeros[lo - 1];
    return if (offset < 10) @intCast(offset) else null;
}

/// `s` with each decimal digit written as the ASCII digit of its value, the
/// way Python's float() and int() read their text before they parse it. The
/// other characters, and the bytes that are not valid UTF-8, are copied as
/// they are. The caller owns the result.
pub fn decimalToAscii(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, s.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const ch = nextChar(s[i..]);
        if (ch.cp) |cp| if (decimalDigit(cp)) |d| {
            out.appendAssumeCapacity('0' + @as(u8, d));
            i += ch.len;
            continue;
        };
        out.appendSliceAssumeCapacity(s[i .. i + ch.len]);
        i += ch.len;
    }
    return out.toOwnedSlice(gpa);
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

/// Inclusive ranges where Python's `str.isprintable` is false.
/// Unicode 16.0.0. U+0020 is not listed.
const np_hex =
    \\00000000001f00007f0000a00000ad0000ad00037800037900038000038300038b00038b00038d00038d0003a20003a200053000053000055700055800058b00058c0005900005900005c80005cf0005eb0005ee0005f500060500061c00061c0006dd0006dd00070e00070f00074b00074c0007b20007bf0007fb0007fc00082e00082f00083f00083f00085c00085d00085f00085f00086b00086f00088f0008960008e20008e200098400098400098d00098e0009910009920009a90009a90009b10009b10009b30009b50009ba0009bb0009c50009c60009c90009ca0009cf0009d60009d80009db0009de0009de0009e40009e50009ff000a00000a04000a04000a0b000a0e000a11000a12000a29000a29000a31000a31000a34000a34
    \\000a37000a37000a3a000a3b000a3d000a3d000a43000a46000a49000a4a000a4e000a50000a52000a58000a5d000a5d000a5f000a65000a77000a80000a84000a84000a8e000a8e000a92000a92000aa9000aa9000ab1000ab1000ab4000ab4000aba000abb000ac6000ac6000aca000aca000ace000acf000ad1000adf000ae4000ae5000af2000af8000b00000b00000b04000b04000b0d000b0e000b11000b12000b29000b29000b31000b31000b34000b34000b3a000b3b000b45000b46000b49000b4a000b4e000b54000b58000b5b000b5e000b5e000b64000b65000b78000b81000b84000b84000b8b000b8d000b91000b91000b96000b98000b9b000b9b000b9d000b9d000ba0000ba2000ba5000ba7000bab000bad000bba000bbd
    \\000bc3000bc5000bc9000bc9000bce000bcf000bd1000bd6000bd8000be5000bfb000bff000c0d000c0d000c11000c11000c29000c29000c3a000c3b000c45000c45000c49000c49000c4e000c54000c57000c57000c5b000c5c000c5e000c5f000c64000c65000c70000c76000c8d000c8d000c91000c91000ca9000ca9000cb4000cb4000cba000cbb000cc5000cc5000cc9000cc9000cce000cd4000cd7000cdc000cdf000cdf000ce4000ce5000cf0000cf0000cf4000cff000d0d000d0d000d11000d11000d45000d45000d49000d49000d50000d53000d64000d65000d80000d80000d84000d84000d97000d99000db2000db2000dbc000dbc000dbe000dbf000dc7000dc9000dcb000dce000dd5000dd5000dd7000dd7000de0000de5
    \\000df0000df1000df5000e00000e3b000e3e000e5c000e80000e83000e83000e85000e85000e8b000e8b000ea4000ea4000ea6000ea6000ebe000ebf000ec5000ec5000ec7000ec7000ecf000ecf000eda000edb000ee0000eff000f48000f48000f6d000f70000f98000f98000fbd000fbd000fcd000fcd000fdb000fff0010c60010c60010c80010cc0010ce0010cf00124900124900124e00124f00125700125700125900125900125e00125f00128900128900128e00128f0012b10012b10012b60012b70012bf0012bf0012c10012c10012c60012c70012d70012d700131100131100131600131700135b00135c00137d00137f00139a00139f0013f60013f70013fe0013ff00168000168000169d00169f0016f90016ff00171600171e
    \\00173700173f00175400175f00176d00176d00177100177100177400177f0017de0017df0017ea0017ef0017fa0017ff00180e00180e00181a00181f00187900187f0018ab0018af0018f60018ff00191f00191f00192c00192f00193c00193f00194100194300196e00196f00197500197f0019ac0019af0019ca0019cf0019db0019dd001a1c001a1d001a5f001a5f001a7d001a7e001a8a001a8f001a9a001a9f001aae001aaf001acf001aff001b4d001b4d001bf4001bfb001c38001c3a001c4a001c4c001c8b001c8f001cbb001cbc001cc8001ccf001cfb001cff001f16001f17001f1e001f1f001f46001f47001f4e001f4f001f58001f58001f5a001f5a001f5c001f5c001f5e001f5e001f7e001f7f001fb5001fb5001fc5001fc5
    \\001fd4001fd5001fdc001fdc001ff0001ff1001ff5001ff5001fff00200f00202800202f00205f00206f00207200207300208f00208f00209d00209f0020c10020cf0020f10020ff00218c00218f00242a00243f00244b00245f002b74002b75002b96002b96002cf4002cf8002d26002d26002d28002d2c002d2e002d2f002d68002d6e002d71002d7e002d97002d9f002da7002da7002daf002daf002db7002db7002dbf002dbf002dc7002dc7002dcf002dcf002dd7002dd7002ddf002ddf002e5e002e7f002e9a002e9a002ef4002eff002fd6002fef00300000300000304000304000309700309800310000310400313000313000318f00318f0031e60031ee00321f00321f00a48d00a48f00a4c700a4cf00a62c00a63f00a6f800a6ff
    \\00a7ce00a7cf00a7d200a7d200a7d400a7d400a7dd00a7f100a82d00a82f00a83a00a83f00a87800a87f00a8c600a8cd00a8da00a8df00a95400a95e00a97d00a97f00a9ce00a9ce00a9da00a9dd00a9ff00a9ff00aa3700aa3f00aa4e00aa4f00aa5a00aa5b00aac300aada00aaf700ab0000ab0700ab0800ab0f00ab1000ab1700ab1f00ab2700ab2700ab2f00ab2f00ab6c00ab6f00abee00abef00abfa00abff00d7a400d7af00d7c700d7ca00d7fc00f8ff00fa6e00fa6f00fada00faff00fb0700fb1200fb1800fb1c00fb3700fb3700fb3d00fb3d00fb3f00fb3f00fb4200fb4200fb4500fb4500fbc300fbd200fd9000fd9100fdc800fdce00fdd000fdef00fe1a00fe1f00fe5300fe5300fe6700fe6700fe6c00fe6f00fe7500fe75
    \\00fefd00ff0000ffbf00ffc100ffc800ffc900ffd000ffd100ffd800ffd900ffdd00ffdf00ffe700ffe700ffef00fffb00fffe00ffff01000c01000c01002701002701003b01003b01003e01003e01004e01004f01005e01007f0100fb0100ff01010301010601013401013601018f01018f01019d01019f0101a10101cf0101fe01027f01029d01029f0102d10102df0102fc0102ff01032401032c01034b01034f01037b01037f01039e01039e0103c40103c70103d60103ff01049e01049f0104aa0104af0104d40104d70104fc0104ff01052801052f01056401056e01057b01057b01058b01058b0105930105930105960105960105a20105a20105b20105b20105ba0105ba0105bd0105bf0105f40105ff01073701073f01075601075f
    \\01076801077f0107860107860107b10107b10107bb0107ff01080601080701080901080901083601083601083901083b01083d01083e01085601085601089f0108a60108b00108df0108f30108f30108f60108fa01091c01091e01093a01093e01094001097f0109b80109bb0109d00109d1010a04010a04010a07010a0b010a14010a14010a18010a18010a36010a37010a3b010a3e010a49010a4f010a59010a5f010aa0010abf010ae7010aea010af7010aff010b36010b38010b56010b57010b73010b77010b92010b98010b9d010ba8010bb0010bff010c49010c7f010cb3010cbf010cf3010cf9010d28010d2f010d3a010d3f010d66010d68010d86010d8d010d90010e5f010e7f010e7f010eaa010eaa010eae010eaf010eb2010ec1
    \\010ec5010efb010f28010f2f010f5a010f6f010f8a010faf010fcc010fdf010ff7010fff01104e01105101107601107e0110bd0110bd0110c30110cf0110e90110ef0110fa0110ff01113501113501114801114f01117701117f0111e00111e00111f50111ff01121201121201124201127f01128701128701128901128901128e01128e01129e01129e0112aa0112af0112eb0112ef0112fa0112ff01130401130401130d01130e01131101131201132901132901133101133101133401133401133a01133a01134501134601134901134a01134e01134f01135101135601135801135c01136401136501136d01136f01137501137f01138a01138a01138c01138d01138f01138f0113b60113b60113c10113c10113c30113c40113c60113c6
    \\0113cb0113cb0113d60113d60113d90113e00113e30113ff01145c01145c01146201147f0114c80114cf0114da01157f0115b60115b70115de0115ff01164501164f01165a01165f01166d01167f0116ba0116bf0116ca0116cf0116e40116ff01171b01171c01172c01172f0117470117ff01183c01189f0118f30118fe01190701190801190a01190b01191401191401191701191701193601193601193901193a01194701194f01195a01199f0119a80119a90119d80119d90119e50119ff011a48011a4f011aa3011aaf011af9011aff011b0a011bbf011be2011bef011bfa011bff011c09011c09011c37011c37011c46011c4f011c6d011c6f011c90011c91011ca8011ca8011cb7011cff011d07011d07011d0a011d0a011d37011d39
    \\011d3b011d3b011d3e011d3e011d48011d4f011d5a011d5f011d66011d66011d69011d69011d8f011d8f011d92011d92011d99011d9f011daa011edf011ef9011eff011f11011f11011f3b011f3d011f5b011faf011fb1011fbf011ff2011ffe01239a0123ff01246f01246f01247501247f012544012f8f012ff3012fff01343001343f01345601345f0143fb0143ff0146470160ff01613a0167ff016a39016a3f016a5f016a5f016a6a016a6d016abf016abf016aca016acf016aee016aef016af6016aff016b46016b4f016b5a016b5a016b62016b62016b78016b7c016b90016d3f016d7a016e3f016e9b016eff016f4b016f4e016f88016f8e016fa0016fdf016fe5016fef016ff2016fff0187f80187ff018cd6018cfe018d0901afef
    \\01aff401aff401affc01affc01afff01afff01b12301b13101b13301b14f01b15301b15401b15601b16301b16801b16f01b2fc01bbff01bc6b01bc6f01bc7d01bc7f01bc8901bc8f01bc9a01bc9b01bca001cbff01ccfa01ccff01ceb401ceff01cf2e01cf2f01cf4701cf4f01cfc401cfff01d0f601d0ff01d12701d12801d17301d17a01d1eb01d1ff01d24601d2bf01d2d401d2df01d2f401d2ff01d35701d35f01d37901d3ff01d45501d45501d49d01d49d01d4a001d4a101d4a301d4a401d4a701d4a801d4ad01d4ad01d4ba01d4ba01d4bc01d4bc01d4c401d4c401d50601d50601d50b01d50c01d51501d51501d51d01d51d01d53a01d53a01d53f01d53f01d54501d54501d54701d54901d55101d55101d6a601d6a701d7cc01d7cd
    \\01da8c01da9a01daa001daa001dab001deff01df1f01df2401df2b01dfff01e00701e00701e01901e01a01e02201e02201e02501e02501e02b01e02f01e06e01e08e01e09001e0ff01e12d01e12f01e13e01e13f01e14a01e14d01e15001e28f01e2af01e2bf01e2fa01e2fe01e30001e4cf01e4fa01e5cf01e5fb01e5fe01e60001e7df01e7e701e7e701e7ec01e7ec01e7ef01e7ef01e7ff01e7ff01e8c501e8c601e8d701e8ff01e94c01e94f01e95a01e95d01e96001ec7001ecb501ed0001ed3e01edff01ee0401ee0401ee2001ee2001ee2301ee2301ee2501ee2601ee2801ee2801ee3301ee3301ee3801ee3801ee3a01ee3a01ee3c01ee4101ee4301ee4601ee4801ee4801ee4a01ee4a01ee4c01ee4c01ee5001ee5001ee5301ee53
    \\01ee5501ee5601ee5801ee5801ee5a01ee5a01ee5c01ee5c01ee5e01ee5e01ee6001ee6001ee6301ee6301ee6501ee6601ee6b01ee6b01ee7301ee7301ee7801ee7801ee7d01ee7d01ee7f01ee7f01ee8a01ee8a01ee9c01eea001eea401eea401eeaa01eeaa01eebc01eeef01eef201efff01f02c01f02f01f09401f09f01f0af01f0b001f0c001f0c001f0d001f0d001f0f601f0ff01f1ae01f1e501f20301f20f01f23c01f23f01f24901f24f01f25201f25f01f26601f2ff01f6d801f6db01f6ed01f6ef01f6fd01f6ff01f77701f77a01f7da01f7df01f7ec01f7ef01f7f101f7ff01f80c01f80f01f84801f84f01f85a01f85f01f88801f88f01f8ae01f8af01f8bc01f8bf01f8c201f8ff01fa5401fa5f01fa6e01fa6f01fa7d01fa7f
    \\01fa8a01fa8e01fac701facd01fadd01fade01faea01faef01faf901faff01fb9301fb9301fbfa01ffff02a6e002a6ff02b73a02b73f02b81e02b81f02cea202ceaf02ebe102ebef02ee5e02f7ff02fa1e02ffff03134b03134f0323b00e00ff0e01f010ffff
;

const NpRange = struct { lo: u21, hi: u21 };

fn hex6(s: []const u8) u21 {
    var v: u32 = 0;
    for (s[0..6]) |c| v = (v << 4) | switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => unreachable,
    };
    return @intCast(v);
}

fn loadRanges(comptime raw: []const u8) [737]NpRange {
    @setEvalBranchQuota(100_000);
    var out: [737]NpRange = undefined;
    var i: usize = 0;
    for (0..737) |r| {
        while (raw[i] == '\n') i += 1;
        out[r] = .{ .lo = hex6(raw[i..]), .hi = hex6(raw[i + 6 ..]) };
        i += 12;
    }
    return out;
}

const np_ranges = loadRanges(np_hex);

fn pyPrintable(cp: u21) bool {
    var lo: usize = 0;
    var hi = np_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (np_ranges[mid].hi < cp) lo = mid + 1 else hi = mid;
    }
    if (lo == np_ranges.len) return true;
    return cp < np_ranges[lo].lo;
}

fn appendReprEscape(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) Allocator.Error!void {
    if (cp < 0x100) {
        try out.print(gpa, "\\x{x:0>2}", .{cp});
    } else if (cp < 0x10000) {
        try out.print(gpa, "\\u{x:0>4}", .{cp});
    } else {
        try out.print(gpa, "\\U{x:0>8}", .{cp});
    }
}

/// Python's `repr` for text decoded from `s` with surrogateescape.
/// The quote is `'` unless `s` has `'` and no `"`.
/// `\\`, `\t`, `\n`, and `\r` are short escapes.
/// Other nonprintable code points use `\x`, `\u`, or `\U`.
/// A byte that is not valid UTF-8 is `\udcNN`.
pub fn reprStr(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    const quote: u8 = if (std.mem.findScalar(u8, s, '\'') != null and std.mem.findScalar(u8, s, '"') == null) '"' else '\'';
    try out.append(gpa, quote);
    var i: usize = 0;
    while (i < s.len) {
        const ch = nextChar(s[i..]);
        if (ch.cp) |cp| switch (cp) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            else => {
                if (!pyPrintable(cp)) {
                    try appendReprEscape(out, gpa, cp);
                } else {
                    if (cp == quote) try out.append(gpa, '\\');
                    try out.appendSlice(gpa, s[i .. i + ch.len]);
                }
            },
        } else try appendReprEscape(out, gpa, 0xDC00 + @as(u21, s[i]));
        i += ch.len;
    }
    try out.append(gpa, quote);
}

pub fn reprStrAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try reprStr(&out, gpa, s);
    return out.toOwnedSlice(gpa);
}

/// Format an `OSError` message with Python-quoted path: `"[Errno N] text: 'path'"`
/// (or `"ErrorName: 'path'"` when `err` is not a `sys.Error`).
pub fn osError(gpa: Allocator, err: anyerror, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, if (sys.asError(err)) |e| sys.describe(e) else @errorName(err));
    try out.appendSlice(gpa, ": ");
    try reprStr(&out, gpa, path);
    return out.toOwnedSlice(gpa);
}

/// Format an `OSError` message for an explicit `linux.E` and Python-quoted path.
pub fn osErrorErrno(gpa: Allocator, e: linux.E, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, sys.describeErrno(e));
    try out.appendSlice(gpa, ": ");
    try reprStr(&out, gpa, path);
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

test "reprStr and reprStrAlloc match Python repr" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "/tmp/x", "'/tmp/x'" },
        .{ "it's", "\"it's\"" },
        .{ "a'b\"c", "'a\\'b\"c'" },
        .{ "a\\b", "'a\\\\b'" },
        .{ "\t\n\r\x01\x7f", "'\\t\\n\\r\\x01\\x7f'" },
        .{ "caf\xe9", "'caf\\udce9'" },
        .{ "caf\u{e9}", "'caf\u{e9}'" },
        .{ "\u{a0}\u{ad}\u{85}\u{ff}", "'\\xa0\\xad\\x85\u{ff}'" },
        .{ "\x00", "'\\x00'" },
        .{ "\u{2028}", "'\\u2028'" },
        .{ "\u{200b}", "'\\u200b'" },
        .{ "\u{feff}", "'\\ufeff'" },
        .{ "\u{3000}", "'\\u3000'" },
        .{ "\u{1680}", "'\\u1680'" },
        .{ "\u{0378}", "'\\u0378'" },
        .{ "\u{fffe}", "'\\ufffe'" },
        .{ "\u{e000}", "'\\ue000'" },
        .{ "\u{10ffff}", "'\\U0010ffff'" },
        .{ "\u{f0000}", "'\\U000f0000'" },
        .{ "\u{1f600}", "'\u{1f600}'" },
        .{ "it's\u{2028}", "\"it's\\u2028\"" },
        .{ "a\u{2028}b'c", "\"a\\u2028b'c\"" },
    };
    for (cases) |cs| {
        const r = try reprStrAlloc(gpa, cs[0]);
        defer gpa.free(r);
        try std.testing.expectEqualStrings(cs[1], r);
    }
}

test "nonprintable ranges match Unicode 16.0.0" {
    // FNV-1a over one bit per code point. Python 3.14.10, unicodedata 16.0.0.
    var h: u64 = 14695981039346656037;
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        const bit: u64 = if (pyPrintable(@intCast(cp))) 0 else 1;
        h ^= bit;
        h *%= 1099511628211;
    }
    try std.testing.expectEqual(@as(u64, 1340014757921071005), h);
}

test "osError and osErrorErrno format OSError messages with Python path quoting" {
    const gpa = std.testing.allocator;
    const e1 = try osError(gpa, error.NotFound, "/no/such");
    defer gpa.free(e1);
    try std.testing.expectEqualStrings("[Errno 2] No such file or directory: '/no/such'", e1);
    const e2 = try osError(gpa, error.CustomThing, "a'b");
    defer gpa.free(e2);
    try std.testing.expectEqualStrings("CustomThing: \"a'b\"", e2);
    const e3 = try osErrorErrno(gpa, .NAMETOOLONG, "/long");
    defer gpa.free(e3);
    try std.testing.expectEqualStrings("[Errno 36] File name too long: '/long'", e3);
}

test "decimalDigit reads the runs of ten decimal digits" {
    try std.testing.expectEqual(@as(?u4, null), decimalDigit(0x2f));
    try std.testing.expectEqual(@as(?u4, 0), decimalDigit('0'));
    try std.testing.expectEqual(@as(?u4, 9), decimalDigit('9'));
    try std.testing.expectEqual(@as(?u4, null), decimalDigit(':'));
    try std.testing.expectEqual(@as(?u4, 3), decimalDigit(0x663));
    try std.testing.expectEqual(@as(?u4, 9), decimalDigit(0xff19));
    try std.testing.expectEqual(@as(?u4, null), decimalDigit(0xff1a));
    try std.testing.expectEqual(@as(?u4, 0), decimalDigit(0x1d7ce));
    try std.testing.expectEqual(@as(?u4, 9), decimalDigit(0x1d7ff));
    try std.testing.expectEqual(@as(?u4, null), decimalDigit(0x1d800));
    try std.testing.expectEqual(@as(?u4, null), decimalDigit(0xb2));
    try std.testing.expectEqual(@as(?u4, null), decimalDigit(0x10ffff));
}

test "decimalToAscii writes decimal digits as ASCII and keeps the rest" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "", "" },
        .{ "12.5", "12.5" },
        .{ "\xd9\xa3", "3" },
        .{ "\xef\xbc\x91\xef\xbc\x90_\xef\xbc\x90", "10_0" },
        .{ "\xc2\xb2x\xff\xd9\xa7", "\xc2\xb2x\xff7" },
    };
    for (cases) |cs| {
        const r = try decimalToAscii(gpa, cs[0]);
        defer gpa.free(r);
        try std.testing.expectEqualStrings(cs[1], r);
    }
}
