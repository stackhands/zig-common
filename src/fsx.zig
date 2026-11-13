//! File handling with the checks done on the open file descriptor, not on a
//! path that can change between a check and its use.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
pub const fd_t = sys.fd_t;
pub const Error = sys.Error;
pub const cwd: fd_t = linux.AT.FDCWD;

pub const S = struct {
    pub const IFMT: u32 = 0o170000;
    pub const IFREG: u32 = 0o100000;
    pub const IFDIR: u32 = 0o040000;
    pub const IFLNK: u32 = 0o120000;
};

pub const Stat = struct {
    mode: u32,
    uid: linux.uid_t,
    gid: linux.gid_t,
    nlink: u32,
    size: u64,
    atime: linux.timespec,
    mtime: linux.timespec,

    pub fn isReg(s: Stat) bool {
        return s.mode & S.IFMT == S.IFREG;
    }
    pub fn isDir(s: Stat) bool {
        return s.mode & S.IFMT == S.IFDIR;
    }
    pub fn isLink(s: Stat) bool {
        return s.mode & S.IFMT == S.IFLNK;
    }
    /// The permission bits, including set-id and sticky bits.
    pub fn perm(s: Stat) u32 {
        return s.mode & 0o7777;
    }
};

const statx_mask: linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .NLINK = true,
    .UID = true,
    .GID = true,
    .ATIME = true,
    .MTIME = true,
    .SIZE = true,
};

fn fromStatx(x: linux.Statx) Stat {
    return .{
        .mode = x.mode,
        .uid = x.uid,
        .gid = x.gid,
        .nlink = x.nlink,
        .size = x.size,
        .atime = .{ .sec = @intCast(x.atime.sec), .nsec = @intCast(x.atime.nsec) },
        .mtime = .{ .sec = @intCast(x.mtime.sec), .nsec = @intCast(x.mtime.nsec) },
    };
}

pub fn fstat(fd: fd_t) Error!Stat {
    var x: linux.Statx = undefined;
    _ = try sys.call(linux.statx, .{ fd, "", linux.AT.EMPTY_PATH, statx_mask, &x });
    return fromStatx(x);
}

/// stat of `path` relative to `dir`; `follow` decides whether a final
/// symbolic link is followed.
pub fn statAt(dir: fd_t, path: []const u8, follow: bool) Error!Stat {
    var buf: [sys.path_max:0]u8 = undefined;
    var x: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    _ = try sys.call(linux.statx, .{ dir, (try sys.z(&buf, path)).ptr, flags, statx_mask, &x });
    return fromStatx(x);
}

/// The absolute path the kernel holds for an open descriptor.
pub fn realpathFd(fd: fd_t, out: *[sys.path_max]u8) Error![]const u8 {
    var link_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrintSentinel(&link_buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    const n = try sys.call(linux.readlinkat, .{ linux.AT.FDCWD, link.ptr, out, out.len });
    if (n == 0 or n >= out.len or out[0] != '/') return error.NotFound;
    return out[0..n];
}

/// realpath(1) with -e: every component must exist; symbolic links are
/// followed.
pub fn realpath(dir: fd_t, path: []const u8, out: *[sys.path_max]u8) Error![]const u8 {
    const fd = try sys.openat(dir, path, .{ .PATH = true }, 0);
    defer sys.close(fd);
    return realpathFd(fd, out);
}

/// Open an existing regular file for reading. `follow` decides whether a
/// final symbolic link is followed. A FIFO or device is refused without
/// blocking on it.
pub fn openRegular(dir: fd_t, path: []const u8, follow: bool) Error!struct { fd: fd_t, stat: Stat } {
    const fd = try sys.openat(dir, path, .{ .NOFOLLOW = !follow, .NONBLOCK = true }, 0);
    errdefer sys.close(fd);
    const st = try fstat(fd);
    if (!st.isReg()) return error.InvalidArgument;
    return .{ .fd = fd, .stat = st };
}

pub fn openDir(dir: fd_t, path: []const u8, follow: bool) Error!fd_t {
    return sys.openat(dir, path, .{ .DIRECTORY = true, .NOFOLLOW = !follow }, 0);
}

fn copyFd(src: fd_t, dst: fd_t) Error!void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(src, &buf);
        if (n == 0) return;
        try sys.writeAll(dst, buf[0..n]);
    }
}

/// Copy an open regular file to `dir/name`, as cp(1) without options does:
/// an existing destination is truncated and keeps its mode, a new one gets
/// the source's permission bits less the umask. A destination that is a
/// symbolic link or not a regular file is refused. Returns the open
/// destination, which the caller closes.
pub fn copyTo(src: fd_t, src_stat: Stat, dir: fd_t, name: []const u8) Error!fd_t {
    const fd = try sys.openat(dir, name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, @intCast(src_stat.mode & 0o777));
    errdefer sys.close(fd);
    if (!(try fstat(fd)).isReg()) return error.InvalidArgument;
    _ = try sys.call(linux.ftruncate, .{ fd, 0 });
    try copyFd(src, fd);
    return fd;
}

/// Append `line` and a newline to `dir/name` in one write, creating the file
/// with mode 0666 less the umask. A symbolic link or non-regular file at the
/// name is refused.
pub fn appendLine(gpa: Allocator, dir: fd_t, name: []const u8, line: []const u8) (Error || Allocator.Error)!void {
    const fd = try sys.openat(dir, name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0o666);
    defer sys.close(fd);
    if (!(try fstat(fd)).isReg()) return error.InvalidArgument;
    const bytes = try std.mem.concat(gpa, u8, &.{ line, "\n" });
    defer gpa.free(bytes);
    try sys.writeAll(fd, bytes);
}

/// Read a whole regular file opened by the caller; more than `limit` bytes
/// is an error.
pub fn readAll(gpa: Allocator, fd: fd_t, limit: usize) (Error || Allocator.Error || error{StreamTooLong})![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(fd, &buf);
        if (n == 0) break;
        if (list.items.len + n > limit) return error.StreamTooLong;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

const acl_names = [_][:0]const u8{ "system.posix_acl_access", "system.nfs4_acl" };

/// Copy the access ACL xattrs of `from` onto `to`. An ACL that exists on
/// `from` and cannot be set on `to` is an error.
fn copyAcls(from: fd_t, to: fd_t) Error!void {
    var buf: [64 * 1024]u8 = undefined;
    for (acl_names) |name| {
        const n = sys.call(linux.fgetxattr, .{ from, name.ptr, &buf, buf.len }) catch |err| switch (err) {
            error.NoData, error.Unsupported => continue,
            else => return err,
        };
        _ = try sys.call(linux.fsetxattr, .{ to, name.ptr, &buf, n, 0 });
    }
}

/// Replace the contents of the regular file `dir/name` atomically. The new
/// file keeps the old one's owner (when this process may set it), mode and
/// access ACLs; it is written beside the old one, synced, then renamed over
/// it.
pub fn replaceContents(gpa: Allocator, dir: fd_t, name: []const u8, bytes: []const u8) (Error || Allocator.Error)!void {
    const old = try openRegular(dir, name, false);
    defer sys.close(old.fd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ name, linux.getpid() });
    defer gpa.free(tmp);
    const fd = try sys.openat(dir, tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, 0o600);
    var done = false;
    defer {
        sys.close(fd);
        if (!done) sys.unlinkat(dir, tmp, 0) catch {};
    }
    try sys.writeAll(fd, bytes);
    const st = try fstat(fd);
    if (st.uid != old.stat.uid or st.gid != old.stat.gid) {
        sys.fchown(fd, old.stat.uid, old.stat.gid) catch |err| switch (err) {
            error.AccessDenied => {},
            else => return err,
        };
    }
    try sys.fchmod(fd, @intCast(old.stat.perm()));
    try copyAcls(old.fd, fd);
    try sys.fsync(fd);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
}

pub const DT = linux.DT;

pub const Entry = struct {
    name: []const u8,
    type: u8,
};

/// Directory entries, without "." and "..", in the order the file system
/// returns them.
pub const DirIter = struct {
    fd: fd_t,
    buf: []align(8) u8,
    pos: usize = 0,
    end: usize = 0,

    /// Iterate `fd` from its first entry, whatever an earlier iteration
    /// of the same descriptor left its offset at.
    pub fn init(gpa: Allocator, fd: fd_t) Allocator.Error!DirIter {
        _ = linux.lseek(fd, 0, linux.SEEK.SET);
        return .{ .fd = fd, .buf = try gpa.alignedAlloc(u8, .@"8", 32 * 1024) };
    }

    pub fn deinit(it: *DirIter, gpa: Allocator) void {
        gpa.free(it.buf);
    }

    pub fn next(it: *DirIter) Error!?Entry {
        while (true) {
            if (it.pos >= it.end) {
                it.end = try sys.call(linux.getdents64, .{ it.fd, it.buf.ptr, @as(c_uint, @intCast(it.buf.len)) });
                it.pos = 0;
                if (it.end == 0) return null;
            }
            const d: *align(1) const linux.dirent64 = @ptrCast(it.buf[it.pos..].ptr);
            const reclen = d.reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(it.buf[it.pos + @offsetOf(linux.dirent64, "name") ..].ptr);
            const name = std.mem.span(name_ptr);
            const typ = d.type;
            it.pos += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .type = typ };
        }
    }
};

/// The type of an entry, from the directory when it says, else from lstat.
pub fn entryType(dir: fd_t, e: Entry) Error!u8 {
    if (e.type != DT.UNKNOWN) return e.type;
    const st = try statAt(dir, e.name, false);
    return switch (st.mode & S.IFMT) {
        S.IFDIR => DT.DIR,
        S.IFREG => DT.REG,
        S.IFLNK => DT.LNK,
        else => DT.UNKNOWN,
    };
}

/// rm -rf of `dir/name`. Symbolic links are removed, never followed. Stops
/// at the first error.
pub fn deleteTree(gpa: Allocator, dir: fd_t, name: []const u8) (Error || Allocator.Error)!void {
    sys.unlinkat(dir, name, 0) catch |err| switch (err) {
        error.IsDir, error.AccessDenied => {
            const st = try statAt(dir, name, false);
            if (!st.isDir()) return err;
            const fd = try openDir(dir, name, false);
            {
                defer sys.close(fd);
                var it = try DirIter.init(gpa, fd);
                defer it.deinit(gpa);
                while (try it.next()) |e| {
                    if (try entryType(fd, e) == DT.DIR) {
                        try deleteTree(gpa, fd, e.name);
                    } else {
                        try sys.unlinkat(fd, e.name, 0);
                    }
                }
            }
            try sys.unlinkat(dir, name, linux.AT.REMOVEDIR);
        },
        else => return err,
    };
}

test "DirIter starts from the first entry on a reused descriptor" {
    const gpa = std.testing.allocator;
    const d = try openDir(cwd, "/", false);
    defer sys.close(d);
    var n1: usize = 0;
    var a = try DirIter.init(gpa, d);
    defer a.deinit(gpa);
    while (try a.next()) |_| n1 += 1;
    var n2: usize = 0;
    var b = try DirIter.init(gpa, d);
    defer b.deinit(gpa);
    while (try b.next()) |_| n2 += 1;
    try std.testing.expect(n1 > 0);
    try std.testing.expectEqual(n1, n2);
}

test "replaceContents keeps the mode" {
    const gpa = std.testing.allocator;
    var tmp_path_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/zig-common-test-{d}", .{linux.getpid()});
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const f = try sys.openat(d, "list", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    try sys.writeAll(f, "a\n");
    try sys.fchmod(f, 0o640);
    sys.close(f);
    try replaceContents(gpa, d, "list", "b\n");
    const st = try statAt(d, "list", false);
    try std.testing.expectEqual(@as(u32, 0o640), st.perm());
    const r = try openRegular(d, "list", false);
    defer sys.close(r.fd);
    const got = try readAll(gpa, r.fd, 100);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("b\n", got);
}
