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
/// The errors of this module's calls: `sys.Error`.
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

/// The state root pre-check `RootLock.acquire` applies: a root that
/// exists and is not a directory once symbolic links are followed is
/// ENOTDIR, a dangling link and a link loop among them, and a missing
/// name passes for makedirs to create. The Python tool reaches its
/// lexists-and-not-isdir line only after its component check has found
/// no symlink, since that check refuses a symlinked root as unsafe
/// first; a symlinked root is not this pre-check's to refuse either
/// way, and RootLock keeps its own NotDir from the open that does not
/// follow it, a known difference in the message alone.
pub fn preflightRoot(root: []const u8) Error!void {
    if (fsx.statAt(fsx.cwd, root, true)) |st| {
        if (st.isDir()) return;
        return error.NotDir;
    } else |_| {}
    // isdir says no; a name that still exists is a link it could not
    // follow, a dangling link among them, and is ENOTDIR.
    if (fsx.statAt(fsx.cwd, root, false)) |_| return error.NotDir else |_| {}
}

/// `error.TimedOut` when another holder kept the lock past the timeout.
pub const LockError = Error || error{TimedOut};

/// The errors of `lockExclusiveCancel`: `LockError`, or `error.Canceled`
/// when `cancel` is set while waiting.
pub const LockCancelError = LockError || error{Canceled};

/// flock(LOCK_EX) on `fd`, giving up after `timeout_ms` when one is given.
/// The timeout is u64 milliseconds, wide enough for the seconds callers
/// like flock -w take: the largest a tool passes is 999_999_999 seconds,
/// whose milliseconds a u32 could not hold. The deadline is read from
/// the monotonic clock. A signal that cuts a sleep short does not
/// consume the whole wait: the next check looks at the clock again. A
/// failure other than contention is the flock error, with its errno in
/// `sys.last_errno`.
pub fn lockExclusive(fd: fsx.fd_t, timeout_ms: ?u64) LockError!void {
    return lockExclusiveCancel(fd, timeout_ms, null) catch |err| switch (err) {
        error.Canceled => unreachable,
        else => |e| return e,
    };
}

/// Like `lockExclusive`, also stopping with `error.Canceled` if `cancel`
/// becomes true while waiting.
pub fn lockExclusiveCancel(fd: fsx.fd_t, timeout_ms: ?u64, cancel: ?*const std.atomic.Value(bool)) LockCancelError!void {
    const deadline: ?i64 = if (timeout_ms) |ms| nowMs() + @as(i64, @intCast(ms)) else null;
    if (deadline == null and cancel == null) {
        _ = try lockCall(lock_ops.flock, .{ fd, @as(i32, std.posix.LOCK.EX) });
        return;
    }
    while (true) {
        if (cancel) |c| if (c.load(.seq_cst)) return error.Canceled;
        const rc = lock_ops.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .AGAIN, .INTR => {},
            else => return mapped(rc),
        }
        var sleep_ms: i64 = 20;
        if (deadline) |dl| {
            const left = dl - nowMs();
            if (left <= 0) return error.TimedOut;
            sleep_ms = @min(left, 20);
        }
        var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(sleep_ms * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
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
    const parent = std.fs.path.dirname(name) orelse ".";
    const base = std.fs.path.basename(name);
    const tmp = try gpa.print("{s}/.{s}.{d}.{x}.tmp", .{ parent, base, linux.getpid(), rnd });
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

test "writePrivate handles nested names under the opened directory" {
    const gpa = std.testing.allocator;
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-state-nested-{d}", .{ cwd, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(d);
    }
    _ = linux.mkdirat(d, (try sys.z(&zb, "sub")).ptr, 0o700);

    try writePrivate(gpa, d, "sub/c.json", "{\"v\":2}\n");
    const got = (try readPrivate(gpa, d, "sub/c.json", 1024)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{\"v\":2}\n", got);
}

fn onUsr1(_: linux.SIG) callconv(.c) void {}

test "lockExclusive waits out the timeout while signals arrive" {
    const gpa = std.testing.allocator;
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-locktime-{d}", .{ cwd, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(d);
    }
    const held = try sys.openat(d, "L", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer sys.close(held);
    const waiter = try sys.openat(d, "L", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(waiter);
    _ = try sys.call(linux.flock, .{ held, std.posix.LOCK.EX });
    defer _ = linux.flock(held, std.posix.LOCK.UN);

    const handler: linux.Sigaction = .{ .handler = .{ .handler = &onUsr1 }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.USR1, &handler, &prev);
    defer _ = linux.sigaction(.USR1, &prev, null);
    const Stop = struct {
        var go = std.atomic.Value(bool).init(true);
        fn buzz() void {
            // This thread must not catch SIGUSR1, or the waiter's sleep is
            // never the one the signal interrupts.
            var blocked = linux.sigemptyset();
            linux.sigaddset(&blocked, .USR1);
            _ = linux.sigprocmask(linux.SIG.BLOCK, &blocked, null);
            while (go.load(.acquire)) {
                _ = linux.kill(linux.getpid(), .USR1);
                var ts: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
            }
        }
    };
    Stop.go.store(true, .release);
    const buzz = try std.Thread.spawn(.{}, Stop.buzz, .{});
    var t0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t0);
    try std.testing.expectError(error.TimedOut, lockExclusive(waiter, 400));
    var t1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t1);
    Stop.go.store(false, .release);
    buzz.join();
    const ms = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);
    try std.testing.expect(ms >= 300 and ms < 5000);
}

test "a lock that fails reports its errno, with or without a timeout" {
    for ([_]?u64{ null, 0, 50 }) |timeout| {
        sys.last_errno = .SUCCESS;
        try std.testing.expectError(error.InvalidArgument, lockExclusive(-1, timeout));
        try std.testing.expectEqualStrings("[Errno 9] Bad file descriptor", sys.describe(error.InvalidArgument));
    }
}

test "lockExclusive takes the timeout flock -w seconds give" {
    const gpa = std.testing.allocator;
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-locku64-{d}", .{ cwd, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(d);
    }

    // the 999_999_999 seconds a tool may pass, as milliseconds: wider
    // than a u32 holds, and with the lock free it returns at once
    const fd1 = try sys.openat(d, "L", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer sys.close(fd1);
    try lockExclusive(fd1, 999_999_999 * std.time.ms_per_s);

    // with the lock held, a timeout past u32 range still waits for the
    // release instead of wrapping to a deadline already past
    const fd2 = try sys.openat(d, "L", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(fd2);
    const Holder = struct {
        var fd: fsx.fd_t = -1;
        fn letGo() void {
            var ts: linux.timespec = .{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
            _ = linux.flock(fd, std.posix.LOCK.UN);
        }
    };
    Holder.fd = fd1;
    const thread = try std.Thread.spawn(.{}, Holder.letGo, .{});
    thread.join();
    try lockExclusive(fd2, 500_000_000 * std.time.ms_per_s);
    _ = linux.flock(fd2, std.posix.LOCK.UN);
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
/// only as a regular file of this user with one link: a FIFO planted at a
/// name is never opened, and the file behind a planted hard link, or a file
/// another user owns, is never truncated.
pub const RootLock = struct {
    /// STATE_ROOT/.lock, with the flock held.
    gate: fsx.fd_t,
    /// STATE_ROOT/.lock.posix, with the record lock held.
    posix: fsx.fd_t,
    /// The process that took the lock. A forked child that releases it only
    /// closes its descriptors: unlocking the shared gate would drop the
    /// parent's lock.
    owner: linux.pid_t,

    /// The errors of `acquire`, beside the `sys.Error` of a failed call.
    /// `error.OutOfMemory` stays in the set with the `gpa` argument; it is
    /// not returned.
    pub const AcquireError = Error || error{
        /// Another holder kept a lock past `timeout_ms`.
        Busy,
        /// STATE_ROOT/.lock.posix is not a regular file of this user with
        /// one link.
        NotPrivate,
        /// STATE_ROOT/.lock is not a regular file of this user with one link.
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
    /// is absent or a regular file of this user with one link, and its
    /// descriptor must be that file. An accepted descriptor is tightened to
    /// mode 0600. The gate is checked again once both locks are held, right
    /// before it is truncated. Allocates nothing; `gpa` stays for source
    /// compatibility.
    pub fn acquire(gpa: Allocator, state_root: []const u8, timeout_ms: ?u32) AcquireError!RootLock {
        _ = gpa;
        const atomic = @import("atomic.zig");
        const root = withoutTrailingSlashes(state_root);
        // The Python tool pre-checks the root before makedirs; a
        // non-directory root is ENOTDIR here whatever makedirs alone
        // would say. A root that is a directory once links are followed
        // passes this and is refused below only when the root itself is
        // a link, as the root is opened without following it.
        try preflightRoot(root);
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
    /// absent or a regular file of this user with one link before the open,
    /// so a FIFO, device or symbolic link there is never opened, and the
    /// descriptor is that file after it.
    fn openLockFile(dir: fsx.fd_t, name: [:0]const u8, open: *const fn (dir: fsx.fd_t, name: [*:0]const u8) usize) Error!?fsx.fd_t {
        if (fsx.statAt(dir, name, false)) |st| {
            if (!st.isReg() or st.nlink != 1 or st.uid != linux.geteuid()) return null;
        } else |err| switch (err) {
            error.NotFound => {},
            else => |e| return e,
        }
        const fd: fsx.fd_t = @intCast(lockCall(open, .{ dir, name.ptr }) catch |err| switch (err) {
            error.SymLink, error.IsDir => return null,
            else => |e| return e,
        });
        errdefer sys.close(fd);
        if (try isSoleLink(dir, name, fd)) {
            try sys.fchmod(fd, 0o600);
            return fd;
        }
        sys.close(fd);
        return null;
    }

    /// Whether `fd` is a regular file of this user whose one link is
    /// `dir/name`. The name is looked up as well as the descriptor: a
    /// planted hard link unlinked while the lock is awaited leaves the
    /// descriptor on the other name's file, with one link.
    fn isSoleLink(dir: fsx.fd_t, name: []const u8, fd: fsx.fd_t) Error!bool {
        const st = try fsx.fstat(fd);
        if (!st.isReg() or st.nlink != 1 or st.uid != linux.geteuid()) return false;
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
/// The calls in use. A replaceable build may assign through it
/// (`lock_ops.* = ...`); any other build points it at constant real calls.
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

test "the state root preflight matches lexists and isdir" {
    const gpa = std.testing.allocator;
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-preflight-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(dir);

    const fd = try sys.openat(dir, "plain", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys.close(fd);
    _ = linux.mkdirat(dir, (try sys.z(&zb, "real")).ptr, 0o700);
    _ = linux.symlinkat("real", dir, (try sys.z(&zb, "link-dir")).ptr);
    _ = linux.symlinkat("plain", dir, (try sys.z(&zb, "link-file")).ptr);
    _ = linux.symlinkat("nowhere", dir, (try sys.z(&zb, "link-dangling")).ptr);
    _ = linux.symlinkat("link-loop", dir, (try sys.z(&zb, "link-loop")).ptr);

    var nb: [sys.path_max]u8 = undefined;
    const at = struct {
        fn at(b: []const u8, name: []const u8, out: *[sys.path_max]u8) []const u8 {
            return std.fmt.bufPrint(out, "{s}/{s}", .{ b, name }) catch unreachable;
        }
    };

    // accepted: a directory, a missing name that makedirs will create,
    // and a link to a directory, which the expression in isolation
    // follows as isdir does. A symlinked root never reaches this line
    // in the Python tool, whose component check refuses it as unsafe
    // first, and RootLock refuses it after the pre-check with NotDir.
    try preflightRoot(at.at(base, "real", &nb));
    try preflightRoot(at.at(base, "link-dir", &nb));
    try preflightRoot(at.at(base, "absent", &nb));

    // refused with ENOTDIR: a file, a link to a file, a dangling link
    // and a link loop, all lexists-true and isdir-false
    try std.testing.expectError(error.NotDir, preflightRoot(at.at(base, "plain", &nb)));
    try std.testing.expectError(error.NotDir, preflightRoot(at.at(base, "link-file", &nb)));
    try std.testing.expectError(error.NotDir, preflightRoot(at.at(base, "link-dangling", &nb)));
    try std.testing.expectError(error.NotDir, preflightRoot(at.at(base, "link-loop", &nb)));
}

test "RootLock refuses a non-directory state root with NotDir" {
    const gpa = std.testing.allocator;
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-rootfile-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);

    // a regular file as the root
    const file_root = try std.fmt.allocPrint(gpa, "{s}/file-root", .{base});
    defer gpa.free(file_root);
    const fd = try sys.openat(fsx.cwd, file_root, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys.close(fd);
    try std.testing.expectError(error.NotDir, RootLock.acquire(gpa, file_root, 0));
    try std.testing.expectEqualStrings("[Errno 20] Not a directory", sys.describe(error.NotDir));

    // a dangling symbolic link as the root
    const dangling_root = try std.fmt.allocPrint(gpa, "{s}/dangling-root", .{base});
    defer gpa.free(dangling_root);
    _ = linux.symlinkat("nowhere", fsx.cwd, (try sys.z(&zb, dangling_root)).ptr);
    try std.testing.expectError(error.NotDir, RootLock.acquire(gpa, dangling_root, 0));

    // a symlink to a directory as the root: the Python tool refuses it
    // as unsafe through its component check, RootLock with the NotDir
    // of the open that does not follow it, and neither accepts it
    const real_root = try std.fmt.allocPrint(gpa, "{s}/real-root", .{base});
    defer gpa.free(real_root);
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, real_root)).ptr, 0o700);
    const link_root = try std.fmt.allocPrint(gpa, "{s}/link-root", .{base});
    defer gpa.free(link_root);
    _ = linux.symlinkat("real-root", fsx.cwd, (try sys.z(&zb, link_root)).ptr);
    try std.testing.expectError(error.NotDir, RootLock.acquire(gpa, link_root, 0));
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

test "lockExclusiveCancel returns Canceled when cancel is set" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const lock_path = try gpa.print("{s}/.zig-cache/zig-common-cancel-{d}.lock", .{ cwd, linux.getpid() });
    defer {
        _ = sys.unlinkat(fsx.cwd, lock_path, 0) catch {};
        gpa.free(lock_path);
    }
    const fd1 = try sys.openat(fsx.cwd, lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer sys.close(fd1);
    try lockExclusive(fd1, null);
    const fd2 = try sys.openat(fsx.cwd, lock_path, .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(fd2);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, lockExclusiveCancel(fd2, 60_000, &cancel));
}

test "lockExclusive covers timeout 0, bounded timeout, and unsupported flock" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try gpa.print("{s}/.zig-cache/zig-common-lockerr-{d}", .{ cwd, linux.getpid() });
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        gpa.free(base);
    }
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(dir);

    var sub_z: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(dir, (try sys.z(&sub_z, "sub")).ptr, 0o700);
    try std.testing.expectError(error.IsDir, openPrivate(dir, "sub", true));
    try std.testing.expectError(error.InvalidArgument, readPrivate(gpa, -1, "x", 64));
    try std.testing.expectError(error.InvalidArgument, writePrivate(gpa, -1, "x", "y"));

    const fd1 = (try openPrivate(dir, "lck", true)).?;
    defer sys.close(fd1);
    try lockExclusive(fd1, 0);

    const fd2 = try sys.openat(dir, "lck", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(fd2);
    try std.testing.expectError(error.TimedOut, lockExclusive(fd2, 0));
    try std.testing.expectError(error.TimedOut, lockExclusive(fd2, 40));

    const Hooks = struct {
        var err_code: linux.E = .OPNOTSUPP;
        fn fail(_: fsx.fd_t, _: i32) usize {
            return @bitCast(-@as(isize, @backingInt(err_code)));
        }
    };
    defer lock_ops.* = .{};
    lock_ops.flock = Hooks.fail;
    for ([_]linux.E{ .OPNOTSUPP, .NOSYS }) |e| {
        Hooks.err_code = e;
        for ([_]?u64{ null, 0, 25 }) |timeout| {
            sys.last_errno = .SUCCESS;
            try std.testing.expectError(error.Unsupported, lockExclusive(fd2, timeout));
            try std.testing.expectEqual(e, sys.last_errno);
        }
    }
}
