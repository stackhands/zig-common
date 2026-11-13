//! Running a child program. The child starts in its own session with an
//! empty signal mask, default signal handlers and no descriptors above 2;
//! the program is named by an absolute path, never looked up in a PATH the
//! child's environment might set. The child's process group is killed when
//! the deadline passes, and any member left after the child exits is killed
//! too.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");

const Allocator = std.mem.Allocator;
pub const Envp = [*:null]const ?[*:0]const u8;

pub const Term = union(enum) {
    exited: u8,
    signaled: u32,

    /// The shell's view of the status: the exit code, or 128 + signal.
    pub fn code(t: Term) u32 {
        return switch (t) {
            .exited => |c| c,
            .signaled => |s| 128 + s,
        };
    }
};

pub const Options = struct {
    /// More stdout than this is an error and the child is killed.
    stdout_limit: usize = 1 << 20,
    /// Milliseconds before the child's group is sent SIGTERM.
    timeout_ms: u32 = 300_000,
    /// Milliseconds between SIGTERM and SIGKILL.
    grace_ms: u32 = 2_000,
};

pub const Result = struct {
    term: Term,
    stdout: []u8,
};

pub const Error = sys.Error || Allocator.Error || error{ StreamTooLong, TimedOut, NotAbsolute };

/// Search `path_env` (colon-separated, an empty entry meaning the current
/// directory, as the shell does) for an executable regular file `name`.
/// Returns an absolute path, or null.
pub fn which(gpa: Allocator, name: []const u8, path_env: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null or name.len == 0) return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir_raw| {
        const cand = try std.fs.path.join(gpa, &.{ if (dir_raw.len == 0) "." else dir_raw, name });
        defer gpa.free(cand);
        var zb: [sys.path_max:0]u8 = undefined;
        const zc = sys.z(&zb, cand) catch continue;
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, zc.ptr, linux.X_OK, 0)) != .SUCCESS) continue;
        const st = fsx.statAt(fsx.cwd, cand, true) catch continue;
        if (!st.isReg()) continue;
        var rb: [sys.path_max]u8 = undefined;
        const abs = fsx.realpath(fsx.cwd, cand, &rb) catch continue;
        return try gpa.dupe(u8, abs);
    }
    return null;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn childExec(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: Envp, devnull: sys.fd_t, out_w: sys.fd_t) noreturn {
    _ = linux.setsid();
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    var act: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = empty, .flags = 0 };
    var s: u32 = 1;
    while (s < linux.NSIG) : (s += 1) {
        if (s == @backingInt(linux.SIG.KILL) or s == @backingInt(linux.SIG.STOP)) continue;
        _ = linux.sigaction(@fromBackingInt(@intCast(s)), &act, null);
    }
    if (linux.errno(linux.dup2(devnull, 0)) != .SUCCESS) linux.exit_group(127);
    if (linux.errno(linux.dup2(out_w, 1)) != .SUCCESS) linux.exit_group(127);
    if (linux.errno(linux.dup2(devnull, 2)) != .SUCCESS) linux.exit_group(127);
    _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
    _ = linux.execve(path, argv, envp);
    linux.exit_group(127);
}

fn decode(status: u32) Term {
    if (status & 0x7f == 0) return .{ .exited = linux.W.EXITSTATUS(status) };
    return .{ .signaled = status & 0x7f };
}

/// Wait up to `ms` for the child to exit, leaving it unreaped (a zombie
/// still holds its process group id, so the group cannot be reused while
/// it is signalled). True once it has exited.
fn exitedWithin(pid: linux.pid_t, ms: i64) bool {
    const until = nowMs() + ms;
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        switch (linux.errno(rc)) {
            .SUCCESS => if (@backingInt(info.signo) != 0) return true,
            .INTR => continue,
            else => return true,
        }
        if (nowMs() >= until) return false;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
}

fn reap(pid: linux.pid_t) Term {
    while (true) {
        var status: i32 = 0;
        const rc = linux.wait4(pid, &status, 0, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return decode(@bitCast(status)),
            .INTR => continue,
            else => return .{ .signaled = 9 },
        }
    }
}

fn killGroup(pid: linux.pid_t, sig: linux.SIG) void {
    _ = linux.kill(-pid, sig);
}

/// Run `argv` with `envp`, stdin and stderr on /dev/null, and return its
/// stdout and how it ended. `argv[0]` must be an absolute path.
pub fn run(gpa: Allocator, argv: []const []const u8, envp: Envp, opts: Options) Error!Result {
    if (argv.len == 0 or argv[0].len == 0 or argv[0][0] != '/') return error.NotAbsolute;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zargv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| {
        if (std.mem.indexOfScalar(u8, a, 0) != null) return error.InvalidArgument;
        zargv[i] = try arena.dupeSentinel(u8, a, 0);
    }

    const devnull = try sys.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(devnull);
    var pipe: [2]sys.fd_t = undefined;
    _ = try sys.call(linux.pipe2, .{ &pipe, linux.O{ .CLOEXEC = true } });
    var read_end_open = true;
    defer if (read_end_open) sys.close(pipe[0]);

    const fork_rc = try sys.call(linux.fork, .{});
    if (fork_rc == 0) childExec(zargv[0].?, zargv.ptr, envp, devnull, pipe[1]);
    const pid: linux.pid_t = @intCast(fork_rc);
    sys.close(pipe[1]);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const deadline = nowMs() + opts.timeout_ms;
    var failure: ?Error = null;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const left = deadline - nowMs();
        if (left <= 0) {
            failure = error.TimedOut;
            break;
        }
        var pfd = [_]linux.pollfd{.{ .fd = pipe[0], .events = linux.POLL.IN }};
        const prc = linux.poll(&pfd, 1, @intCast(@min(left, std.math.maxInt(i32))));
        switch (linux.errno(prc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => {
                failure = error.Unexpected;
                break;
            },
        }
        if (prc == 0) continue;
        const n = sys.read(pipe[0], &buf) catch |err| {
            failure = err;
            break;
        };
        if (n == 0) break;
        if (out.items.len + n > opts.stdout_limit) {
            failure = error.StreamTooLong;
            break;
        }
        try out.appendSlice(gpa, buf[0..n]);
    }
    sys.close(pipe[0]);
    read_end_open = false;

    if (failure == null and !exitedWithin(pid, @max(deadline - nowMs(), 0))) failure = error.TimedOut;
    if (failure) |err| {
        killGroup(pid, .TERM);
        if (!exitedWithin(pid, opts.grace_ms)) killGroup(pid, .KILL);
        killGroup(pid, .KILL);
        _ = reap(pid);
        return err;
    }
    // Members of the child's group outliving it are not ours to keep; the
    // unreaped leader keeps the group id from being reused until this is sent.
    killGroup(pid, .KILL);
    const term = reap(pid);
    return .{ .term = term, .stdout = try out.toOwnedSlice(gpa) };
}

test "run captures stdout and the exit code" {
    const gpa = std.testing.allocator;
    const envp: Envp = &[_:null]?[*:0]const u8{};
    const r = try run(gpa, &.{ "/bin/sh", "-c", "echo hi; exit 3" }, envp, .{});
    defer gpa.free(r.stdout);
    try std.testing.expectEqualStrings("hi\n", r.stdout);
    try std.testing.expectEqual(@as(u32, 3), r.term.code());
}

test "run kills a child past its deadline" {
    const gpa = std.testing.allocator;
    const envp: Envp = &[_:null]?[*:0]const u8{};
    try std.testing.expectError(error.TimedOut, run(gpa, &.{ "/bin/sh", "-c", "sleep 30" }, envp, .{ .timeout_ms = 200, .grace_ms = 200 }));
}

test "run refuses a relative program" {
    const gpa = std.testing.allocator;
    const envp: Envp = &[_:null]?[*:0]const u8{};
    try std.testing.expectError(error.NotAbsolute, run(gpa, &.{"sh"}, envp, .{}));
}
