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
//!  - `osfail`: atomicWrite failures. The last field is the full
//!    `why.msg`, compared with str() of the OSError Python raises for
//!    the same call.
//!  - `rootlock`: RootLock.acquire failures. The last two fields are
//!    osFailure text and path, or NONE when the failure was not an
//!    operating-system error.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");

const fsx = common.fsx;
const state = common.state;
const sys = common.sys;
const proc = common.proc;
const pytext = common.pytext;
const logs = common.logs;
const flate = std.compress.flate;
const json = common.json;
const env = common.env;
const cli = common.cli;

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

/// `atomic` mode: atomicWrite, replaceContents and appendLine cases on
/// the fixture the test created around the probe's working directory.
fn atomicMode() void {
    const dir = fsx.openDir(fsx.cwd, ".", false) catch unreachable;
    defer sys.close(dir);
    const aw_cases = [_]struct { name: []const u8, data: []const u8, opts: common.atomic.WriteOptions }{
        .{ .name = "aw-new", .data = "new content\n", .opts = .{} },
        .{ .name = "aw-keep", .data = "replaced\n", .opts = .{} },
        .{ .name = "aw-link", .data = "x\n", .opts = .{} },
        .{ .name = "ro/aw-new", .data = "x\n", .opts = .{} },
        .{ .name = "aw-mode", .data = "m\n", .opts = .{ .mode = 0o600 } },
    };
    for (aw_cases) |c| {
        var why: common.atomic.Why = .{};
        const result = common.atomic.atomicWrite(A, c.name, c.data, c.opts, &why);
        if (result) |_| {
            emit(&.{ "atomicwrite", hexOf(c.name), "OK", hexOf(why.msg) });
        } else |e| {
            const status = std.fmt.allocPrint(A, "ERR:{s}", .{errName(e)}) catch unreachable;
            emit(&.{ "atomicwrite", hexOf(c.name), status, hexOf(why.msg) });
        }
        why.deinit(A);
    }
    const rc_cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "rc-keep", .data = "replaced\n" },
        .{ .name = "rc-missing", .data = "x\n" },
        .{ .name = "rc-link", .data = "x\n" },
        .{ .name = "ro/rc-keep", .data = "x\n" },
    };
    for (rc_cases) |c| {
        opLine("replacecontents", c.name, fsx.replaceContents(A, dir, c.name, c.data));
    }
    const ap_cases = [_]struct { name: []const u8, line: []const u8 }{
        .{ .name = "ap-new", .line = "fresh line" },
        .{ .name = "ap-exist", .line = "second" },
        .{ .name = "ap-link", .line = "x" },
        .{ .name = "ro/ap-new", .line = "x" },
        .{ .name = "ap-fifo", .line = "x" },
    };
    for (ap_cases) |c| {
        opLine("appendline", c.name, fsx.appendLine(A, dir, c.name, c.line));
    }
}

/// One atomicWrite, including the full failure text. `why.msg` is copied
/// into the output before it is freed.
fn writeFail(name: []const u8, path: []const u8, data: []const u8, opts: common.atomic.WriteOptions) void {
    var why: common.atomic.Why = .{};
    const result = common.atomic.atomicWrite(A, path, data, opts, &why);
    const status = if (result) |_|
        "OK"
    else |e|
        std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable;
    emit(&.{ "osfail", name, status, hexOf(why.msg) });
    why.deinit(A);
}

/// A write that the file-size limit stops. Python's os.write names no
/// file for that OSError, and neither does atomicWrite. A flush of a
/// regular file cannot be made to fail from this process, so the write
/// is the no-filename failure the probe can raise.
fn writeTooBig() void {
    var old: linux.rlimit = undefined;
    if (linux.errno(linux.prlimit(0, .FSIZE, null, &old)) != .SUCCESS) {
        emit(&.{ "osfail", "write-fsize", "SKIP", "" });
        return;
    }
    const unlimited = std.math.maxInt(u64);
    const room: u64 = if (old.max == unlimited) 8 else old.max;
    if (room < 8) {
        emit(&.{ "osfail", "write-fsize", "SKIP", "" });
        return;
    }
    const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.XFSZ, &ign, &prev);
    defer _ = linux.sigaction(.XFSZ, &prev, null);
    const lim: linux.rlimit = .{ .cur = 8, .max = old.max };
    if (linux.errno(linux.prlimit(0, .FSIZE, &lim, null)) != .SUCCESS) {
        emit(&.{ "osfail", "write-fsize", "SKIP", "" });
        return;
    }
    defer _ = linux.prlimit(0, .FSIZE, &old, null);
    var payload: [64]u8 = @splat('x');
    writeFail("write-fsize", "fsize-out", &payload, .{});
}

fn chmodAt(path: []const u8, mode: linux.mode_t) void {
    var zb: [sys.path_max:0]u8 = undefined;
    const z = sys.z(&zb, path) catch unreachable;
    if (linux.errno(linux.fchmodat(fsx.cwd, z.ptr, mode)) != .SUCCESS) unreachable;
}

/// `osfail` mode: real atomicWrite failures whose text is Python's
/// OSError for the same operation. The fixture is created here, in the
/// working directory, and any directory made unwritable is restored
/// before returning so the caller can remove the tree.
fn osFailMode() void {
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, "ro") catch unreachable).ptr, 0o755);
    if (linux.geteuid() == 0) {
        emit(&.{ "osfail", "open-ro", "SKIP", "" });
        emit(&.{ "osfail", "mkdir-ro", "SKIP", "" });
    } else {
        chmodAt("ro", 0o555);
        defer chmodAt("ro", 0o755);
        // open of the temporary file, which Python names rather than the
        // destination
        writeFail("open-ro", "ro/new", "x\n", .{});
        // mkdir of the first missing ancestor, not the leaf that was asked for
        writeFail("mkdir-ro", "ro/a/b/file", "x\n", .{});
    }

    _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, "adir") catch unreachable).ptr, 0o755);
    const meta = sys.openat(fsx.cwd, "meta", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644) catch unreachable;
    sys.writeAll(meta, "m\n") catch unreachable;
    sys.close(meta);
    // metadata comes from a regular file, so the directory at the
    // destination is reached by rename rather than refused as a source
    writeFail("rename-dir", "adir", "data\n", .{ .metadata_from = "meta" });

    _ = linux.symlinkat("nowhere", fsx.cwd, (sys.z(&zb, "gone") catch unreachable).ptr);
    writeFail("missing-ancestor", "gone/a/b/file", "x\n", .{});
    writeTooBig();
}

fn lockCase(name: []const u8, root: []const u8) void {
    if (state.RootLock.acquire(A, root, 0)) |held| {
        held.release();
        emit(&.{ "rootlock", name, "OK", "", "" });
    } else |e| {
        const status = std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable;
        if (state.osFailure()) |failure| {
            emit(&.{ "rootlock", name, status, hexOf(failure.text), hexOf(failure.path) });
        } else {
            emit(&.{ "rootlock", name, status, "NONE", "NONE" });
        }
    }
}

/// `rootlock` mode: RootLock.acquire failures. Text and path are the
/// osFailure snapshot; NONE means the failure was not an OS error and
/// the snapshot was cleared.
fn rootLockMode() void {
    var zb: [sys.path_max:0]u8 = undefined;
    const file = sys.openat(fsx.cwd, "fileroot", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644) catch unreachable;
    sys.close(file);
    lockCase("file-root", "fileroot");

    _ = linux.symlinkat("nowhere", fsx.cwd, (sys.z(&zb, "dangling") catch unreachable).ptr);
    lockCase("dangling-root", "dangling");

    _ = linux.symlinkat("nowhere", fsx.cwd, (sys.z(&zb, "gone") catch unreachable).ptr);
    lockCase("ancestor", "gone/a/b");

    if (linux.geteuid() == 0) {
        emit(&.{ "rootlock", "gate-ro", "SKIP", "", "" });
        emit(&.{ "rootlock", "sidecar-ro", "SKIP", "", "" });
    } else {
        _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, "gate") catch unreachable).ptr, 0o755);
        chmodAt("gate", 0o555);
        defer chmodAt("gate", 0o755);
        lockCase("gate-ro", "gate");

        _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, "side") catch unreachable).ptr, 0o755);
        const side = sys.openat(fsx.cwd, "side/.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600) catch unreachable;
        sys.close(side);
        chmodAt("side", 0o555);
        defer chmodAt("side", 0o755);
        lockCase("sidecar-ro", "side");
    }

    // a directory planted at the gate is refused without an OSError, and
    // only after the cases above have recorded one, so a stale snapshot
    // would show up here
    _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, "gatedir") catch unreachable).ptr, 0o755);
    _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, "gatedir/.lock") catch unreachable).ptr, 0o755);
    lockCase("gate-dir", "gatedir");
}

/// `which` mode: whichShutil over a PATH fixture the test built around
/// the probe's working directory, plus the unset-PATH cases.
fn whichMode() void {
    const names = [_][]const u8{ "good.sh", "plain.txt", "sym-good.sh", "dangling.sh", "dir.sh", "abs.sh", "missing.sh", "sub/rel.sh" };
    const paths = [_][]const u8{ "binA", "binA:binB", "binB:binA", "", ":", "binA:", ":binA", "binA:./sub" };
    for (paths) |p| {
        for (names) |n| {
            if (proc.whichShutil(A, n, p) catch unreachable) |got| {
                emit(&.{ "whichshutil", hexOf(p), hexOf(n), hexOf(got) });
            } else {
                emit(&.{ "whichshutil", hexOf(p), hexOf(n), "NULL" });
            }
        }
    }
    const unset_names = [_][]const u8{ "sh", "missing.sh" };
    for (unset_names) |n| {
        if (proc.whichShutil(A, n, null) catch unreachable) |got| {
            emit(&.{ "whichshutil-unset", hexOf(n), hexOf(got) });
        } else {
            emit(&.{ "whichshutil-unset", hexOf(n), "NULL" });
        }
    }
}

/// `diag` mode: reprStr strings and osErrorErrno messages, the error
/// text every tool prints where Python printed str(OSError).
fn diagMode() void {
    const texts = [_][]const u8{
        "plain",              "it's",    "a'b\"c",      "a\\b",       "space path",
        "\t\n\r\x01\x1f\x7f", "caf\xe9", "caf\xc3\xa9", "\xff\xfe",   "a\xffb",
        "\xc2\xa0\xc2\xad",   "",        ".",           "..",         "x/y",
        "EESSI/2026.06",      "$HOME",   "`tick`",      "semi;colon",
    };
    for (texts) |t| {
        const r = pytext.reprStrAlloc(A, t) catch unreachable;
        emit(&.{ "repr", hexOf(t), hexOf(r) });
    }
    const errnos = [_]u32{ 2, 13, 1, 20, 17, 36, 28, 18, 22, 5 };
    const paths = [_][]const u8{ "/no/such", "a\xffb", "it's", "dir\x01ctl", "caf\xe9" };
    for (errnos) |e| {
        for (paths) |p| {
            const msg = pytext.osErrorErrno(A, @fromBackingInt(@intCast(e)), p) catch unreachable;
            emit(&.{ "oserror", std.fmt.allocPrint(A, "{d}", .{e}) catch unreachable, hexOf(p), hexOf(msg) });
        }
    }
}

/// `gzip` mode: gzipInPlace over the fixture file in the working
/// directory; the test compresses the same fixture with gzip itself and
/// compares the effects.
fn gzipMode() void {
    const dir = fsx.openDir(fsx.cwd, ".", false) catch unreachable;
    defer sys.close(dir);
    const io = std.Io.Threaded.global_single_threaded.io();
    if (logs.gzipInPlace(A, io, dir, "run.1234.log")) |_| {
        emit(&.{ "gzip", "OK" });
    } else |e| {
        emit(&.{ "gzip", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable });
    }
}

/// `envcli` mode: the environment parsing and builder edge cases and
/// the CLI exit code, compared with what a Python child sees from the
/// same environ block and with argparse's error exit.
fn envCliMode() void {
    const block = [_:null]?[*:0]const u8{ "A=1", "NOEQ", "B=x=y", "A=2", "E=", "B=late" };
    const e = env.Env.fromEnvp(&block);

    // the block itself, so the test can recompute from the same input
    var joined: std.ArrayList(u8) = .empty;
    for (block) |entry_o| {
        const entry = entry_o orelse break;
        if (joined.items.len > 0) joined.append(A, 1) catch unreachable;
        joined.appendSlice(A, std.mem.span(entry)) catch unreachable;
    }
    emit(&.{ "env-block", hexOf(joined.items) });

    // Env.get: the first entry wins, as a getenv-walking child sees it
    const names = [_][]const u8{ "A", "B", "E", "NOEQ", "MISSING", "", "B=" };
    for (names) |n| {
        if (e.get(n)) |v| {
            emit(&.{ "env-get", hexOf(n), hexOf(v) });
        } else {
            emit(&.{ "env-get", hexOf(n), "NULL" });
        }
    }

    // Builder: order kept, a set replaces in place, an unset removes;
    // the ops are emitted so the test can replay them
    var b = env.Builder.fromEnv(A, e) catch unreachable;
    b.set("D", "") catch unreachable;
    b.set("A", "replaced") catch unreachable;
    b.unset("E");
    b.set("F", "with=equals") catch unreachable;
    emit(&.{ "builder-op", "set", hexOf("D"), hexOf("") });
    emit(&.{ "builder-op", "set", hexOf("A"), hexOf("replaced") });
    emit(&.{ "builder-op", "unset", hexOf("E") });
    emit(&.{ "builder-op", "set", hexOf("F"), hexOf("with=equals") });
    const built = b.envp() catch unreachable;
    var out_block: std.ArrayList(u8) = .empty;
    var bi: usize = 0;
    while (built[bi] != null) : (bi += 1) {
        const entry = built[bi].?;
        if (out_block.items.len > 0) out_block.append(A, 1) catch unreachable;
        out_block.appendSlice(A, std.mem.span(entry)) catch unreachable;
    }
    emit(&.{ "builder-block", hexOf(out_block.items) });

    // names execve cannot carry are refused
    const bad_cases = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "", .value = "x" },
        .{ .name = "A=B", .value = "x" },
        .{ .name = "OK", .value = "x\x00y" },
    };
    for (bad_cases) |c| {
        var bad = env.Builder.init(A);
        bad.set(c.name, c.value) catch unreachable;
        if (bad.envp()) |_| {
            emit(&.{ "builder-bad", hexOf(c.name), hexOf(c.value), "OK" });
        } else |err| {
            emit(&.{ "builder-bad", hexOf(c.name), hexOf(c.value), std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(err)}) catch unreachable });
        }
    }

    // validName, the shell's assignment-name rule
    const name_cases = [_][]const u8{ "_A1", "1A", "A-B", "", "z", "A9_b" };
    for (name_cases) |n| {
        emit(&.{ "valid-name", hexOf(n), if (env.validName(n)) "1" else "0" });
    }

    emit(&.{ "usage-exit", std.fmt.allocPrint(A, "{d}", .{cli.usage_exit}) catch unreachable });
}

/// `errno` mode: describeErrno and errnoText for every errno the
/// kernel names on this platform, and the [Errno N] framing over tricky
/// paths, compared with os.strerror and the str of an OSError.
fn errnoMode() void {
    var n: u16 = 0;
    while (n <= 150) : (n += 1) {
        const e: linux.E = @fromBackingInt(n);
        const num = std.fmt.allocPrint(A, "{d}", .{n}) catch unreachable;
        emit(&.{ "errno-desc", num, hexOf(sys.describeErrno(e)) });
        if (sys.errnoText(e)) |t| {
            emit(&.{ "errno-text", num, hexOf(t) });
        } else {
            emit(&.{ "errno-text", num, "NULL" });
        }
    }
    // the errnos the mapped errors surface, over tricky paths
    const frame_errnos = [_]u32{ 1, 2, 5, 11, 13, 17, 18, 20, 21, 26, 27, 28, 30, 32, 36, 38, 40, 8 };
    const frame_paths = [_][]const u8{ "/no/such", "it's \"quoted\"", "a\xffb", "line\nbreak\ttab", "caf\xe9", "back\\slash" };
    for (frame_errnos) |num| {
        for (frame_paths) |p| {
            const msg = pytext.osErrorErrno(A, @fromBackingInt(@intCast(num)), p) catch unreachable;
            emit(&.{ "errno-frame", std.fmt.allocPrint(A, "{d}", .{num}) catch unreachable, hexOf(p), hexOf(msg) });
        }
    }
}

/// `copyedges` mode: copyTo and moveAcross edge cases the test set up
/// around the probe's working directory and on a second device under
/// /dev/shm: cross-device moves, a read-only destination, a symlinked
/// destination, a write the file-size limit stops, and a source removed
/// after its descriptor was opened.
fn copyEdgesMode() void {
    const shm = "/dev/shm/zc-parity-copyedges-probe";
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (sys.z(&zb, shm) catch unreachable).ptr, 0o755);

    const shm_dir = fsx.openDir(fsx.cwd, shm, false) catch unreachable;
    defer sys.close(shm_dir);

    // the fixture inside the second device: a victim the link points
    // at, the link itself, and a read-only directory
    const victim_fd = sys.openat(shm_dir, "victim", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch unreachable;
    sys.writeAll(victim_fd, "keep me\n") catch unreachable;
    sys.close(victim_fd);
    _ = linux.symlinkat("victim", shm_dir, (sys.z(&zb, "moved-link") catch unreachable).ptr);
    _ = linux.mkdirat(shm_dir, (sys.z(&zb, "ro") catch unreachable).ptr, 0o755);
    {
        const ro_z = sys.z(&zb, "ro") catch unreachable;
        _ = linux.fchmodat(shm_dir, ro_z.ptr, 0o555);
    }

    const dir = fsx.openDir(fsx.cwd, ".", false) catch unreachable;
    defer sys.close(dir);
    const ro_dir = fsx.openDir(fsx.cwd, "ro", false) catch unreachable;
    defer sys.close(ro_dir);

    const case = struct {
        fn emitCase(name: []const u8, result: []const u8) void {
            emit(&.{ "copyedges", hexOf(name), result });
        }
    };

    // copyTo into a read-only directory
    {
        const src = fsx.openRegular(fsx.cwd, "src", false) catch unreachable;
        defer sys.close(src.fd);
        const out = fsx.copyTo(src.fd, src.stat, ro_dir, "new");
        if (out) |fd| {
            sys.close(fd);
            case.emitCase("copy-ro", "OK");
        } else |e| {
            case.emitCase("copy-ro", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }

    // copyTo onto a symlink: the documented refusal
    {
        const src = fsx.openRegular(fsx.cwd, "src", false) catch unreachable;
        defer sys.close(src.fd);
        const out = fsx.copyTo(src.fd, src.stat, dir, "dst-link");
        if (out) |fd| {
            sys.close(fd);
            case.emitCase("copy-link", "OK");
        } else |e| {
            case.emitCase("copy-link", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }

    // moveAcross over EXDEV: the copy fallback publishes and removes
    {
        const result = fsx.moveAcross(A, dir, "src", shm_dir, "moved", .{});
        if (result) |_| {
            case.emitCase("move-exdev", "OK");
        } else |e| {
            case.emitCase("move-exdev", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }

    // moveAcross over EXDEV into the read-only directory
    {
        const result = fsx.moveAcross(A, dir, "victim2", shm_dir, "ro/moved", .{});
        if (result) |_| {
            case.emitCase("move-exdev-ro", "OK");
        } else |e| {
            case.emitCase("move-exdev-ro", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }

    // moveAcross over EXDEV onto a symlink replaces it, as os.replace
    {
        const result = fsx.moveAcross(A, dir, "victim2", shm_dir, "moved-link", .{});
        if (result) |_| {
            case.emitCase("move-exdev-link", "OK");
        } else |e| {
            case.emitCase("move-exdev-link", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }

    // a write the file-size limit stops keeps the old bytes
    {
        const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        var prev: linux.Sigaction = undefined;
        _ = linux.sigaction(.XFSZ, &ign, &prev);
        defer _ = linux.sigaction(.XFSZ, &prev, null);
        var old: linux.rlimit = undefined;
        if (linux.errno(linux.prlimit(0, .FSIZE, null, &old)) != .SUCCESS) unreachable;
        const lim: linux.rlimit = .{ .cur = 8, .max = old.max };
        if (linux.errno(linux.prlimit(0, .FSIZE, &lim, null)) != .SUCCESS) unreachable;
        defer _ = linux.prlimit(0, .FSIZE, &old, null);
        const src = fsx.openRegular(fsx.cwd, "fsize-src", false) catch unreachable;
        defer sys.close(src.fd);
        const out = fsx.copyTo(src.fd, src.stat, dir, "fsize-dst");
        if (out) |fd| {
            sys.close(fd);
            case.emitCase("copy-fsize", "OK");
        } else |e| {
            case.emitCase("copy-fsize", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }

    // a source removed after its descriptor was opened copies in full
    {
        const src = fsx.openRegular(fsx.cwd, "unlink-src", false) catch unreachable;
        defer sys.close(src.fd);
        sys.unlinkat(fsx.cwd, "unlink-src", 0) catch unreachable;
        const out = fsx.copyTo(src.fd, src.stat, dir, "unlinked-dst");
        if (out) |fd| {
            sys.close(fd);
            case.emitCase("copy-unlinked", "OK");
        } else |e| {
            case.emitCase("copy-unlinked", std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable);
        }
    }
}

/// `gunzip` mode: the reader over a corpus built at run time, compared
/// with Python's gzip module and GNU gzip.
fn gunzipMode() void {
    const window = A.alloc(u8, flate.max_window_len) catch unreachable;
    var data: [320]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 7) % 251);

    // a member the library's own writer made
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(A, 64) catch unreachable;
    {
        var c = flate.Compress.init(&aw.writer, window, .gzip, .best) catch unreachable;
        c.writer.writeAll(&data) catch unreachable;
        c.finish() catch unreachable;
    }
    const written = aw.written();
    gzCase("plain", written, 1 << 30);
    gzCase("limit", written, 8);

    // members with each header flag, built by hand over raw deflate
    const flag_sets = [_]struct { name: []const u8, extra: ?[]const u8 = null, fname: ?[]const u8 = null, comment: ?[]const u8 = null, fhcrc: bool = false, break_fhcrc: bool = false }{
        .{ .name = "fname", .fname = "log.txt" },
        .{ .name = "extra", .extra = "EX" },
        .{ .name = "comment", .comment = "a note" },
        .{ .name = "fhcrc", .fhcrc = true },
        .{ .name = "allflags", .extra = "ab", .fname = "f", .comment = "c", .fhcrc = true },
        .{ .name = "bad-fhcrc", .fhcrc = true, .break_fhcrc = true },
    };
    for (flag_sets) |fs| {
        const member = gzMember(&data, fs.extra, fs.fname, fs.comment, fs.fhcrc, fs.break_fhcrc, window);
        gzCase(fs.name, member, 1 << 30);
    }

    // damaged and edge shapes over the writer's member
    const plain_member = written;
    {
        const multi = std.mem.concat(A, u8, &.{ plain_member, plain_member }) catch unreachable;
        gzCase("multi", multi, 1 << 30);
        const zeros16: [16]u8 = @splat(0);
        const padded = std.mem.concat(A, u8, &.{ multi, &zeros16 }) catch unreachable;
        gzCase("padded-multi", padded, 1 << 30);
        const empty_tail = gzMember(&([_]u8{}), null, null, null, false, false, window);
        const with_empty = std.mem.concat(A, u8, &.{ plain_member, empty_tail }) catch unreachable;
        gzCase("empty-member", with_empty, 1 << 30);
    }
    {
        const bad = A.dupe(u8, plain_member) catch unreachable;
        bad[bad.len - 6] ^= 0xff;
        gzCase("bad-crc", bad, 1 << 30);
    }
    {
        const bad = A.dupe(u8, plain_member) catch unreachable;
        bad[bad.len - 1] ^= 0x01;
        gzCase("bad-isize", bad, 1 << 30);
    }
    gzCase("truncated-half", plain_member[0 .. plain_member.len / 2], 1 << 30);
    gzCase("truncated-header", plain_member[0..6], 1 << 30);
    gzCase("not-gzip", "not gzip at all", 1 << 30);
    {
        const zeros16b: [16]u8 = @splat(0);
        const zeros = std.mem.concat(A, u8, &.{ plain_member, &zeros16b }) catch unreachable;
        gzCase("trailing-zeros", zeros, 1 << 30);
    }
    {
        const junk = std.mem.concat(A, u8, &.{ plain_member, "junkjunk" }) catch unreachable;
        gzCase("trailing-junk", junk, 1 << 30);
    }
    {
        const second = gzMember("second\n", null, null, null, false, false, window);
        const multi = std.mem.concat(A, u8, &.{ plain_member, second }) catch unreachable;
        const bad = A.dupe(u8, multi) catch unreachable;
        bad[bad.len - 6] ^= 0xff;
        gzCase("second-bad-crc", bad, 1 << 30);
    }
}

fn gzCase(name: []const u8, blob: []const u8, limit: usize) void {
    const num = std.fmt.allocPrint(A, "{d}", .{limit}) catch unreachable;
    if (logs.gunzip(A, blob, limit)) |out| {
        emit(&.{ "gunzip", hexOf(name), num, hexOf(blob), "OK", hexOf(out) });
    } else |e| {
        emit(&.{ "gunzip", hexOf(name), num, hexOf(blob), std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable });
    }
}

/// One gzip member over `data` with the given header parts, built by
/// hand over a raw deflate stream so every flag can appear; with
/// `break_fhcrc` the FHCRC value is wrong on purpose.
fn gzMember(data: []const u8, extra: ?[]const u8, fname: ?[]const u8, comment: ?[]const u8, fhcrc: bool, break_fhcrc: bool, window: []u8) []const u8 {
    var body_aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(A, 64) catch unreachable;
    var c = flate.Compress.init(&body_aw.writer, window, .raw, .best) catch unreachable;
    c.writer.writeAll(data) catch unreachable;
    c.finish() catch unreachable;

    var flags: u8 = 0;
    if (extra != null) flags |= 0x04;
    if (fname != null) flags |= 0x08;
    if (comment != null) flags |= 0x10;
    if (fhcrc) flags |= 0x02;

    var hdr: std.ArrayList(u8) = .empty;
    hdr.appendSlice(A, &[_]u8{ 0x1f, 0x8b, 8, flags, 0, 0, 0, 0, 2, 3 }) catch unreachable;
    if (extra) |e| {
        hdr.append(A, @intCast(e.len)) catch unreachable;
        hdr.append(A, 0) catch unreachable;
        hdr.appendSlice(A, e) catch unreachable;
    }
    if (fname) |f| {
        hdr.appendSlice(A, f) catch unreachable;
        hdr.append(A, 0) catch unreachable;
    }
    if (comment) |cm| {
        hdr.appendSlice(A, cm) catch unreachable;
        hdr.append(A, 0) catch unreachable;
    }
    if (fhcrc) {
        const crc16: u16 = if (break_fhcrc) 0xbeef else @truncate(std.hash.Crc32.hash(hdr.items));
        hdr.append(A, @intCast(crc16 & 0xff)) catch unreachable;
        hdr.append(A, @intCast(crc16 >> 8)) catch unreachable;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(A, hdr.items) catch unreachable;
    out.appendSlice(A, body_aw.written()) catch unreachable;
    var tail: [8]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, tail[4..8], @truncate(data.len), .little);
    out.appendSlice(A, &tail) catch unreachable;
    return out.items;
}

fn jsonFuzzMode() void {
    var prng = std.Random.DefaultPrng.init(0xC0DE_5EED);
    const rand = prng.random();

    const edges = [_][]const u8{
        "{\"k\": \"\\ud83d\\ude00\"}",
        "{\"k\": \"\\ud800\"}",
        "{\"k\": \"\\udc80\"}",
        "{\"k\": \"\\ud800\\ud800\"}",
        "{\"k\": \"\\udbff\\udfff\"}",
        "{\"k\": \"a\x80b\"}",
        "{\"k\": \"caf\xe9\"}",
        "{\"k\": \"caf\xc3\xa9\"}",
        "{\"a\": 9223372036854775807, \"k\": \"x\"}",
        "{\"a\": 9223372036854775808, \"k\": \"x\"}",
        "{\"a\": -9223372036854775808, \"k\": \"x\"}",
        "{\"a\": -9223372036854775809, \"k\": \"x\"}",
        "{\"a\": -0, \"k\": \"x\"}",
        "{\"a\": -0.0, \"k\": \"x\"}",
        "{\"a\": 0e0, \"k\": \"x\"}",
        "{\"a\": 1e999, \"k\": \"x\"}",
        "{\"a\": 1E+5, \"k\": \"x\"}",
        "{\"k\": 1, \"k\": 2}",
        "{\"k\": \"first\", \"k\": \"second\"}",
        "[1, 2, 3]",
        "{}",
        "[]",
        "\"bare\"",
        "123",
        "null",
        "true",
        "false",
        "{\"a\": NaN, \"k\": \"x\"}",
        "{\"a\": Infinity, \"k\": \"x\"}",
        "{\"a\": -Infinity, \"k\": \"x\"}",
        "NaN",
        "\xef\xbb\xbf{}",
        "{} trailing",
        "{}{}",
        "{\"k\":}",
        "{\"k\" \"x\"}",
        "{\"k\": \"a\x00b\"}",
        "\"\\u12\"",
        "\"raw\x01ctl\"",
        "01",
        "1.",
        ".5",
        "+1",
        "1e",
    };
    for (edges) |doc| jsonFuzzCase(doc);

    // the nesting limit: 31 and 32 levels parse, 33 and deeper do not
    for ([_]usize{ 31, 32, 33, 2000 }) |depth| {
        var doc: std.ArrayList(u8) = .empty;
        for (0..depth) |_| doc.append(A, '[') catch unreachable;
        doc.append(A, '1') catch unreachable;
        for (0..depth) |_| doc.append(A, ']') catch unreachable;
        jsonFuzzCase(doc.items);
    }

    for (0..150) |_| jsonFuzzCase(randomJsonDoc(rand));
}

fn jsonFuzzCase(doc: []const u8) void {
    const name = std.fmt.allocPrint(A, "{x}", .{doc}) catch unreachable;
    const parsed = json.parse(A, doc);
    if (parsed) |v| {
        emit(&.{ "json-parse", name, "OK" });
        if (json.toPy(A, v)) |py| {
            const out = json.dumps(A, py, 0, false) catch unreachable;
            emit(&.{ "json-topy", name, "OK", hexOf(out) });
            // the strict reader reads the writer's own output back;
            // the Infinity the writer gives a float past the range is
            // the one literal the reader refuses by contract
            const reparsed = json.parse(A, out) catch {
                emit(&.{ "json-roundtrip", name, "ERR:Syntax" });
                return;
            };
            const again = json.toPy(A, reparsed) catch {
                emit(&.{ "json-roundtrip", name, "ERR:Encoding" });
                return;
            };
            const second = json.dumps(A, again, 0, false) catch unreachable;
            if (std.mem.eql(u8, out, second)) {
                emit(&.{ "json-roundtrip", name, "OK" });
            } else {
                emit(&.{ "json-roundtrip", name, "CHANGED" });
            }
        } else |e| {
            emit(&.{ "json-topy", name, std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable });
        }
        const got = v.get("k");
        if (got == null) {
            emit(&.{ "json-get", name, "MISSING" });
        } else switch (got.?) {
            .string => |raw| {
                if (json.decodeCache(A, raw)) |value| {
                    emit(&.{ "json-get", name, "OK", hexOf(value) });
                } else |e| {
                    emit(&.{ "json-get", name, std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable });
                }
            },
            else => emit(&.{ "json-get", name, "OTHER" }),
        }
    } else |e| {
        emit(&.{ "json-parse", name, std.fmt.allocPrint(A, "ERR:{s}", .{@errorName(e)}) catch unreachable });
    }
}

/// A seeded random JSON object whose "k" member is a string, with raw
/// invalid bytes, escapes, surrogate pairs and lone halves, numbers with
/// exponents and fractions, and some nesting.
fn randomJsonDoc(rand: std.Random) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(A, '{') catch unreachable;
    out.appendSlice(A, "\"k\":") catch unreachable;
    randomJsonString(rand, &out);
    var members = rand.uintLessThan(usize, 3);
    while (members > 0) : (members -= 1) {
        out.append(A, ',') catch unreachable;
        const key = "abz"[rand.uintLessThan(usize, 3)];
        out.append(A, '"') catch unreachable;
        out.append(A, key) catch unreachable;
        out.appendSlice(A, "\":") catch unreachable;
        const kind = rand.uintLessThan(usize, 5);
        switch (kind) {
            0 => randomJsonString(rand, &out),
            1 => randomJsonNumber(rand, &out),
            2 => out.appendSlice(A, "true") catch unreachable,
            3 => out.appendSlice(A, "null") catch unreachable,
            else => {
                out.append(A, '[') catch unreachable;
                var inner = rand.uintLessThan(usize, 4);
                while (inner > 0) : (inner -= 1) {
                    if (inner < 3) out.append(A, ',') catch unreachable;
                    randomJsonNumber(rand, &out);
                }
                out.append(A, ']') catch unreachable;
            },
        }
    }
    out.append(A, '}') catch unreachable;
    return out.items;
}

fn randomJsonString(rand: std.Random, out: *std.ArrayList(u8)) void {
    out.append(A, '"') catch unreachable;
    var n = rand.uintLessThan(usize, 13);
    while (n > 0) : (n -= 1) {
        const kind = rand.uintLessThan(usize, 7);
        switch (kind) {
            0 => out.append(A, 'a' + @as(u8, @intCast(rand.uintLessThan(u8, 26)))) catch unreachable,
            1 => out.append(A, 0x80 + @as(u8, @intCast(rand.uintLessThan(u8, 0x80)))) catch unreachable,
            2 => out.appendSlice(A, "\\\"") catch unreachable,
            3 => out.appendSlice(A, "\\n") catch unreachable,
            4 => {
                out.appendSlice(A, "\\u") catch unreachable;
                const cp = rand.uintLessThan(u32, 0x10000);
                var hex: [4]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "{x:0>4}", .{cp}) catch unreachable;
                out.appendSlice(A, &hex) catch unreachable;
            },
            5 => {
                out.appendSlice(A, "\\ud83d\\ude00") catch unreachable;
            },
            else => out.appendSlice(A, "\\ud800") catch unreachable,
        }
    }
    out.append(A, '"') catch unreachable;
}

fn randomJsonNumber(rand: std.Random, out: *std.ArrayList(u8)) void {
    if (rand.boolean()) out.append(A, '-') catch unreachable;
    const digits = 1 + rand.uintLessThan(usize, 9);
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        out.append(A, '0' + @as(u8, @intCast(rand.uintLessThan(u8, 10)))) catch unreachable;
    }
    if (rand.boolean()) {
        out.append(A, '.') catch unreachable;
        var frac = 1 + rand.uintLessThan(usize, 3);
        while (frac > 0) : (frac -= 1) {
            out.append(A, '0' + @as(u8, @intCast(rand.uintLessThan(u8, 10)))) catch unreachable;
        }
    }
    if (rand.boolean()) {
        out.append(A, 'e') catch unreachable;
        if (rand.boolean()) out.append(A, '+') catch unreachable;
        var exp = 1 + rand.uintLessThan(usize, 3);
        while (exp > 0) : (exp -= 1) {
            out.append(A, '0' + @as(u8, @intCast(rand.uintLessThan(u8, 10)))) catch unreachable;
        }
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
    } else if (std.mem.eql(u8, mode, "atomic")) {
        atomicMode();
    } else if (std.mem.eql(u8, mode, "osfail")) {
        osFailMode();
    } else if (std.mem.eql(u8, mode, "rootlock")) {
        rootLockMode();
    } else if (std.mem.eql(u8, mode, "which")) {
        whichMode();
    } else if (std.mem.eql(u8, mode, "diag")) {
        diagMode();
    } else if (std.mem.eql(u8, mode, "gzip")) {
        gzipMode();
    } else if (std.mem.eql(u8, mode, "envcli")) {
        envCliMode();
    } else if (std.mem.eql(u8, mode, "errno")) {
        errnoMode();
    } else if (std.mem.eql(u8, mode, "copyedges")) {
        copyEdgesMode();
    } else if (std.mem.eql(u8, mode, "gunzip")) {
        gunzipMode();
    } else if (std.mem.eql(u8, mode, "jsonfuzz")) {
        jsonFuzzMode();
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
