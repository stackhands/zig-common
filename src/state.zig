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
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-state-{d}", .{ cwd, linux.getpid() });
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
///
/// Others may be able to write the state root. The root is opened without
/// following a symbolic link as its last component, both files through its
/// descriptor without following one at their names, and each is trusted
/// only as a regular file with one link: a FIFO planted at a name is never
/// opened, and the file behind a planted hard link is never truncated.
pub const RootLock = struct {
    gate: fsx.fd_t,
    posix: fsx.fd_t,
    /// The process that took the lock. A forked child that releases it only
    /// closes its descriptors: unlocking the shared gate would drop the
    /// parent's lock.
    owner: linux.pid_t,

    pub const AcquireError = Error || error{
        Busy,
        /// STATE_ROOT/.lock.posix is not a regular file with one link.
        NotPrivate,
        /// STATE_ROOT/.lock is not a regular file with one link.
        GateNotPrivate,
        OutOfMemory,
    };

    const gate_name = ".lock";
    const sidecar_name = ".lock.posix";

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
    ///
    /// STATE_ROOT is created when absent and opened O_DIRECTORY|O_NOFOLLOW;
    /// a symbolic link there is NotDir. Each lock file is opened relative to
    /// that descriptor with O_NOFOLLOW, created mode 0600, only when its name
    /// is absent or a regular file with one link, and its descriptor must be
    /// that file. The gate is checked again once both locks are held, right
    /// before it is truncated. Allocates nothing; `gpa` stays for source
    /// compatibility.
    pub fn acquire(gpa: Allocator, state_root: []const u8, timeout_ms: ?u32) AcquireError!RootLock {
        _ = gpa;
        const atomic = @import("atomic.zig");
        const root = withoutTrailingSlashes(state_root);
        try atomic.makedirs(root);
        const deadline: ?i64 = if (timeout_ms) |t| nowMs() + t else null;
        const dir = try fsx.openDir(fsx.cwd, root, false);
        defer sys.close(dir);
        const gate = (try openLockFile(dir, gate_name, realOpenLock)) orelse return error.GateNotPrivate;
        errdefer sys.close(gate);
        try takeFlock(gate, deadline);
        const posix = (try openLockFile(dir, sidecar_name, lock_ops.open_sidecar)) orelse return error.NotPrivate;
        errdefer sys.close(posix);
        try takeRecord(posix, deadline);
        if (!try isSoleLink(dir, gate_name, gate)) return error.GateNotPrivate;
        _ = try lockCall(lock_ops.ftruncate, .{ gate, @as(i64, 0) });
        var buf: [24]u8 = undefined;
        const line = std.mem.print(&buf, "{d}\n", .{linux.getpid()}) catch unreachable;
        if ((try lockCall(lock_ops.write, .{ gate, line })) != line.len) return error.NoSpace;
        return .{ .gate = gate, .posix = posix, .owner = linux.getpid() };
    }

    /// `dir/name` opened read-write through `open`; null unless the name is
    /// absent or a regular file with one link before the open, so a FIFO,
    /// device or symbolic link there is never opened, and the descriptor is
    /// that file after it.
    fn openLockFile(dir: fsx.fd_t, name: [:0]const u8, open: *const fn (dir: fsx.fd_t, name: [*:0]const u8) usize) Error!?fsx.fd_t {
        if (fsx.statAt(dir, name, false)) |st| {
            if (!st.isReg() or st.nlink != 1) return null;
        } else |err| switch (err) {
            error.NotFound => {},
            else => |e| return e,
        }
        const fd: fsx.fd_t = @intCast(lockCall(open, .{ dir, name.ptr }) catch |err| switch (err) {
            error.SymLink, error.IsDir => return null,
            else => |e| return e,
        });
        errdefer sys.close(fd);
        if (try isSoleLink(dir, name, fd)) return fd;
        sys.close(fd);
        return null;
    }

    /// Whether `fd` is a regular file whose one link is `dir/name`. The name
    /// is looked up as well as the descriptor: a planted hard link unlinked
    /// while the lock is awaited leaves the descriptor on the other name's
    /// file, with one link.
    fn isSoleLink(dir: fsx.fd_t, name: []const u8, fd: fsx.fd_t) Error!bool {
        const st = try fsx.fstat(fd);
        if (!st.isReg() or st.nlink != 1) return false;
        const at = fsx.statAt(dir, name, false) catch |err| switch (err) {
            error.NotFound => return false,
            else => |e| return e,
        };
        return at.dev == st.dev and at.ino == st.ino and at.nlink == 1;
    }

    /// A trailing slash makes the kernel follow a final symbolic link even
    /// under O_NOFOLLOW. "/" stays "/".
    fn withoutTrailingSlashes(path: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, path, "/");
        return if (trimmed.len == 0 and path.len != 0) "/" else trimmed;
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
    open_sidecar: *const fn (dir: fsx.fd_t, name: [*:0]const u8) usize = realOpenLock,
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
fn realOpenLock(dir: fsx.fd_t, name: [*:0]const u8) usize {
    return linux.openat(dir, name, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0o600);
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
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-rootlock-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const first = try RootLock.acquire(gpa, base, 0);
    try std.testing.expectError(error.Busy, RootLock.acquire(gpa, base, 0));
    first.release();
    const again = try RootLock.acquire(gpa, base, 0);
    again.release();
}
