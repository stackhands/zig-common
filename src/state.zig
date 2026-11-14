//! Private state files in a directory other users may write, such as /tmp:
//! a file is trusted only when the open descriptor is a regular file owned by
//! this user with one link and no group or other bits; writes go to a fresh
//! file beside it and are renamed over it; a lock file is trusted the same
//! way before it is locked on.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");

const Allocator = std.mem.Allocator;
pub const Error = sys.Error;

/// Regular, owned by `uid`, one link, mode & 0o077 == 0.
pub fn privateOk(st: fsx.Stat, uid: linux.uid_t) bool {
    return st.isReg() and st.uid == uid and st.nlink == 1 and st.mode & 0o077 == 0;
}

/// Open `dir/name` without following a final symbolic link and without
/// blocking on a FIFO; with `create`, make it mode 0600 when absent. Null
/// when it is absent or not private to this user.
pub fn openPrivate(dir: fsx.fd_t, name: []const u8, create: bool) Error!?fsx.fd_t {
    const fd = sys.openat(dir, name, .{
        .ACCMODE = if (create) .RDWR else .RDONLY,
        .CREAT = create,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0o600) catch |err| switch (err) {
        error.NotFound, error.SymLink => return null,
        else => return err,
    };
    const st = fsx.fstat(fd) catch |err| {
        sys.close(fd);
        return err;
    };
    if (!privateOk(st, sys.getuid())) {
        sys.close(fd);
        return null;
    }
    return fd;
}

pub const LockError = Error || error{TimedOut};

/// flock(LOCK_EX) on `fd`, giving up after `timeout_ms` when one is given.
pub fn lockExclusive(fd: fsx.fd_t, timeout_ms: ?u32) LockError!void {
    const ms = timeout_ms orelse {
        _ = try sys.call(linux.flock, .{ fd, std.posix.LOCK.EX });
        return;
    };
    var left: i64 = ms;
    while (true) {
        const rc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .AGAIN, .INTR => {},
            else => return error.Unexpected,
        }
        if (left <= 0) return error.TimedOut;
        const step: i64 = @min(left, 20);
        var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(step * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
        left -= step;
    }
}

/// The contents of `dir/name` when the file is private to this user and no
/// larger than `limit`; null otherwise.
pub fn readPrivate(gpa: Allocator, dir: fsx.fd_t, name: []const u8, limit: usize) (Error || Allocator.Error)!?[]u8 {
    const fd = (try openPrivate(dir, name, false)) orelse return null;
    defer sys.close(fd);
    return fsx.readAll(gpa, fd, limit) catch |err| switch (err) {
        error.StreamTooLong => null,
        else => |e| return e,
    };
}

/// Replace `dir/name` with `bytes`: written to `.NAME.PID.RANDOM.tmp` with
/// mode 0600, then renamed over the name.
pub fn writePrivate(gpa: Allocator, dir: fsx.fd_t, name: []const u8, bytes: []const u8) (Error || Allocator.Error)!void {
    var rnd: [6]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
    const tmp = try gpa.print(".{s}.{d}.{x}.tmp", .{ name, linux.getpid(), rnd });
    defer gpa.free(tmp);
    const fd = try sys.openat(dir, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    var done = false;
    defer {
        sys.close(fd);
        if (!done) sys.unlinkat(dir, tmp, 0) catch {};
    }
    try sys.writeAll(fd, bytes);
    try sys.fchmod(fd, 0o600);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
}

test "a file that is not private is not read" {
    const gpa = std.testing.allocator;
    var pb: [64]u8 = undefined;
    const base = try std.mem.print(&pb, "/tmp/zig-common-state-{d}", .{linux.getpid()});
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(d);
    }
    try writePrivate(gpa, d, "c.json", "{\"v\":1}\n");
    const got = (try readPrivate(gpa, d, "c.json", 1024)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{\"v\":1}\n", got);
    try std.testing.expect((try readPrivate(gpa, d, "c.json", 3)) == null);

    const f = (try openPrivate(d, "c.json", false)).?;
    try sys.fchmod(f, 0o644);
    sys.close(f);
    try std.testing.expect((try readPrivate(gpa, d, "c.json", 1024)) == null);
    try std.testing.expect((try readPrivate(gpa, d, "absent", 1024)) == null);

    const lk = (try openPrivate(d, "c.json.lock", true)).?;
    defer sys.close(lk);
    try lockExclusive(lk, 100);
}

// ---- the state-root lock: a flock gate and a POSIX record lock -------------

/// A state root's lock. The flock gate excludes processes on one kernel; the
/// POSIX record lock on a separate sidecar excludes nodes where the
/// filesystem keeps record locks coherent. The sidecar is opened only while
/// the gate is held, because closing any descriptor for it drops this
/// process's record locks; it is released before the gate. Neither file is
/// ever unlinked.
pub const RootLock = struct {
    gate: fsx.fd_t,
    posix: fsx.fd_t,
    /// The process that took the lock. A forked child that releases it only
    /// closes its descriptors: unlocking the shared gate would drop the
    /// parent's lock.
    owner: linux.pid_t,

    pub const AcquireError = Error || error{ Busy, NotPrivate, OutOfMemory };

    fn takeFlock(fd: fsx.fd_t, deadline_ms: ?i64) AcquireError!void {
        const d = deadline_ms orelse {
            _ = try lockCall(lock_ops.flock, .{ fd, @as(i32, std.posix.LOCK.EX) });
            return;
        };
        while (true) {
            const rc = lock_ops.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .AGAIN, .ACCES, .INTR => {},
                else => return mapped(rc),
            }
            if (try pause(d)) return error.Busy;
        }
    }

    fn takeRecord(fd: fsx.fd_t, deadline_ms: ?i64) AcquireError!void {
        var fl: linux.Flock = std.mem.zeroes(linux.Flock);
        fl.type = linux.F.WRLCK;
        fl.whence = 0; // SEEK_SET, offset 0, length 0: the whole file
        const cmd: i32 = if (deadline_ms == null) linux.F.SETLKW else linux.F.SETLK;
        while (true) {
            const rc = lock_ops.fcntl(fd, cmd, @intFromPtr(&fl));
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .AGAIN, .ACCES => if (deadline_ms) |d| {
                    if (try pause(d)) return error.Busy;
                } else return error.Unexpected,
                else => return mapped(rc),
            }
        }
    }

    /// True once the deadline has passed; otherwise sleeps up to 20 ms.
    fn pause(deadline_ms: i64) Error!bool {
        const left = deadline_ms - nowMs();
        if (left <= 0) return true;
        var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(@min(left, 20) * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
        return false;
    }

    /// Lock STATE_ROOT/.lock and STATE_ROOT/.lock.posix, waiting up to
    /// `timeout_ms` (null: no limit). The gate then records this pid.
    pub fn acquire(gpa: Allocator, state_root: []const u8, timeout_ms: ?u32) AcquireError!RootLock {
        const atomic = @import("atomic.zig");
        try atomic.makedirs(state_root);
        const deadline: ?i64 = if (timeout_ms) |t| nowMs() + t else null;
        const gate_path = try std.fs.path.join(gpa, &.{ state_root, ".lock" });
        defer gpa.free(gate_path);
        const posix_path = try gpa.print("{s}.posix", .{gate_path});
        defer gpa.free(posix_path);
        const gate = try sys.openat(fsx.cwd, gate_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, 0o644);
        errdefer sys.close(gate);
        try takeFlock(gate, deadline);
        var zb: [sys.path_max:0]u8 = undefined;
        const posix: fsx.fd_t = @intCast(try lockCall(lock_ops.open_sidecar, .{(try sys.z(&zb, posix_path)).ptr}));
        errdefer sys.close(posix);
        const st = try fsx.fstat(posix);
        if (!st.isReg() or st.nlink != 1) return error.NotPrivate;
        try takeRecord(posix, deadline);
        _ = try lockCall(lock_ops.ftruncate, .{ gate, @as(i64, 0) });
        var buf: [24]u8 = undefined;
        const line = std.mem.print(&buf, "{d}\n", .{linux.getpid()}) catch unreachable;
        if ((try lockCall(lock_ops.write, .{ gate, line })) != line.len) return error.NoSpace;
        return .{ .gate = gate, .posix = posix, .owner = linux.getpid() };
    }

    /// Unlock the record lock, close its descriptor, then unlock and close
    /// the gate. Both descriptors are closed whatever an unlock returns; a
    /// forked child only closes them.
    pub fn release(l: RootLock) void {
        if (linux.getpid() == l.owner) {
            var fl: linux.Flock = std.mem.zeroes(linux.Flock);
            fl.type = linux.F.UNLCK;
            _ = lock_ops.fcntl(l.posix, linux.F.SETLK, @intFromPtr(&fl));
        }
        sys.close(l.posix);
        if (linux.getpid() == l.owner) _ = lock_ops.flock(l.gate, std.posix.LOCK.UN);
        sys.close(l.gate);
    }
};

/// The calls RootLock makes, as raw system-call results. Replaceable in the
/// same builds as atomic.ops (this library's tests, a tool's -Dtest-ops
/// artifact); constant real calls in any other build.
pub const LockOps = struct {
    flock: *const fn (fd: fsx.fd_t, op: i32) usize = realFlock,
    fcntl: *const fn (fd: fsx.fd_t, cmd: i32, arg: usize) usize = realFcntl,
    ftruncate: *const fn (fd: fsx.fd_t, len: i64) usize = realFtruncate,
    write: *const fn (fd: fsx.fd_t, bytes: []const u8) usize = realWrite,
    open_sidecar: *const fn (path: [*:0]const u8) usize = realOpenSidecar,
};

var test_lock_ops: LockOps = .{};
const real_lock_ops: LockOps = .{};
pub const lock_ops = if (@import("atomic.zig").replaceable) &test_lock_ops else &real_lock_ops;

fn realFlock(fd: fsx.fd_t, op: i32) usize {
    return linux.flock(fd, op);
}
fn realFcntl(fd: fsx.fd_t, cmd: i32, arg: usize) usize {
    return linux.fcntl(fd, cmd, arg);
}
fn realFtruncate(fd: fsx.fd_t, len: i64) usize {
    return linux.ftruncate(fd, len);
}
fn realWrite(fd: fsx.fd_t, bytes: []const u8) usize {
    return linux.write(fd, bytes.ptr, bytes.len);
}
fn realOpenSidecar(path: [*:0]const u8) usize {
    return linux.openat(fsx.cwd, path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o644);
}

/// One of `lock_ops`, retrying on EINTR.
fn lockCall(f: anytype, args: anytype) Error!usize {
    while (true) {
        if (try sys.result(@call(.auto, f, args))) |rc| return rc;
    }
}

fn mapped(rc: usize) Error {
    _ = sys.result(rc) catch |e| return e;
    return error.Unexpected;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "RootLock refuses a second holder and is free after release" {
    const gpa = std.testing.allocator;
    var pb: [64]u8 = undefined;
    const base = try std.mem.print(&pb, "/tmp/zig-common-rootlock-{d}", .{linux.getpid()});
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const first = try RootLock.acquire(gpa, base, 0);
    try std.testing.expectError(error.Busy, RootLock.acquire(gpa, base, 0));
    first.release();
    const again = try RootLock.acquire(gpa, base, 0);
    again.release();
}
