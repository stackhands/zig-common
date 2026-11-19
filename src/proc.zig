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
/// The child's environment block, as execve(2) takes it; `env.Builder.envp`
/// makes one.
pub const Envp = [*:null]const ?[*:0]const u8;

/// How the child ended.
pub const Term = union(enum) {
    /// Its exit status, 0 to 255.
    exited: u8,
    /// The number of the signal that killed it.
    signaled: u32,

    /// The shell's view of the status: the exit code, or 128 + signal.
    pub fn code(t: Term) u32 {
        return switch (t) {
            .exited => |c| c,
            .signaled => |s| 128 + s,
        };
    }
};

/// How `run` starts the child and waits for it. By default stdout may be
/// up to 1 MiB, stderr goes to /dev/null, and the child's process group is
/// killed 300 000 ms after the start.
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
    /// signal handler can kill it with `killGroup` or `stopGroup`. It is set
    /// before the child has made the group, which a kill of the group alone
    /// then misses. Only with `new_session`.
    pgid_out: ?*std.atomic.Value(i32) = null,
    /// `truncate`: stdout past `stdout_limit` is read and dropped, and the
    /// call goes on; `fail`: it is an error and the child is killed.
    stdout_overflow: enum { fail, truncate } = .fail,
    /// Return once the child exits, whoever else still holds its pipes: its
    /// group is killed, what the pipes already hold is drained (at most 16
    /// reads of 16 KiB, 256 KiB, per stream; enough for a default 64 KiB
    /// pipe, not for one a writer enlarged with F_SETPIPE_SZ) and they are
    /// closed, so a writer that left the group gets EPIPE instead of holding
    /// the call. Only with `new_session`.
    end_with_leader: bool = false,
    /// After the group is killed, wait (up to 10 s) until no member of it
    /// is alive, so nothing of the child outlives the call. Only with
    /// `new_session`.
    wait_for_group: bool = false,
    /// A failed exec is returned as its errno's error, as Python's Popen
    /// raises OSError, instead of a child that exits 127.
    exec_error: bool = false,
};

/// What `run` returns once the child has ended: how, and what it wrote.
/// The two outputs are allocated from the allocator given to `run`;
/// `deinit` frees them.
pub const Result = struct {
    term: Term,
    /// What the child wrote to stdout, at most `Options.stdout_limit`
    /// bytes.
    stdout: []u8,
    /// What the child wrote to stderr, at most `Options.stderr_limit`
    /// bytes; empty when that is 0.
    stderr: []u8,

    /// Free `stdout` and `stderr`, with the allocator `run` was given.
    pub fn deinit(r: Result, gpa: Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

/// The errors of `run`. Each of the first three kills the child's process
/// group, or with `new_session` false the child, before it is returned:
///
/// - `error.TimedOut`: the child was still running at `Options.timeout_ms`
/// - `error.Canceled`: `Options.cancel` was set
/// - `error.StreamTooLong`: stdout passed `Options.stdout_limit`, with
///   `stdout_overflow` at `.fail`
/// - `error.NotAbsolute`: `exe` does not start with `/`
/// - `error.InvalidArgument`: `exe` or an argument has a NUL byte
/// - `error.NoChild`: the caller ignores SIGCHLD, so the status is lost
///
/// With `Options.exec_error`, a failed exec is its errno's `sys.Error`,
/// such as `error.NotFound` for ENOENT. Otherwise it is a child that
/// exits 127.
pub const Error = sys.Error || Allocator.Error || error{ StreamTooLong, TimedOut, Canceled, NotAbsolute };

/// Search `path_env` (colon-separated, an empty entry meaning the current
/// directory, as execvp does) for an executable regular file `name`.
/// Returns an absolute path to it, without resolving symbolic links, or
/// null. A name containing '/' is not looked up.
pub fn which(gpa: Allocator, name: []const u8, path_env: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.findScalar(u8, name, '/') != null or name.len == 0) return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir_raw| {
        const cand = try std.fs.path.join(gpa, &.{ if (dir_raw.len == 0) "." else dir_raw, name });
        defer gpa.free(cand);
        if (!isExecutableFile(cand)) continue;
        if (cand[0] == '/') return try gpa.dupe(u8, cand);
        var rb: [sys.path_max]u8 = undefined;
        const dir_abs = fsx.realpath(fsx.cwd, if (dir_raw.len == 0) "." else dir_raw, &rb) catch continue;
        return try std.fs.path.join(gpa, &.{ dir_abs, name });
    }
    return null;
}

fn isExecutableFile(path: []const u8) bool {
    var zb: [sys.path_max:0]u8 = undefined;
    const z = sys.z(&zb, path) catch return false;
    if (linux.errno(linux.faccessat(linux.AT.FDCWD, z.ptr, linux.X_OK, 0)) != .SUCCESS) return false;
    const st = fsx.statAt(fsx.cwd, path, true) catch return false;
    return st.isReg();
}

/// Resolve an executable name to an absolute path. A name with '/' is treated
/// as a path and returned as an absolute path when it names an executable
/// regular file; other names are looked up in `path_env`, or in
/// "/bin:/usr/bin" when `path_env` is null.
pub fn resolveExecutable(gpa: Allocator, name: []const u8, path_env: ?[]const u8) Allocator.Error!?[]u8 {
    if (name.len == 0) return null;
    if (std.mem.findScalar(u8, name, '/') == null) return which(gpa, name, path_env orelse "/bin:/usr/bin");

    const abs = if (std.fs.path.isAbsolute(name))
        try gpa.dupe(u8, name)
    else
        try fsx.absPath(gpa, name);
    if (!isExecutableFile(abs)) {
        gpa.free(abs);
        return null;
    }
    return abs;
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
    exec_err_fd: sys.fd_t,
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
    // A source at 0, 1 or 2 (the caller started with that descriptor
    // closed) moves above 2 first: a dup2 onto it would clobber it, and a
    // dup2 onto itself keeps its close-on-exec flag.
    var src = [3]sys.fd_t{ in_fd, out_fd, err_fd };
    for (&src) |*fd| if (fd.* < 3) {
        const moved = linux.fcntl(fd.*, linux.F.DUPFD, 3);
        if (linux.errno(moved) != .SUCCESS) linux.exit_group(127);
        fd.* = @intCast(moved);
    };
    for (src, 0..) |fd, target| {
        if (linux.errno(linux.dup2(fd, @intCast(target))) != .SUCCESS) linux.exit_group(127);
    }
    const keep_fd = exec_err_fd;
    if (keep_fd > 3) _ = linux.close_range(3, @intCast(keep_fd - 1), .{ .UNSHARE = false, .CLOEXEC = false });
    _ = linux.close_range(if (keep_fd >= 3) @intCast(keep_fd + 1) else 3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
    const rc = linux.execve(path, argv, envp);
    if (keep_fd >= 3) {
        const e: u32 = @backingInt(linux.errno(rc));
        _ = linux.write(keep_fd, std.mem.asBytes(&e), 4);
    }
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

/// Reap the child. With SIGCHLD ignored (SIG_IGN or SA_NOCLDWAIT) the
/// kernel has reaped it and its status is gone: `error.NoChild`.
fn reap(pid: linux.pid_t) sys.Error!Term {
    var status: i32 = 0;
    _ = try sys.call(linux.wait4, .{ pid, &status, 0, null });
    return decode(@bitCast(status));
}

/// True while a live (not zombie) process is in process group `pgid`. A
/// /proc read that fails mid-scan answers false, so a wait on this is best
/// effort.
pub fn groupAlive(pgid: linux.pid_t) bool {
    const dir = sys.openat(linux.AT.FDCWD, "/proc", .{ .DIRECTORY = true }, 0) catch return false;
    defer sys.close(dir);
    var dents: [16 * 1024]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dir, &dents, dents.len);
        // EINTR is not a failed scan. Treating it as "nobody is alive"
        // would let waitGroupGone return while the group is still running.
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        var pos: usize = 0;
        while (pos < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(dents[pos..].ptr);
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(dents[pos + @offsetOf(linux.dirent64, "name") ..].ptr)));
            pos += d.reclen;
            if (name.len == 0 or !std.ascii.isDigit(name[0])) continue;
            var path_buf: [64]u8 = undefined;
            const path = std.mem.print(&path_buf, "/proc/{s}/stat", .{name}) catch continue;
            const fd = sys.openat(linux.AT.FDCWD, path, .{}, 0) catch continue;
            var buf: [512]u8 = undefined;
            const got = sys.read(fd, &buf) catch 0;
            sys.close(fd);
            const stat = buf[0..got];
            const close_paren = std.mem.findScalarLast(u8, stat, ')') orelse continue;
            var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
            const state = fields.next() orelse continue;
            _ = fields.next(); // ppid
            const pgrp = std.fmt.parseInt(linux.pid_t, fields.next() orelse continue, 10) catch continue;
            if (pgrp == pgid and state[0] != 'Z' and state[0] != 'X') return true;
        }
    }
}

/// Send `sig` to the process group `pgid` of a child that `run` started in
/// a new session, as `Options.pgid_out` publishes it. The child makes that
/// group with setsid after the fork, so until then there is no such group:
/// the child itself is signalled, as it has started nothing before it
/// execs, and then the group again in case it was made meanwhile. The child
/// is reaped only after pgid_out is cleared, so a published pid is still
/// the child's. A `pgid` of 0 or less does nothing: 0 is pgid_out's "no
/// child", which kill would take for this process's own group. Safe in a
/// signal handler: only kill system calls, and no waiting; `stopGroup`
/// also waits until the group is gone.
pub fn killGroup(pgid: linux.pid_t, sig: linux.SIG) void {
    if (pgid <= 0) return;
    if (linux.errno(linux.kill(-pgid, sig)) != .SRCH) return;
    _ = linux.kill(pgid, sig);
    _ = linux.kill(-pgid, sig);
}

/// `killGroup(pgid, .KILL)`, then wait (up to 10 s) until no member of the
/// group is alive. Only system calls and stack buffers, so a signal handler
/// may call it, with the pgid that `Options.pgid_out` published.
pub fn stopGroup(pgid: linux.pid_t) void {
    if (pgid <= 0) return;
    killGroup(pgid, .KILL);
    waitGroupGone(pgid);
}

/// Wait up to 10 s until group `pgid` has no live member; best effort, as
/// groupAlive is.
fn waitGroupGone(pgid: linux.pid_t) void {
    const until = nowMs() + 10_000;
    while (groupAlive(pgid) and nowMs() < until) {
        killGroup(pgid, .KILL);
        var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
}

/// Signal the child `pid`, or with `group` its process group.
fn kill(pid: linux.pid_t, group: bool, sig: linux.SIG) void {
    if (group) return killGroup(pid, sig);
    _ = linux.kill(pid, sig);
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
/// The caller must not ignore SIGCHLD (SIG_IGN or SA_NOCLDWAIT): the kernel
/// then reaps the child and its status is lost, which is `error.NoChild`.
pub fn run(gpa: Allocator, exe: []const u8, argv: []const []const u8, envp: Envp, opts: Options) Error!Result {
    if (exe.len == 0 or exe[0] != '/') return error.NotAbsolute;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (std.mem.findScalar(u8, exe, 0) != null) return error.InvalidArgument;
    const zexe = try arena.dupeSentinel(u8, exe, 0);
    const zargv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| {
        if (std.mem.findScalar(u8, a, 0) != null) return error.InvalidArgument;
        zargv[i] = try arena.dupeSentinel(u8, a, 0);
    }

    const devnull = try sys.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(devnull);
    var fds = [_]sys.fd_t{ -1, -1, -1 }; // parent ends: stdin write, stdout read, stderr read
    defer for (fds) |fd| if (fd >= 0) sys.close(fd);
    // The child's ends, closed in the parent once the child has them, and
    // on every error before that.
    var child_ends = [_]sys.fd_t{ -1, -1, -1 };
    defer for (child_ends) |fd| if (fd >= 0) sys.close(fd);
    var child_in: sys.fd_t = devnull;
    var child_err: sys.fd_t = devnull;
    if (opts.stdin != null) {
        const p = try pipe();
        fds[0] = p.w;
        child_ends[0] = p.r;
        child_in = p.r;
    }
    const out_p = try pipe();
    fds[1] = out_p.r;
    child_ends[1] = out_p.w;
    if (opts.stderr_limit > 0) {
        const p = try pipe();
        fds[2] = p.r;
        child_ends[2] = p.w;
        child_err = p.w;
    }

    // The write end is close-on-exec and kept at 3 or above, past the
    // child's dup2 targets; a failed exec writes its errno there.
    var exec_p: ?Pipe = null;
    defer if (exec_p) |p| sys.close(p.r);
    if (opts.exec_error) {
        var p = try pipe();
        if (p.w < 3) {
            const moved = sys.call(linux.fcntl, .{ p.w, linux.F.DUPFD_CLOEXEC, @as(usize, 3) }) catch |e| {
                sys.close(p.r);
                sys.close(p.w);
                return e;
            };
            sys.close(p.w);
            p.w = @intCast(moved);
        }
        exec_p = p;
    }

    const fork_rc = sys.call(linux.fork, .{}) catch |e| {
        if (exec_p) |p| sys.close(p.w);
        return e;
    };
    if (fork_rc == 0) childExec(zexe.ptr, zargv.ptr, envp, opts.new_session, child_in, out_p.w, child_err, if (exec_p) |p| p.w else -1);
    const pid: linux.pid_t = @intCast(fork_rc);
    if (opts.new_session) {
        if (opts.pgid_out) |p| p.store(pid, .seq_cst);
    }
    defer if (opts.pgid_out) |p| p.store(0, .seq_cst);
    for (&child_ends) |*fd| if (fd.* >= 0) {
        sys.close(fd.*);
        fd.* = -1;
    };
    if (fds[0] >= 0) setNonblock(fds[0]);
    // Writing stdin to a child that stopped reading raises SIGPIPE, which
    // would end this process; with it ignored the write fails with EPIPE,
    // as in Python, which ignores SIGPIPE at startup. Restored on return.
    var old_pipe: linux.Sigaction = undefined;
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    const pipe_ignored = fds[0] >= 0 and linux.errno(linux.sigaction(.PIPE, &ignore, &old_pipe)) == .SUCCESS;
    defer if (pipe_ignored) {
        _ = linux.sigaction(.PIPE, &old_pipe, null);
    };
    if (exec_p) |p| {
        sys.close(p.w);
        var e: u32 = 0;
        const got = while (true) {
            const rc = linux.read(p.r, std.mem.asBytes(&e), 4);
            if (linux.errno(rc) != .INTR) break if (linux.errno(rc) == .SUCCESS) rc else 0;
        };
        if (got == 4) {
            if (opts.pgid_out) |o| o.store(0, .seq_cst);
            _ = reap(pid) catch null;
            _ = try sys.result(@bitCast(-@as(isize, @intCast(e))));
            return error.Unexpected;
        }
    }

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
            killGroup(pid, .KILL);
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
        if (opts.new_session) killGroup(pid, .KILL);
        if (opts.new_session and opts.wait_for_group) waitGroupGone(pid);
        if (opts.pgid_out) |o| o.store(0, .seq_cst);
        _ = reap(pid) catch null;
        return err;
    }
    // Members of the child's group outliving it are not ours to keep; the
    // unreaped leader keeps the group id from being reused until this is sent.
    if (opts.new_session) killGroup(pid, .KILL);
    if (opts.new_session and opts.wait_for_group) waitGroupGone(pid);
    if (opts.pgid_out) |o| o.store(0, .seq_cst);
    const term = try reap(pid);
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

var usr1_caught = std.atomic.Value(u32).init(0);

fn onUsr1Proc(_: linux.SIG) callconv(.c) void {
    _ = usr1_caught.fetchAdd(1, .monotonic);
}

test "groupAlive stays true for a live group while signals arrive" {
    const handler: linux.Sigaction = .{ .handler = .{ .handler = &onUsr1Proc }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.USR1, &handler, &prev);
    defer _ = linux.sigaction(.USR1, &prev, null);
    const Stop = struct {
        var go = std.atomic.Value(bool).init(true);
        fn buzz() void {
            // This thread must not catch SIGUSR1, or the signal may interrupt
            // it instead of the scan.
            var blocked = linux.sigemptyset();
            linux.sigaddset(&blocked, .USR1);
            _ = linux.sigprocmask(linux.SIG.BLOCK, &blocked, null);
            // Without the pause a signal is always pending, the scan takes
            // one after every system call, and the checks below take a
            // minute on more than one CPU.
            while (go.load(.acquire)) {
                _ = linux.kill(linux.getpid(), .USR1);
                var ts: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
            }
        }
    };
    Stop.go.store(true, .release);
    const buzz = try std.Thread.spawn(.{}, Stop.buzz, .{});
    defer {
        Stop.go.store(false, .release);
        buzz.join();
    }
    const pgid: linux.pid_t = @intCast(linux.getpgid(0));
    // At least 50 checks, and on until 10 have caught a signal mid-scan, so
    // the test fails rather than passes when no signal lands.
    const until = nowMs() + 10_000;
    var checks: usize = 0;
    var interrupted: usize = 0;
    while (checks < 50 or (interrupted < 10 and nowMs() < until)) : (checks += 1) {
        const caught = usr1_caught.load(.monotonic);
        try std.testing.expect(groupAlive(pgid));
        if (usr1_caught.load(.monotonic) != caught) interrupted += 1;
    }
    try std.testing.expect(interrupted >= 10);
}

test "run refuses a relative program" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAbsolute, run(gpa, "sh", &.{"sh"}, no_env, .{}));
}

/// Run `body` in a forked child, which may close the descriptors the test
/// runner talks over, and expect it to exit 0.
fn expectChildPasses(comptime body: fn () u8) !void {
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) return error.Unexpected;
    if (pid == 0) linux.exit_group(body());
    var status: i32 = 0;
    while (linux.errno(linux.wait4(@intCast(pid), &status, 0, null)) == .INTR) {}
    try std.testing.expectEqual(Term{ .exited = 0 }, decode(@bitCast(status)));
}

/// 0 when `script` under /bin/sh prints `want`, 1 when it prints something
/// else, 2 when it cannot be run.
fn shPrints(script: []const u8, stdin: ?[]const u8, want: []const u8) u8 {
    const r = run(std.heap.page_allocator, "/bin/sh", &.{ "sh", "-c", script }, no_env, .{ .stdin = stdin }) catch return 2;
    if (std.mem.eql(u8, r.stdout, want)) return 0;
    std.debug.print("stdout \"{s}\", want \"{s}\"\n", .{ r.stdout, want });
    return 1;
}

const ExecFixture = struct {
    base: []u8,
    exe_path: []u8,
    plain_path: []u8,
};

fn makeExecFixture(gpa: Allocator, tag: []const u8) (sys.Error || Allocator.Error)!ExecFixture {
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/zig-common-proc-fixture-{s}-{d}", .{ here, tag, linux.getpid() });
    errdefer gpa.free(base);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);

    const exe_path = try std.fs.path.join(gpa, &.{ base, "tool.sh" });
    errdefer gpa.free(exe_path);
    const exe_fd = try sys.openat(fsx.cwd, exe_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
    defer sys.close(exe_fd);
    try sys.writeAll(exe_fd, "#!/bin/sh\nexit 0\n");

    const plain_path = try std.fs.path.join(gpa, &.{ base, "plain.txt" });
    errdefer gpa.free(plain_path);
    const plain_fd = try sys.openat(fsx.cwd, plain_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer sys.close(plain_fd);
    try sys.writeAll(plain_fd, "text\n");
    return .{ .base = base, .exe_path = exe_path, .plain_path = plain_path };
}

test "a closed stdout at start does not send the child's stderr to its stdout" {
    try expectChildPasses(struct {
        fn body() u8 {
            sys.close(1);
            return shPrints("echo out; echo err >&2", null, "out\n");
        }
    }.body);
}

test "a closed stdin at start leaves the child's stdin and stderr on their files" {
    try expectChildPasses(struct {
        fn body() u8 {
            sys.close(0);
            const r = shPrints("readlink /proc/self/fd/0 || echo closed", null, "/dev/null\n");
            if (r != 0) return r;
            return shPrints("cat; readlink /proc/self/fd/2", "in\n", "in\n/dev/null\n");
        }
    }.body);
}

test "a closed stderr at start leaves the child's stderr on /dev/null" {
    try expectChildPasses(struct {
        fn body() u8 {
            sys.close(2);
            return shPrints("readlink /proc/self/fd/2 || echo closed", null, "/dev/null\n");
        }
    }.body);
}

test "a status lost to an ignored SIGCHLD is an error, not a kill by signal 9" {
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var old: linux.Sigaction = undefined;
    _ = linux.sigaction(.CHLD, &ignore, &old);
    defer _ = linux.sigaction(.CHLD, &old, null);
    try std.testing.expectError(error.NoChild, run(std.testing.allocator, "/bin/sh", &.{ "sh", "-c", "exit 3" }, no_env, .{}));
    try std.testing.expectEqual(linux.E.CHILD, sys.last_errno);
}

test "resolveExecutable resolves slash paths and PATH lookup" {
    const gpa = std.testing.allocator;
    const fixture = try makeExecFixture(gpa, "resolve");
    defer gpa.free(fixture.plain_path);
    defer gpa.free(fixture.exe_path);
    defer gpa.free(fixture.base);
    defer fsx.deleteTree(gpa, fsx.cwd, fixture.base) catch {};

    const dir_path = try std.fs.path.join(gpa, &.{ fixture.base, "dir" });
    defer gpa.free(dir_path);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, dir_path)).ptr, 0o755);

    const by_path = (try resolveExecutable(gpa, fixture.exe_path, null)).?;
    defer gpa.free(by_path);
    try std.testing.expectEqualStrings(fixture.exe_path, by_path);

    const by_name = (try resolveExecutable(gpa, "tool.sh", fixture.base)).?;
    defer gpa.free(by_name);
    try std.testing.expectEqualStrings(fixture.exe_path, by_name);

    try std.testing.expectEqual(@as(?[]u8, null), try resolveExecutable(gpa, fixture.plain_path, null));
    try std.testing.expectEqual(@as(?[]u8, null), try resolveExecutable(gpa, dir_path, null));
    try std.testing.expectEqual(@as(?[]u8, null), try resolveExecutable(gpa, "not-present-tool", fixture.base));
}
