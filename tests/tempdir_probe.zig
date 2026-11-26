//! The temporary directory probe. Stdin is a batch of cases; stdout is one
//! result line per case, in order. A case is an environment, an optional
//! file size limit, and whether the working directory has been removed.
//! The Python test runs `tempfile.gettempdir` on the same batch.
//!
//! A line is `ok`, a tab and the directory, or `err`, a tab, the Python
//! class name and the `str()` of the error. Like Python, the probe ignores
//! SIGXFSZ, so a write past a file size limit fails with EFBIG instead of
//! ending the process.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");

const fsx = common.fsx;
const sys = common.sys;

const Env = struct {
    blob: []const u8,

    pub fn get(e: Env, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, e.blob, 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
        }
        return null;
    }
};

const Case = struct {
    cap: ?u64,
    gone: bool,
    env: Env,
};

fn readStdin(a: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }
        if (n == 0) break;
        try list.appendSlice(a, buf[0..n]);
    }
    return list.toOwnedSlice(a);
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.Invalid,
    };
}

fn unhex(a: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.Invalid;
    const out = try a.alloc(u8, text.len / 2);
    for (out, 0..) |*b, i| {
        b.* = try hexNibble(text[i * 2]) << 4 | try hexNibble(text[i * 2 + 1]);
    }
    return out;
}

fn parse(a: std.mem.Allocator, text: []const u8) ![]Case {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const n = try std.fmt.parseInt(usize, lines.next() orelse return error.Invalid, 10);
    const cases = try a.alloc(Case, n);
    for (cases) |*case| {
        const head = lines.next() orelse return error.Invalid;
        var cols = std.mem.splitScalar(u8, head, '\t');
        const cap_s = cols.next() orelse return error.Invalid;
        const gone_s = cols.next() orelse return error.Invalid;
        const nenv_s = cols.next() orelse return error.Invalid;
        const cap: ?u64 = if (std.mem.eql(u8, cap_s, "-")) null else try std.fmt.parseInt(u64, cap_s, 10);
        const nenv = try std.fmt.parseInt(usize, nenv_s, 10);
        var blob: std.ArrayList(u8) = .empty;
        for (0..nenv) |_| {
            const row = lines.next() orelse return error.Invalid;
            var kv = std.mem.splitScalar(u8, row, '\t');
            const key = try unhex(a, kv.next() orelse return error.Invalid);
            const val = try unhex(a, kv.next() orelse return error.Invalid);
            try blob.appendSlice(a, key);
            try blob.append(a, '=');
            try blob.appendSlice(a, val);
            try blob.append(a, 0);
        }
        case.* = .{
            .cap = cap,
            .gone = std.mem.eql(u8, gone_s, "1"),
            .env = .{ .blob = try blob.toOwnedSlice(a) },
        };
    }
    return cases;
}

fn fsizeLimit(new: ?*const linux.rlimit, old: ?*linux.rlimit) sys.Error!void {
    _ = try sys.call(linux.prlimit, .{ @as(linux.pid_t, 0), linux.rlimit_resource.FSIZE, new, old });
}

fn removeCwd(a: std.mem.Allocator) !void {
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const gone = try std.fmt.allocPrint(a, "{s}/gone-batch", .{here});
    defer a.free(gone);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = try sys.call(linux.mkdirat, .{ fsx.cwd, (try sys.z(&zb, gone)).ptr, @as(linux.mode_t, 0o700) });
    _ = try sys.call(linux.chdir, .{(try sys.z(&zb, gone)).ptr});
    _ = try sys.call(linux.unlinkat, .{ linux.AT.FDCWD, (try sys.z(&zb, gone)).ptr, linux.AT.REMOVEDIR });
}

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(1, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return;
                off += n;
            },
            .INTR => continue,
            else => return,
        }
    }
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const ignore: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.XFSZ, &ignore, null);

    const saved = try sys.openat(fsx.cwd, ".", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer sys.close(saved);
    var saved_lim: linux.rlimit = undefined;
    try fsizeLimit(null, &saved_lim);

    const cases = try parse(a, try readStdin(a));
    for (cases) |case| {
        if (case.cap) |cap| {
            // Keep the hard limit. A later case has to raise the soft
            // limit again, and an unprivileged process cannot raise the hard one.
            const lim: linux.rlimit = .{ .cur = cap, .max = saved_lim.max };
            try fsizeLimit(&lim, null);
        } else try fsizeLimit(&saved_lim, null);
        if (case.gone) try removeCwd(a);
        defer if (case.gone) {
            _ = linux.fchdir(saved);
        };
        var td: fsx.TempDir = .{};
        defer td.deinit(a);
        const line = if (td.get(a, case.env)) |dir|
            try std.fmt.allocPrint(a, "ok\t{s}\n", .{dir})
        else |err| switch (err) {
            error.NoTempDir => try std.fmt.allocPrint(a, "err\tFileNotFoundError\t{s}\n", .{td.message}),
            error.OutOfMemory => return err,
        };
        writeAll(line);
    }
}
