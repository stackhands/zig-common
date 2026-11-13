//! Running a child program. The program is named by an absolute path, never
//! looked up in a PATH the child's environment might set; `which` does the
//! lookup, in an explicit PATH, beforehand. The child starts with an empty
//! signal mask, default signal handlers and no descriptors above 2, and by
//! default in its own session, so its whole process group can be killed.
//! Input is written and both outputs are read at the same time, so a child
//! that fills one pipe while the other is unread does not deadlock.
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
    /// Bytes written to the child's stdin, which is then closed; null means
    /// stdin is /dev/null.
    stdin: ?[]const u8 = null,
    /// More stdout than this is an error and the child is killed.
    stdout_limit: usize = 1 << 20,
    /// Stderr is captured up to this many bytes and the rest discarded; 0
    /// sends stderr to /dev/null.
    stderr_limit: usize = 0,
    /// Milliseconds before the child's group is killed; null waits without
    /// a limit.
    timeout_ms: ?u32 = 300_000,
    /// Milliseconds between SIGTERM and SIGKILL after the deadline.
    grace_ms: u32 = 2_000,
    /// Start the child in a new session (and process group). Without it the
    /// child stays in this process's group, so a kill of this group reaches
    /// it.
    new_session: bool = true,
    /// Checked whenever the wait is interrupted (a signal handler sets it):
    /// when true, the child's group is killed and `error.Canceled` returned.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Set to the child's process group id while it runs, 0 otherwise, so a
    /// signal handler can kill it. Only with `new_session`.
    pgid_out: ?*std.atomic.Value(i32) = null,
    /// `truncate`: stdout past `stdout_limit` is read and dropped, and the
    /// call goes on; `fail`: it is an error and the child is killed.
    stdout_overflow: enum { fail, truncate } = .fail,
    /// Return once the child exits, whoever else still holds its pipes: its
    /// group is killed, what the pipes already hold is drained (at most 16
    /// reads per stream) and they are closed, so a writer that left the
    /// group gets EPIPE instead of holding the call. Only with `new_session`.
    end_with_leader: bool = false,
    /// After the group is killed, wait (up to 10 s) until no member of it
    /// is alive, so nothing of the child outlives the call. Only with
    /// `new_session`.
    wait_for_group: bool = false,
};

pub const Result = struct {
    term: Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(r: Result, gpa: Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

pub const Error = sys.Error || Allocator.Error || error{ StreamTooLong, TimedOut, Canceled, NotAbsolute };

/// Search `path_env` (colon-separated, an empty entry meaning the current
/// directory, as execvp does) for an executable regular file `name`.
/// Returns an absolute path to it, without resolving symbolic links, or
/// null. A name containing '/' is not looked up.
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
        if (cand[0] == '/') return try gpa.dupe(u8, cand);
        var rb: [sys.path_max]u8 = undefined;
        const dir_abs = fsx.realpath(fsx.cwd, if (dir_raw.len == 0) "." else dir_raw, &rb) catch continue;
        return try std.fs.path.join(gpa, &.{ dir_abs, name });
    }
    return null;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn childExec(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: Envp,
    new_session: bool,
    in_fd: sys.fd_t,
    out_fd: sys.fd_t,
    err_fd: sys.fd_t,
) noreturn {
    if (new_session) _ = linux.setsid();
    const empty = linux.sigemptyset();
    var act: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = empty, .flags = 0 };
    var s: u32 = 1;
    while (s < linux.NSIG) : (s += 1) {
        if (s == @backingInt(linux.SIG.KILL) or s == @backingInt(linux.SIG.STOP)) continue;
        _ = linux.sigaction(@fromBackingInt(@intCast(s)), &act, null);
    }
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    if (linux.errno(linux.dup2(in_fd, 0)) != .SUCCESS) linux.exit_group(127);
    if (linux.errno(linux.dup2(out_fd, 1)) != .SUCCESS) linux.exit_group(127);
    if (linux.errno(linux.dup2(err_fd, 2)) != .SUCCESS) linux.exit_group(127);
    _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
    _ = linux.execve(path, argv, envp);
    linux.exit_group(127);
}

fn decode(status: u32) Term {
    if (status & 0x7f == 0) return .{ .exited = linux.W.EXITSTATUS(status) };
    return .{ .signaled = status & 0x7f };
}

/// Wait up to `ms` (null: no limit) for the child to exit, leaving it
/// unreaped (a zombie still holds its process group id, so the group cannot
/// be reused while it is signalled). True once it has exited.
fn exitedWithin(pid: linux.pid_t, ms: ?i64) bool {
    const until: ?i64 = if (ms) |m| nowMs() + m else null;
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        switch (linux.errno(rc)) {
            .SUCCESS => if (@backingInt(info.signo) != 0) return true,
            .INTR => continue,
            else => return true,
        }
        if (until) |u| if (nowMs() >= u) return false;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
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

/// True while a live (not zombie) process is in process group `pgid`.
fn groupAlive(pgid: linux.pid_t) bool {
    const dir = sys.openat(linux.AT.FDCWD, "/proc", .{ .DIRECTORY = true }, 0) catch return false;
    defer sys.close(dir);
    var dents: [16 * 1024]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dir, &dents, dents.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        var pos: usize = 0;
        while (pos < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(dents[pos..].ptr);
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(dents[pos + @offsetOf(linux.dirent64, "name") ..].ptr)));
            pos += d.reclen;
            if (name.len == 0 or !std.ascii.isDigit(name[0])) continue;
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/stat", .{name}) catch continue;
            const fd = sys.openat(linux.AT.FDCWD, path, .{}, 0) catch continue;
            var buf: [512]u8 = undefined;
            const got = sys.read(fd, &buf) catch 0;
            sys.close(fd);
            const stat = buf[0..got];
            const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
            var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
            const state = fields.next() orelse continue;
            _ = fields.next(); // ppid
            const pgrp = std.fmt.parseInt(linux.pid_t, fields.next() orelse continue, 10) catch continue;
            if (pgrp == pgid and state[0] != 'Z' and state[0] != 'X') return true;
        }
    }
}

/// Wait up to 10 s until group `pgid` has no live member.
fn waitGroupGone(pgid: linux.pid_t) void {
    const until = nowMs() + 10_000;
    while (groupAlive(pgid) and nowMs() < until) {
        kill(pgid, true, .KILL);
        var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
}

fn kill(pid: linux.pid_t, group: bool, sig: linux.SIG) void {
    _ = linux.kill(if (group) -pid else pid, sig);
}

const Pipe = struct { r: sys.fd_t, w: sys.fd_t };

fn pipe() sys.Error!Pipe {
    var p: [2]sys.fd_t = undefined;
    _ = try sys.call(linux.pipe2, .{ &p, linux.O{ .CLOEXEC = true } });
    return .{ .r = p[0], .w = p[1] };
}

fn setNonblock(fd: sys.fd_t) void {
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, fl | (1 << @bitOffsetOf(linux.O, "NONBLOCK")));
}

/// Append `bytes` read from stdout (`i` 1) or stderr (2) within the limits.
fn keep(i: usize, bytes: []const u8, out: *std.ArrayList(u8), err_buf: *std.ArrayList(u8), gpa: Allocator, opts: Options) Error!void {
    if (i == 1) {
        if (out.items.len + bytes.len > opts.stdout_limit) {
            if (opts.stdout_overflow == .fail) return error.StreamTooLong;
            const room = opts.stdout_limit -| out.items.len;
            try out.appendSlice(gpa, bytes[0..@min(bytes.len, room)]);
            return;
        }
        try out.appendSlice(gpa, bytes);
    } else {
        const room = opts.stderr_limit -| err_buf.items.len;
        try err_buf.appendSlice(gpa, bytes[0..@min(bytes.len, room)]);
    }
}

/// Run `exe` (an absolute path) with `argv` (argv[0] included) and `envp`.
pub fn run(gpa: Allocator, exe: []const u8, argv: []const []const u8, envp: Envp, opts: Options) Error!Result {
    if (exe.len == 0 or exe[0] != '/') return error.NotAbsolute;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (std.mem.indexOfScalar(u8, exe, 0) != null) return error.InvalidArgument;
    const zexe = try arena.dupeSentinel(u8, exe, 0);
    const zargv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| {
        if (std.mem.indexOfScalar(u8, a, 0) != null) return error.InvalidArgument;
        zargv[i] = try arena.dupeSentinel(u8, a, 0);
    }

    const devnull = try sys.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(devnull);
    var fds = [_]sys.fd_t{ -1, -1, -1 }; // parent ends: stdin write, stdout read, stderr read
    defer for (fds) |fd| if (fd >= 0) sys.close(fd);
    var child_in: sys.fd_t = devnull;
    var child_err: sys.fd_t = devnull;
    var in_p: ?Pipe = null;
    var err_p: ?Pipe = null;
    if (opts.stdin != null) {
        in_p = try pipe();
        fds[0] = in_p.?.w;
        child_in = in_p.?.r;
    }
    const out_p = try pipe();
    fds[1] = out_p.r;
    if (opts.stderr_limit > 0) {
        err_p = try pipe();
        fds[2] = err_p.?.r;
        child_err = err_p.?.w;
    }

    const fork_rc = try sys.call(linux.fork, .{});
    if (fork_rc == 0) childExec(zexe.ptr, zargv.ptr, envp, opts.new_session, child_in, out_p.w, child_err);
    const pid: linux.pid_t = @intCast(fork_rc);
    if (opts.new_session) {
        if (opts.pgid_out) |p| p.store(pid, .seq_cst);
    }
    defer if (opts.pgid_out) |p| p.store(0, .seq_cst);
    if (in_p) |p| sys.close(p.r);
    sys.close(out_p.w);
    if (err_p) |p| sys.close(p.w);
    if (fds[0] >= 0) setNonblock(fds[0]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(gpa);
    var in_off: usize = 0;
    if (opts.stdin) |s| if (s.len == 0) {
        sys.close(fds[0]);
        fds[0] = -1;
    };

    const deadline: ?i64 = if (opts.timeout_ms) |t| nowMs() + t else null;
    var failure: ?Error = null;
    var buf: [16 * 1024]u8 = undefined;
    loop: while (fds[0] >= 0 or fds[1] >= 0 or fds[2] >= 0) {
        if (opts.cancel) |c| if (c.load(.seq_cst)) {
            failure = error.Canceled;
            break;
        };
        if (opts.end_with_leader and opts.new_session and exitedWithin(pid, 0)) {
            // The child is gone: stop its group, keep what is already in
            // the pipes, and close them under any writer that left it.
            kill(pid, true, .KILL);
            for (fds[1..], 1..) |fd, i| {
                if (fd < 0) continue;
                setNonblock(fd);
                var reads: usize = 0;
                while (reads < 16) : (reads += 1) {
                    const rc = linux.read(fd, &buf, buf.len);
                    if (linux.errno(rc) != .SUCCESS or rc == 0) break;
                    keep(i, buf[0..rc], &out, &err_buf, gpa, opts) catch |e| {
                        failure = e;
                        break;
                    };
                }
                sys.close(fds[i]);
                fds[i] = -1;
            }
            if (fds[0] >= 0) {
                sys.close(fds[0]);
                fds[0] = -1;
            }
            break;
        }
        var wait: i32 = -1;
        if (deadline) |d| {
            const left = d - nowMs();
            if (left <= 0) {
                failure = error.TimedOut;
                break;
            }
            wait = @intCast(@min(left, std.math.maxInt(i32)));
        }
        if (opts.end_with_leader and (wait < 0 or wait > 20)) wait = 20;
        var pfds: [3]linux.pollfd = undefined;
        var which_fd: [3]usize = undefined;
        var n: usize = 0;
        for (fds, 0..) |fd, i| {
            if (fd < 0) continue;
            pfds[n] = .{ .fd = fd, .events = if (i == 0) linux.POLL.OUT else linux.POLL.IN };
            which_fd[n] = i;
            n += 1;
        }
        const prc = linux.poll(&pfds, n, wait);
        switch (linux.errno(prc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => {
                failure = error.Unexpected;
                break;
            },
        }
        for (pfds[0..n], which_fd[0..n]) |p, i| {
            if (p.revents == 0) continue;
            if (i == 0) {
                const s = opts.stdin.?;
                const rc = linux.write(fds[0], s[in_off..].ptr, s.len - in_off);
                switch (linux.errno(rc)) {
                    .SUCCESS => in_off += rc,
                    .AGAIN, .INTR => {},
                    else => in_off = s.len, // EPIPE: the child stopped reading
                }
                if (in_off >= s.len) {
                    sys.close(fds[0]);
                    fds[0] = -1;
                }
                continue;
            }
            const got = sys.read(fds[i], &buf) catch |e| {
                failure = e;
                break :loop;
            };
            if (got == 0) {
                sys.close(fds[i]);
                fds[i] = -1;
                continue;
            }
            keep(i, buf[0..got], &out, &err_buf, gpa, opts) catch |e| {
                failure = e;
                break :loop;
            };
        }
    }

    if (failure == null) {
        const left: ?i64 = if (deadline) |d| @max(d - nowMs(), 0) else null;
        if (!exitedWithin(pid, left)) failure = error.TimedOut;
    }
    if (failure) |err| {
        if (err == error.Canceled) {
            kill(pid, opts.new_session, .KILL);
        } else {
            kill(pid, opts.new_session, .TERM);
            if (!exitedWithin(pid, opts.grace_ms)) kill(pid, opts.new_session, .KILL);
        }
        if (opts.new_session) kill(pid, true, .KILL);
        if (opts.new_session and opts.wait_for_group) waitGroupGone(pid);
        _ = reap(pid);
        return err;
    }
    // Members of the child's group outliving it are not ours to keep; the
    // unreaped leader keeps the group id from being reused until this is sent.
    if (opts.new_session) kill(pid, true, .KILL);
    if (opts.new_session and opts.wait_for_group) waitGroupGone(pid);
    const term = reap(pid);
    const o = try out.toOwnedSlice(gpa);
    errdefer gpa.free(o);
    return .{ .term = term, .stdout = o, .stderr = try err_buf.toOwnedSlice(gpa) };
}

const no_env: Envp = &[_:null]?[*:0]const u8{};

test "run captures stdout, stderr and the exit code" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, "/bin/sh", &.{ "sh", "-c", "echo hi; echo no >&2; exit 3" }, no_env, .{ .stderr_limit = 100 });
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("hi\n", r.stdout);
    try std.testing.expectEqualStrings("no\n", r.stderr);
    try std.testing.expectEqual(@as(u32, 3), r.term.code());
}

test "stdin and both outputs larger than a pipe do not deadlock" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(input);
    @memset(input, 'x');
    const r = try run(gpa, "/bin/sh", &.{ "sh", "-c", "cat; head -c 300000 /dev/zero >&2" }, no_env, .{
        .stdin = input,
        .stdout_limit = 2 << 20,
        .stderr_limit = 1 << 20,
    });
    defer r.deinit(gpa);
    try std.testing.expectEqual(input.len, r.stdout.len);
    try std.testing.expectEqual(@as(usize, 300000), r.stderr.len);
}

test "run kills a child past its deadline" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.TimedOut, run(gpa, "/bin/sh", &.{ "sh", "-c", "sleep 30" }, no_env, .{ .timeout_ms = 200, .grace_ms = 200 }));
}

test "a set cancel flag kills the child" {
    const gpa = std.testing.allocator;
    var flag = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, run(gpa, "/bin/sh", &.{ "sh", "-c", "sleep 30" }, no_env, .{ .cancel = &flag }));
}

test "run refuses a relative program" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAbsolute, run(gpa, "sh", &.{"sh"}, no_env, .{}));
}
