//! Linux system calls with errno mapped to a Zig error set. The standard
//! library's `std.os.linux` returns raw `usize` results; every call here
//! retries on EINTR and returns a named error otherwise.
const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;
pub const O = linux.O;
pub const AT = linux.AT;
pub const path_max = 4096;

pub const Error = error{
    NotFound,
    Exists,
    AccessDenied,
    SymLink,
    NotDir,
    IsDir,
    NotEmpty,
    NoSpace,
    Busy,
    CrossDevice,
    InvalidArgument,
    NameTooLong,
    TooManyLinks,
    ReadOnly,
    Unsupported,
    NoData,
    Range,
    NoChild,
    NoProcess,
    Unexpected,
};

/// Map a raw result. EINTR is returned as `null` so callers can retry.
fn map(rc: usize) Error!?usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .INTR => null,
        .NOENT => error.NotFound,
        .EXIST => error.Exists,
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.SymLink,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NOTEMPTY => error.NotEmpty,
        .NOSPC, .DQUOT => error.NoSpace,
        .BUSY, .TXTBSY => error.Busy,
        .XDEV => error.CrossDevice,
        .INVAL, .BADF => error.InvalidArgument,
        .NAMETOOLONG => error.NameTooLong,
        .MLINK => error.TooManyLinks,
        .ROFS => error.ReadOnly,
        .OPNOTSUPP, .NOSYS => error.Unsupported,
        .NODATA => error.NoData,
        .RANGE => error.Range,
        .CHILD => error.NoChild,
        .SRCH => error.NoProcess,
        else => error.Unexpected,
    };
}

/// The result of a raw system call: its value, `null` for EINTR (retry), or
/// the error.
pub fn result(rc: usize) Error!?usize {
    return map(rc);
}

/// Run `f` until it does not fail with EINTR.
pub inline fn call(comptime f: anytype, args: anytype) Error!usize {
    while (true) {
        if (try map(@call(.auto, f, args))) |rc| return rc;
    }
}

/// A NUL-terminated copy of `s` in `buf`. Paths with a NUL byte are refused.
pub fn z(buf: *[path_max:0]u8, s: []const u8) Error![:0]const u8 {
    if (s.len >= path_max) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidArgument;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

pub fn openat(dir: fd_t, path: []const u8, flags: O, mode: linux.mode_t) Error!fd_t {
    var buf: [path_max:0]u8 = undefined;
    var f = flags;
    f.CLOEXEC = true;
    const rc = try call(linux.openat, .{ dir, (try z(&buf, path)).ptr, f, mode });
    return @intCast(rc);
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    return call(linux.read, .{ fd, buf.ptr, buf.len });
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try call(linux.write, .{ fd, bytes[off..].ptr, bytes.len - off });
        if (n == 0) return error.NoSpace;
        off += n;
    }
}

pub fn fchmod(fd: fd_t, mode: linux.mode_t) Error!void {
    _ = try call(linux.fchmod, .{ fd, mode });
}

pub fn fchown(fd: fd_t, uid: linux.uid_t, gid: linux.gid_t) Error!void {
    _ = try call(linux.fchown, .{ fd, uid, gid });
}

pub fn fsync(fd: fd_t) Error!void {
    _ = try call(linux.fsync, .{fd});
}

pub fn unlinkat(dir: fd_t, path: []const u8, flags: u32) Error!void {
    var buf: [path_max:0]u8 = undefined;
    _ = try call(linux.unlinkat, .{ dir, (try z(&buf, path)).ptr, flags });
}

pub fn renameat(old_dir: fd_t, old: []const u8, new_dir: fd_t, new: []const u8) Error!void {
    var a: [path_max:0]u8 = undefined;
    var b: [path_max:0]u8 = undefined;
    _ = try call(linux.renameat, .{ old_dir, (try z(&a, old)).ptr, new_dir, (try z(&b, new)).ptr });
}

pub fn getuid() linux.uid_t {
    return linux.getuid();
}
