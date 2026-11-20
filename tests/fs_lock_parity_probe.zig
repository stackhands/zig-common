//! The filesystem and lock parity probe: writes this library's path
//! normalization, filesystem effects, realpath results and lock
//! outcomes for a deterministic case set. The Python test beside this
//! file recomputes every case with os.path, os.makedirs, shutil-style
//! copies, os.replace, os.path.realpath and fcntl.flock, and compares
//! byte for byte, so an errno, a mode bit or a lock outcome cannot
//! drift quietly.
//!
//! Modes, one per invocation, from the test:
//!
//!  - `norm`: normPath and absPath lines for a fixed path corpus. The
//!    test runs the probe with the fixture directory as its working
//!    directory and computes os.path.abspath against the same one.
//!  - `effects`: one line per filesystem operation on the fixture the
//!    test created around the probe's working directory.
//!  - `try-lock PATH`: opens PATH and takes state.lockExclusive with a
//!    short timeout, printing the outcome. The test holds the lock.
//!  - `hold-lock PATH MS`: takes the lock with no timeout, prints
//!    `held`, sleeps MS and exits, releasing the lock as it goes.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");

const fsx = common.fsx;
const state = common.state;
const sys = common.sys;

var arena_state: std.heap.ArenaAllocator = undefined;
var A: std.mem.Allocator = undefined;
var all: std.ArrayList(u8) = .empty;

fn put(bytes: []const u8) void {
    _ = linux.write(1, bytes.ptr, bytes.len);
}

fn hexOf(bytes: []const u8) []const u8 {
    const out = A.alloc(u8, bytes.len * 2) catch unreachable;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}

fn emit(parts: []const []const u8) void {
    for (parts, 0..) |p, i| {
        if (i > 0) all.append(A, '\t') catch unreachable;
        all.appendSlice(A, p) catch unreachable;
    }
    all.append(A, '\n') catch unreachable;
}

fn errName(e: anyerror) []const u8 {
    return @errorName(e);
}

/// `OP\tARG\tOK` or `OP\tARG\tERR:<error>`, Python's per-call view.
fn opLine(op: []const u8, arg: []const u8, result: anytype) void {
    if (result) |_| {
        emit(&.{ op, hexOf(arg), "OK" });
    } else |e| {
        emit(&.{ op, hexOf(arg), std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable });
    }
}

// ---- the norm corpus -------------------------------------------------------

const segs = [_][]const u8{ "", ".", "..", "a" };

const norm_corpus = [_][]const u8{
    "",              ".",       "..",                "a",         "a/",           "a//",      "./a",
    "a/.",           "a/./b",   "a/b/../c",          "../a/b/..", "/a/b/../c/",   "/../../a", "//a/b/..",
    "///a//b",       "//",      "/",                 "a/../..",   "a/b/../../..", "\xff/..",  "a/\xff/b",
    "\xc3\xa9/../x", "..//..",  "a//b//c//",         "/.",        "/..",          "//..",     "./",
    "../",           "./././a", "/a/b/c/../../../d", "\xff\xfe",
};

fn normMode() !void {
    // every combination of the segments, one to four deep
    for (segs) |s1| {
        emit(&.{ "normPath", hexOf(s1), hexOf(fsx.normPath(A, s1) catch unreachable) });
        const one = std.mem.concat(A, u8, &.{ s1, "/", "a" }) catch unreachable;
        emit(&.{ "normPath", hexOf(one), hexOf(fsx.normPath(A, one) catch unreachable) });
        for (segs) |s2| {
            const two = std.mem.concat(A, u8, &.{ s1, "/", s2 }) catch unreachable;
            emit(&.{ "normPath", hexOf(two), hexOf(fsx.normPath(A, two) catch unreachable) });
            for (segs) |s3| {
                const three = std.mem.concat(A, u8, &.{ s1, "/", s2, "/", s3 }) catch unreachable;
                emit(&.{ "normPath", hexOf(three), hexOf(fsx.normPath(A, three) catch unreachable) });
                for (segs) |s4| {
                    const four = std.mem.concat(A, u8, &.{ s1, "/", s2, "/", s3, "/", s4 }) catch unreachable;
                    emit(&.{ "normPath", hexOf(four), hexOf(fsx.normPath(A, four) catch unreachable) });
                }
            }
        }
    }
    for (norm_corpus) |p| {
        emit(&.{ "normPath", hexOf(p), hexOf(fsx.normPath(A, p) catch unreachable) });
        emit(&.{ "absPath", hexOf(p), hexOf(fsx.absPath(A, p) catch unreachable) });
    }
    // absPath for every single segment too
    for (segs) |s1| emit(&.{ "absPath", hexOf(s1), hexOf(fsx.absPath(A, s1) catch unreachable) });
}

// ---- the effects corpus ----------------------------------------------------

fn makedirsCase(name: []const u8) void {
    opLine("makedirs", name, common.atomic.makedirs(name));
}

fn copySrcCase() void {
    const result = fsx.openRegular(fsx.cwd, "no-such-src", false);
    if (result) |r| {
        sys.close(r.fd);
        emit(&.{ "copyto-src", hexOf("no-such-src"), "OK" });
    } else |e| {
        emit(&.{ "copyto-src", hexOf("no-such-src"), std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable });
    }
}

fn copyToCase(dir: fsx.fd_t, dst: []const u8) void {
    const src = fsx.openRegular(fsx.cwd, "copysrc", false) catch |e| {
        emit(&.{ "copyto-src", hexOf("copysrc"), std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable });
        return;
    };
    defer sys.close(src.fd);
    const out = fsx.copyTo(src.fd, src.stat, dir, dst);
    if (out) |fd| {
        sys.close(fd);
        emit(&.{ "copyto", hexOf(dst), "OK" });
    } else |e| {
        emit(&.{ "copyto", hexOf(dst), std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable });
    }
}

fn moveAcrossCase(dir: fsx.fd_t, src: []const u8, dst: []const u8) void {
    const arg = std.mem.concat(A, u8, &.{ src, "->", dst }) catch unreachable;
    const result = fsx.moveAcross(A, dir, src, dir, dst, .{});
    if (result) |_| {
        emit(&.{ "moveacross", hexOf(arg), "OK" });
    } else |e| {
        emit(&.{ "moveacross", hexOf(arg), std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable });
    }
}

fn realpathCase(name: []const u8) void {
    var buf: [sys.path_max]u8 = undefined;
    const result = fsx.realpath(fsx.cwd, name, &buf);
    if (result) |resolved| {
        emit(&.{ "realpath", hexOf(name), "OK", hexOf(resolved) });
    } else |e| {
        emit(&.{ "realpath", hexOf(name), std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable });
    }
}

fn effectsMode() void {
    // copyTo and moveAcross end with a directory fsync, so they take a
    // real descriptor rather than the AT.FDCWD alias.
    const dir = fsx.openDir(fsx.cwd, ".", false) catch unreachable;
    defer sys.close(dir);
    makedirsCase("d");
    makedirsCase("f");
    makedirsCase("dangling");
    makedirsCase("f/x");
    makedirsCase("dangling/x");
    makedirsCase("fresh/a/b");
    copySrcCase();
    copyToCase(dir, "dst");
    copyToCase(dir, "new");
    copyToCase(dir, "d");
    copyToCase(dir, "tolink");
    moveAcrossCase(dir, "mvsrc", "mvdst");
    moveAcrossCase(dir, "missing-src", "mvdst2");
    realpathCase("d");
    realpathCase("sym");
    realpathCase("sym/sym");
    realpathCase("loop");
    realpathCase("dangling");
    realpathCase("\xffdir");
    realpathCase("d/\xffdir/../f");
}

// ---- the lock modes --------------------------------------------------------

fn openLockFile(path: []const u8) sys.fd_t {
    return sys.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR }, 0o600) catch unreachable;
}

fn tryLockMode(path: []const u8) void {
    const fd = openLockFile(path);
    defer sys.close(fd);
    const result = state.lockExclusive(fd, 400);
    if (result) |_| {
        put("lockExclusive\tOK\n");
    } else |e| {
        const line = std.fmt.allocPrint(A, "lockExclusive\t{s}\n", .{@errorName(e)}) catch unreachable;
        put(line);
    }
}

fn holdLockMode(path: []const u8, ms: u64) void {
    const fd = openLockFile(path);
    defer sys.close(fd);
    state.lockExclusive(fd, null) catch unreachable;
    put("held\n");
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    A = arena_state.allocator();

    var args_it = std.process.Args.Iterator.init(init.args);
    if (args_it.next() == null) return error.InvalidArgument;
    const mode = args_it.next() orelse return error.InvalidArgument;
    const arg2 = args_it.next();
    if (std.mem.eql(u8, mode, "norm")) {
        try normMode();
    } else if (std.mem.eql(u8, mode, "effects")) {
        effectsMode();
    } else if (std.mem.eql(u8, mode, "try-lock")) {
        tryLockMode(arg2 orelse return error.InvalidArgument);
    } else if (std.mem.eql(u8, mode, "hold-lock")) {
        const path = arg2 orelse return error.InvalidArgument;
        const ms_txt = args_it.next() orelse return error.InvalidArgument;
        holdLockMode(path, std.fmt.parseInt(u64, ms_txt, 10) catch unreachable);
    } else {
        return error.InvalidArgument;
    }
    put(all.items);
}
