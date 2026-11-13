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
    const tmp = try std.fmt.allocPrint(gpa, ".{s}.{d}.{x}.tmp", .{ name, linux.getpid(), rnd });
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
    const base = try std.fmt.bufPrint(&pb, "/tmp/zig-common-state-{d}", .{linux.getpid()});
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
