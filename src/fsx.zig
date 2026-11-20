//! File handling with the checks done on the open file descriptor, not on a
//! path that can change between a check and its use.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
/// A file descriptor, as `sys.fd_t`.
pub const fd_t = sys.fd_t;
/// The errors of this module's calls: `sys.Error`.
pub const Error = sys.Error;
/// The `dir` that makes a path relative to the current directory,
/// `AT_FDCWD`. An absolute path ignores `dir`.
pub const cwd: fd_t = linux.AT.FDCWD;

/// The file type bits of `Stat.mode`, as stat(2) names them.
pub const S = struct {
    /// The mask of the file type bits.
    pub const IFMT: u32 = 0o170000;
    /// A regular file.
    pub const IFREG: u32 = 0o100000;
    /// A directory.
    pub const IFDIR: u32 = 0o040000;
    /// A symbolic link.
    pub const IFLNK: u32 = 0o120000;
};

/// What `fstat` and `statAt` return: the statx(2) fields these tools use.
pub const Stat = struct {
    /// The file type bits (`S`) and the permission bits (`perm`).
    mode: u32,
    uid: linux.uid_t,
    gid: linux.gid_t,
    nlink: u32,
    /// Bytes.
    size: u64,
    atime: linux.timespec,
    mtime: linux.timespec,
    ctime: linux.timespec = .{ .sec = 0, .nsec = 0 },
    /// The device the file is on: the major number in the high 32 bits, the
    /// minor number in the low 32.
    dev: u64 = 0,
    ino: u64 = 0,

    /// True for a regular file.
    pub fn isReg(s: Stat) bool {
        return s.mode & S.IFMT == S.IFREG;
    }
    /// True for a directory.
    pub fn isDir(s: Stat) bool {
        return s.mode & S.IFMT == S.IFDIR;
    }
    /// True for a symbolic link. `statAt` with `follow` true never returns
    /// one.
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
    .CTIME = true,
    .INO = true,
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
        .ctime = .{ .sec = @intCast(x.ctime.sec), .nsec = @intCast(x.ctime.nsec) },
        .dev = (@as(u64, x.dev_major) << 32) | x.dev_minor,
        .ino = x.ino,
    };
}

/// The `Stat` of an open descriptor, from statx(2) with `AT_EMPTY_PATH`.
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
    const link = std.mem.printSentinel(&link_buf, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    const n = try sys.call(linux.readlinkat, .{ linux.AT.FDCWD, link.ptr, out, out.len });
    if (n == 0 or n >= out.len or out[0] != '/') return error.NotFound;
    return out[0..n];
}

/// The path of this program, as /proc/self/exe reports it, or null when
/// the kernel does not report it whole: a failed read, an empty one, or
/// one that filled the buffer.
pub fn selfExe(out: *[sys.path_max]u8) ?[]const u8 {
    const n = sys.call(linux.readlinkat, .{ linux.AT.FDCWD, "/proc/self/exe", out, out.len }) catch return null;
    if (n == 0 or n >= out.len) return null;
    return out[0..n];
}

/// realpath(1) with -e: every component must exist; symbolic links are
/// followed.
pub fn realpath(dir: fd_t, path: []const u8, out: *[sys.path_max]u8) Error![]const u8 {
    const fd = try sys.openat(dir, path, .{ .PATH = true }, 0);
    defer sys.close(fd);
    return realpathFd(fd, out);
}

/// Normalize `path` like Python's `posixpath.normpath`: drop "." segments
/// and repeated slashes, resolve ".." segments without following symbolic
/// links, and keep one or two leading slashes while collapsing three or
/// more to one. The caller owns the returned slice.
pub fn normPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const slashes: usize = if (!std.mem.startsWith(u8, path, "/"))
        0
    else if (std.mem.startsWith(u8, path, "//") and !std.mem.startsWith(u8, path, "///"))
        2
    else
        1;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        const after_up = parts.items.len > 0 and std.mem.eql(u8, parts.items[parts.items.len - 1], "..");
        if (!std.mem.eql(u8, part, "..") or (slashes == 0 and parts.items.len == 0) or after_up) {
            try parts.append(gpa, part);
        } else {
            _ = parts.pop();
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, '/', slashes);
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

/// Return a normalized absolute path like Python's `os.path.abspath`,
/// joining relative paths to the current working directory without
/// following symbolic links. The caller owns the returned slice.
pub fn absPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    if (std.mem.startsWith(u8, path, "/")) return normPath(gpa, path);
    var buf: [sys.path_max]u8 = undefined;
    const cwd_path = realpath(cwd, ".", &buf) catch return normPath(gpa, path);
    const joined = try std.mem.concat(gpa, u8, &.{ cwd_path, "/", path });
    defer gpa.free(joined);
    return normPath(gpa, joined);
}

test "normPath and absPath match posixpath.normpath and os.path.abspath" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "." },
        .{ .in = ".", .want = "." },
        .{ .in = "a/./b/../c", .want = "a/c" },
        .{ .in = "../a/b/..", .want = "../a" },
        .{ .in = "/a/b/../c/", .want = "/a/c" },
        .{ .in = "/../../a", .want = "/a" },
        .{ .in = "//a/b/..", .want = "//a" },
        .{ .in = "///a//b", .want = "/a/b" },
    };
    for (cases) |tc| {
        const got = try normPath(gpa, tc.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(tc.want, got);
    }

    const abs_lit = try absPath(gpa, "///opt/./x/../bin/");
    defer gpa.free(abs_lit);
    try std.testing.expectEqualStrings("/opt/bin", abs_lit);

    var buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &buf);
    const abs_rel = try absPath(gpa, "sub/./file");
    defer gpa.free(abs_rel);
    const expected = try std.mem.concat(gpa, u8, &.{ here, "/sub/file" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, abs_rel);
}

/// Open an existing regular file for reading. `follow` decides whether a
/// final symbolic link is followed. A FIFO or device is refused without
/// blocking on it.
pub fn openRegular(dir: fd_t, path: []const u8, follow: bool) Error!struct { fd: fd_t, stat: Stat } {
    const fd = try sys.openat(dir, path, .{ .NOFOLLOW = !follow, .NONBLOCK = true }, 0);
    errdefer sys.close(fd);
    const st = try fstat(fd);
    if (regularTypeError(st)) |err| return err;
    return .{ .fd = fd, .stat = st };
}

fn regularTypeError(st: Stat) ?Error {
    if (st.isReg()) return null;
    if (st.isLink()) return error.SymLink;
    if (st.isDir()) return error.IsDir;
    return error.NotRegularFile;
}

/// Open the directory `dir/path` for reading with `O_DIRECTORY`. `follow`
/// decides whether a final symbolic link is followed; one that is not is
/// `error.NotDir`, as the kernel reports `O_NOFOLLOW` on a link with
/// `O_DIRECTORY`. The caller closes the descriptor.
pub fn openDir(dir: fd_t, path: []const u8, follow: bool) Error!fd_t {
    return sys.openat(dir, path, .{ .DIRECTORY = true, .NOFOLLOW = !follow }, 0);
}

fn copyFd(src: fd_t, dst: fd_t) Error!void {
    var buf: [64 * 1024]u8 = undefined;
    var off: linux.off_t = 0;
    while (true) {
        const n = try sys.call(linux.pread, .{ src, &buf, buf.len, off });
        if (n == 0) return;
        try sys.writeAll(dst, buf[0..n]);
        off += @intCast(n);
    }
}

/// Copy an open regular file to `dir/name`: all of it, whatever the
/// descriptor's offset, which is left where it was. The bytes are written
/// to a temporary file in `dir`, synced, and renamed over `name`, so a
/// short write (a full disk, a file-size limit) leaves an existing
/// destination as it was and does not publish a partial file under `name`.
/// An existing regular file keeps its owner, when this process may set it,
/// and its mode; a new file gets the source's permission bits less the
/// umask. A destination that is a symbolic link or not a regular file is
/// refused. A destination with other hard links keeps those links on the
/// previous inode; `name` is the new inode. Returns the open destination,
/// which the caller closes.
pub fn copyTo(src: fd_t, src_stat: Stat, dir: fd_t, name: []const u8) Error!fd_t {
    const existing: ?Stat = statAt(dir, name, false) catch |err| switch (err) {
        error.NotFound => null,
        else => |e| return e,
    };
    if (existing) |st| if (regularTypeError(st)) |err| return err;
    var tmp_buf: [sys.path_max]u8 = undefined;
    const tmp = try tmpName(name, &tmp_buf);
    const fd = try sys.openat(dir, tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, if (existing != null) 0o600 else @intCast(src_stat.mode & 0o777));
    var done = false;
    errdefer {
        sys.close(fd);
        if (!done) sys.unlinkat(dir, tmp, 0) catch {};
    }
    try copyFd(src, fd);
    if (existing) |st| {
        if ((try fstat(fd)).uid != st.uid or (try fstat(fd)).gid != st.gid) {
            sys.fchown(fd, st.uid, st.gid) catch |err| switch (err) {
                error.AccessDenied => {},
                else => |e| return e,
            };
        }
        try sys.fchmod(fd, @intCast(st.perm()));
    }
    try sys.fsync(fd);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
    try fsyncNameParent(dir, name);
    return fd;
}

/// Append `line` and a newline to `dir/name` in one write, creating the file
/// with mode 0666 less the umask. A symbolic link or non-regular file at the
/// name is refused.
pub fn appendLine(gpa: Allocator, dir: fd_t, name: []const u8, line: []const u8) (Error || Allocator.Error)!void {
    const existing: ?Stat = statAt(dir, name, false) catch |err| switch (err) {
        error.NotFound => null,
        else => |e| return e,
    };
    if (existing) |st| if (regularTypeError(st)) |err| return err;
    const fd = try sys.openat(dir, name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0o666);
    defer sys.close(fd);
    const st = try fstat(fd);
    if (regularTypeError(st)) |err| return err;
    const bytes = try std.mem.concat(gpa, u8, &.{ line, "\n" });
    defer gpa.free(bytes);
    // One write is atomic on Linux only when it completes. A short write
    // (ENOSPC part way through) is rolled back to the size before it, so
    // the list does not gain a partial line. Safe while this process is
    // the only writer; a concurrent append in that window can be shortened.
    sys.writeAll(fd, bytes) catch |err| {
        if (fstat(fd)) |now| {
            if (now.size > st.size and now.size - st.size < bytes.len) {
                _ = linux.ftruncate(fd, @intCast(st.size));
            }
        } else |_| {}
        return err;
    };
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

/// The access ACL forms, most native first: the GPFS native NFSv4 ACL, the
/// generic NFSv4 ACL and the POSIX access ACL. A filesystem may expose one
/// ACL through several of them.
pub const acl_attributes = [_][:0]const u8{ "system.gpfs_nfs4_acl", "system.nfs4_acl", "system.posix_acl_access" };
const posix_access = acl_attributes[2];

/// How access metadata is preserved when copying across file systems.
pub const MoveAcrossPolicy = enum {
    /// Refuse when an ACL form cannot be read or set.
    strict,
    /// Keep bytes and ownership, but allow ACL downgrade when the destination
    /// does not represent the source form.
    portable,
};

/// Options for `moveAcross`.
pub const MoveAcrossOptions = struct {
    /// Access metadata policy for an EXDEV fallback.
    policy: MoveAcrossPolicy = .strict,
};

/// The xattr calls copyAcls makes, as raw system-call results; a test
/// emulates a filesystem's ACL model with its own.
const Xattrs = struct {
    fn get(fd: fd_t, name: [:0]const u8, buf: []u8) usize {
        return linux.fgetxattr(fd, name.ptr, buf.ptr, buf.len);
    }
    fn set(fd: fd_t, name: [:0]const u8, value: []const u8) usize {
        return linux.fsetxattr(fd, name.ptr, value.ptr, value.len, 0);
    }
};

/// Copy the access ACL of `from` onto `to` in the most native form `from`
/// has; the filesystem derives any other form it shows from that one. An
/// ACL that cannot be set on `to` is an error, and so is a form that cannot
/// be read when no other can be copied.
fn copyAcls(comptime X: type, from: fd_t, to: fd_t) Error!void {
    return copyAclsWithPolicy(X, from, to, .strict);
}

fn copyAclsWithPolicy(comptime X: type, from: fd_t, to: fd_t, policy: MoveAcrossPolicy) Error!void {
    var buf: [64 * 1024]u8 = undefined;
    var unreadable = false;
    for (acl_attributes) |name| {
        const n = sys.call(X.get, .{ from, name, &buf }) catch |err| switch (err) {
            error.NoData, error.Unsupported => continue,
            // GPFS answers EINVAL for an NFSv4 form of a file whose ACL is
            // POSIX, which the last form reads.
            error.InvalidArgument => if (policy == .portable) continue else if (std.mem.eql(u8, name, posix_access)) return err else {
                unreadable = true;
                continue;
            },
            else => return err,
        };
        _ = sys.call(X.set, .{ to, name, buf[0..n] }) catch |err| switch (err) {
            error.Unsupported, error.InvalidArgument => if (policy == .portable) return else return err,
            else => return err,
        };
        return;
    }
    if (unreadable and policy == .strict) return error.InvalidArgument;
}

const MoveFaults = struct {
    force_cross_device_rename: bool = false,
    reach_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    fail_fn: ?*const fn (?*anyopaque, []const u8) ?Error = null,
    ctx: ?*anyopaque = null,
};

fn moveFaultsStep(faults: MoveFaults, step: []const u8) Error!void {
    if (faults.reach_fn) |f| f(faults.ctx, step);
    if (faults.fail_fn) |f| if (f(faults.ctx, step)) |err| return err;
}

fn tmpName(base: []const u8, out: *[sys.path_max]u8) Error![]const u8 {
    var rnd: [4]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
    const parent = std.fs.path.dirname(base) orelse ".";
    return std.fmt.bufPrint(out, "{s}/.{s}.{d}.{x:0>8}.tmp", .{
        parent,
        std.fs.path.basename(base),
        linux.getpid(),
        std.mem.readInt(u32, &rnd, .little),
    }) catch error.NameTooLong;
}

/// Sync the directory that receives `name`, which is the parent of `name`
/// when it is nested and `dir` itself otherwise.
fn fsyncNameParent(dir: fd_t, name: []const u8) Error!void {
    const parent = std.fs.path.dirname(name) orelse ".";
    const parent_dir = try openDir(dir, parent, true);
    defer sys.close(parent_dir);
    try sys.fsync(parent_dir);
}

fn setModeOwnerAndAcl(src_fd: fd_t, src: Stat, dst_fd: fd_t, policy: MoveAcrossPolicy) Error!void {
    if ((try fstat(dst_fd)).uid != src.uid or (try fstat(dst_fd)).gid != src.gid) {
        sys.fchown(dst_fd, src.uid, src.gid) catch |err| switch (err) {
            error.AccessDenied => {},
            else => return err,
        };
    }
    try sys.fchmod(dst_fd, @intCast(src.perm()));
    try copyAclsWithPolicy(Xattrs, src_fd, dst_fd, policy);
}

fn copyRegularInto(src_fd: fd_t, src: Stat, dst_dir: fd_t, name: []const u8, policy: MoveAcrossPolicy) Error!fd_t {
    const fd = try sys.openat(dst_dir, name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, 0o600);
    errdefer {
        sys.close(fd);
        sys.unlinkat(dst_dir, name, 0) catch {};
    }
    try copyFd(src_fd, fd);
    try setModeOwnerAndAcl(src_fd, src, fd, policy);
    try sys.fsync(fd);
    return fd;
}

fn copyLinkAt(src_dir: fd_t, src_name: []const u8, dst_dir: fd_t, dst_name: []const u8) Error!void {
    var in: [sys.path_max:0]u8 = undefined;
    var out: [sys.path_max:0]u8 = undefined;
    const n = try sys.call(linux.readlinkat, .{ src_dir, (try sys.z(&in, src_name)).ptr, &out, sys.path_max - 1 });
    out[n] = 0;
    _ = try sys.call(linux.symlinkat, .{ (&out).ptr, dst_dir, (try sys.z(&in, dst_name)).ptr });
}

fn copyTreeContents(gpa: Allocator, src_fd: fd_t, dst_fd: fd_t, policy: MoveAcrossPolicy) (Error || Allocator.Error)!void {
    var it = try DirIter.init(gpa, src_fd);
    defer it.deinit(gpa);
    while (try it.next()) |e| {
        const t = try entryType(src_fd, e);
        switch (t) {
            DT.REG => {
                const opened = try openRegular(src_fd, e.name, false);
                defer sys.close(opened.fd);
                const out = try copyRegularInto(opened.fd, opened.stat, dst_fd, e.name, policy);
                sys.close(out);
            },
            DT.DIR => {
                var zbuf: [sys.path_max:0]u8 = undefined;
                _ = try sys.call(linux.mkdirat, .{ dst_fd, (try sys.z(&zbuf, e.name)).ptr, @as(linux.mode_t, 0o700) });
                const sdir = try openDir(src_fd, e.name, false);
                defer sys.close(sdir);
                const ddir = try openDir(dst_fd, e.name, false);
                defer sys.close(ddir);
                try copyTreeContents(gpa, sdir, ddir, policy);
                const st = try fstat(sdir);
                try setModeOwnerAndAcl(sdir, st, ddir, policy);
                try sys.fsync(ddir);
            },
            DT.LNK => try copyLinkAt(src_fd, e.name, dst_fd, e.name),
            else => return error.NotRegularFile,
        }
    }
    try sys.fsync(dst_fd);
}

fn moveAcrossCopy(gpa: Allocator, src_dir: fd_t, src_name: []const u8, dst_dir: fd_t, dst_name: []const u8, opts: MoveAcrossOptions, faults: MoveFaults) (Error || Allocator.Error)!void {
    const src = try statAt(src_dir, src_name, false);
    var tmp_buf: [sys.path_max]u8 = undefined;
    const tmp = try tmpName(dst_name, &tmp_buf);
    var published = false;
    errdefer if (!published) {
        if (src.isDir()) {
            deleteTree(gpa, dst_dir, tmp) catch {};
        } else {
            sys.unlinkat(dst_dir, tmp, 0) catch {};
        }
    };

    if (src.isReg()) {
        const opened = try openRegular(src_dir, src_name, false);
        defer sys.close(opened.fd);
        const out = try copyRegularInto(opened.fd, opened.stat, dst_dir, tmp, opts.policy);
        sys.close(out);
    } else if (src.isDir()) {
        var zbuf: [sys.path_max:0]u8 = undefined;
        _ = try sys.call(linux.mkdirat, .{ dst_dir, (try sys.z(&zbuf, tmp)).ptr, @as(linux.mode_t, 0o700) });
        const sdir = try openDir(src_dir, src_name, false);
        defer sys.close(sdir);
        const ddir = try openDir(dst_dir, tmp, false);
        defer sys.close(ddir);
        try copyTreeContents(gpa, sdir, ddir, opts.policy);
        try setModeOwnerAndAcl(sdir, src, ddir, opts.policy);
        try sys.fsync(ddir);
    } else if (src.isLink()) {
        try copyLinkAt(src_dir, src_name, dst_dir, tmp);
    } else {
        return error.NotRegularFile;
    }

    try moveFaultsStep(faults, "move.publish");
    try sys.renameat(dst_dir, tmp, dst_dir, dst_name);
    published = true;
    try sys.fsync(dst_dir);
    try moveFaultsStep(faults, "move.remove-source");
    if (src.isDir()) {
        try deleteTree(gpa, src_dir, src_name);
    } else {
        try sys.unlinkat(src_dir, src_name, 0);
    }
    try sys.fsync(src_dir);
}

fn moveAcrossInternal(gpa: Allocator, src_dir: fd_t, src_name: []const u8, dst_dir: fd_t, dst_name: []const u8, opts: MoveAcrossOptions, faults: MoveFaults) (Error || Allocator.Error)!void {
    try moveFaultsStep(faults, "move.rename");
    if (!faults.force_cross_device_rename) {
        if (sys.renameat(src_dir, src_name, dst_dir, dst_name)) |_| {
            try sys.fsync(dst_dir);
            if (src_dir != dst_dir) try sys.fsync(src_dir);
            return;
        } else |err| switch (err) {
            error.CrossDevice => {},
            else => return err,
        }
    }
    try moveAcrossCopy(gpa, src_dir, src_name, dst_dir, dst_name, opts, faults);
}

/// Move `src_dir/src_name` to `dst_dir/dst_name`. On one file system this is
/// a rename; on `error.CrossDevice` it copies to a destination-side temporary
/// path, syncs, atomically publishes with rename, then removes the source.
pub fn moveAcross(gpa: Allocator, src_dir: fd_t, src_name: []const u8, dst_dir: fd_t, dst_name: []const u8, opts: MoveAcrossOptions) (Error || Allocator.Error)!void {
    return moveAcrossInternal(gpa, src_dir, src_name, dst_dir, dst_name, opts, .{});
}

/// Replace the contents of the regular file `dir/name` atomically. The new
/// file keeps the old one's owner (when this process may set it), mode and
/// access ACL, in the most native of the `acl_attributes` forms the old one
/// has; it is written beside the old one, synced, then renamed over it.
pub fn replaceContents(gpa: Allocator, dir: fd_t, name: []const u8, bytes: []const u8) (Error || Allocator.Error)!void {
    const old = try openRegular(dir, name, false);
    defer sys.close(old.fd);
    const tmp = try gpa.print("{s}.tmp.{d}", .{ name, linux.getpid() });
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
    try copyAcls(Xattrs, old.fd, fd);
    try sys.fsync(fd);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
}

/// Create a private 0700 directory `{dir}/{prefix}XXXXXXXX` with a random
/// suffix, retrying on `error.Exists`, and return its path allocated from
/// `gpa`. The caller owns the returned slice.
pub fn mkdtemp(gpa: Allocator, dir: []const u8, prefix: []const u8) (Error || Allocator.Error)![]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_";
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        var rnd: [8]u8 = undefined;
        // A name from bytes getrandom did not fill would not be random.
        const got = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
        if (got != rnd.len) return error.Unexpected;
        for (&rnd) |*b| b.* = alphabet[b.* % alphabet.len];
        const name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, rnd });
        defer gpa.free(name);
        const path = try std.fs.path.join(gpa, &.{ dir, name });
        errdefer gpa.free(path);
        var zb: [sys.path_max:0]u8 = undefined;
        const z = try sys.z(&zb, path);
        _ = sys.call(linux.mkdirat, .{ cwd, z.ptr, @as(linux.mode_t, 0o700) }) catch |err| switch (err) {
            error.Exists => {
                gpa.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.Exists;
}

test "selfExe names this program as a readable regular file" {
    var out: [sys.path_max]u8 = undefined;
    const got = selfExe(&out) orelse return error.TestUnexpectedResult;
    const st = try statAt(cwd, got, true);
    try std.testing.expect(st.isReg());
}

test "mkdtemp creates private 0700 directories with distinct names" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, "{s}/.zig-cache/zig-common-mkdtemp-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    defer deleteTree(gpa, cwd, base) catch {};

    const a = try mkdtemp(gpa, base, "pre-");
    defer gpa.free(a);
    const b_base = try std.fmt.allocPrint(gpa, "{s}/", .{base});
    defer gpa.free(b_base);
    const b = try mkdtemp(gpa, b_base, "pre-");
    defer gpa.free(b);

    try std.testing.expect(!std.mem.eql(u8, a, b));
    const expected_prefix = try std.fmt.allocPrint(gpa, "{s}/pre-", .{base});
    defer gpa.free(expected_prefix);
    try std.testing.expect(std.mem.startsWith(u8, a, expected_prefix));
    try std.testing.expectEqual(expected_prefix.len + 8, a.len);
    try std.testing.expect(std.mem.startsWith(u8, b, expected_prefix));
    try std.testing.expectEqual(expected_prefix.len + 8, b.len);

    const st = try statAt(cwd, a, false);
    try std.testing.expect(st.isDir());
    try std.testing.expectEqual(@as(u32, 0), st.perm() & 0o077);

    const missing = try std.fmt.allocPrint(gpa, "{s}/missing", .{base});
    defer gpa.free(missing);
    try std.testing.expectError(error.NotFound, mkdtemp(gpa, missing, "pre-"));
}

/// The `d_type` values of a directory entry, as `std.os.linux.DT`:
/// `DT.REG`, `DT.DIR`, `DT.LNK`, `DT.UNKNOWN` and the rest.
pub const DT = linux.DT;

/// One entry of a directory, as `DirIter.next` returns it.
pub const Entry = struct {
    /// Points into the iterator's buffer: valid until the next call to
    /// `DirIter.next`.
    name: []const u8,
    /// A `DT` value; `DT.UNKNOWN` when the file system does not say, which
    /// `entryType` resolves.
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

    /// Free the buffer `init` allocated. The descriptor stays open; the
    /// caller closes it.
    pub fn deinit(it: *DirIter, gpa: Allocator) void {
        gpa.free(it.buf);
    }

    /// The next entry, or null after the last one.
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
    var tmp_path_buf: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    const base = try std.mem.print(&tmp_path_buf, "{s}/.zig-cache/zig-common-test-{d}", .{ here, linux.getpid() });
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

fn withFileLimit(bytes: u64, body: *const fn () anyerror!void) anyerror!void {
    var old: linux.rlimit = undefined;
    if (linux.errno(linux.prlimit(0, .FSIZE, null, &old)) != .SUCCESS) return error.Unexpected;
    const lim: linux.rlimit = .{ .cur = @intCast(bytes), .max = old.max };
    if (linux.errno(linux.prlimit(0, .FSIZE, &lim, null)) != .SUCCESS) return error.Unexpected;
    const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.XFSZ, &ign, &prev);
    defer {
        _ = linux.sigaction(.XFSZ, &prev, null);
        _ = linux.prlimit(0, .FSIZE, &old, null);
    }
    try body();
}

test "copyTo leaves an existing file unchanged when the write cannot finish" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-copy-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const dst = try sys.openat(d, "dest", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o640);
    try sys.writeAll(dst, "OLDDATA\n");
    sys.close(dst);
    const srcfd = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try sys.writeAll(srcfd, "NEWDATA-IS-LONGER-THAN-THE-LIMIT\n");
    sys.close(srcfd);
    const opened = try openRegular(d, "src", false);
    defer sys.close(opened.fd);

    const Hold = struct {
        var dir: fd_t = -1;
        var src: fd_t = -1;
        var st: Stat = undefined;
        fn go() Error!void {
            if (copyTo(src, st, dir, "dest")) |fd| sys.close(fd) else |_| {}
        }
    };
    Hold.dir = d;
    Hold.src = opened.fd;
    Hold.st = opened.stat;
    try withFileLimit(8, Hold.go);

    const got = try openRegular(d, "dest", false);
    defer sys.close(got.fd);
    const text = try readAll(gpa, got.fd, 100);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("OLDDATA\n", text);
    try std.testing.expectEqual(@as(u32, 0o640), got.stat.perm());
}

/// Scratch directory under `.zig-cache` whose `xdev` entry is a symlink to a
/// directory on `/dev/shm`, so a nested destination crosses filesystems.
const XdevFixture = struct {
    gpa: Allocator,
    base: []u8,
    ext: []u8,
    d: fd_t,

    fn init(gpa: Allocator, tag: []const u8) !XdevFixture {
        const shm = openDir(cwd, "/dev/shm", true) catch return error.SkipZigTest;
        sys.close(shm);
        var cwd_buf: [sys.path_max]u8 = undefined;
        const here = try realpath(cwd, ".", &cwd_buf);
        const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/zig-common-{s}-{d}", .{ here, tag, linux.getpid() });
        errdefer gpa.free(base);
        const ext = try std.fmt.allocPrint(gpa, "/dev/shm/zig-common-{s}-{d}", .{ tag, linux.getpid() });
        errdefer gpa.free(ext);
        var zb: [sys.path_max:0]u8 = undefined;
        _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
        const d = try openDir(cwd, base, false);
        _ = linux.mkdirat(cwd, (try sys.z(&zb, ext)).ptr, 0o700);
        _ = linux.symlinkat((try sys.z(&zb, ext)).ptr, d, "xdev");
        return .{ .gpa = gpa, .base = base, .ext = ext, .d = d };
    }

    fn deinit(self: XdevFixture) void {
        deleteTree(self.gpa, cwd, self.ext) catch {};
        deleteTree(self.gpa, cwd, self.base) catch {};
        sys.close(self.d);
        self.gpa.free(self.ext);
        self.gpa.free(self.base);
    }
};

test "copyTo supports nested destinations across a symlinked mount" {
    const gpa = std.testing.allocator;
    const fx = try XdevFixture.init(gpa, "copyto-nested");
    defer fx.deinit();
    const d = fx.d;

    const srcfd = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    try sys.writeAll(srcfd, "nested\n");
    sys.close(srcfd);
    const src = try openRegular(d, "src", false);
    defer sys.close(src.fd);

    const outfd = try copyTo(src.fd, src.stat, d, "xdev/dest");
    defer sys.close(outfd);
    const got = try openRegular(d, "xdev/dest", false);
    defer sys.close(got.fd);
    const text = try readAll(gpa, got.fd, 64);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("nested\n", text);
}

test "appendLine does not leave a partial line when the write cannot finish" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-append-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const f = try sys.openat(d, "list", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try sys.writeAll(f, "hi\n");
    sys.close(f);
    const Hold = struct {
        var dir: fd_t = -1;
        fn go() Error!void {
            appendLine(std.testing.allocator, dir, "list", "this line is far longer than the file size limit") catch {};
        }
    };
    Hold.dir = d;
    try withFileLimit(8, Hold.go);
    const got = try openRegular(d, "list", false);
    defer sys.close(got.fd);
    const text = try readAll(gpa, got.fd, 200);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hi\n", text);
}

test "appendLine reports not a regular file for a FIFO target" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-append-fifo-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    _ = try sys.call(linux.mknodat, .{ d, "pipe", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    try std.testing.expectError(error.NotRegularFile, appendLine(gpa, d, "pipe", "x"));
    try std.testing.expectEqualStrings("not a regular file", sys.describe(error.NotRegularFile));
}

test "copyTo copies the whole source and leaves its offset" {
    const gpa = std.testing.allocator;
    var tmp_path_buf: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    const base = try std.mem.print(&tmp_path_buf, "{s}/.zig-cache/zig-common-copy-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const f = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    try sys.writeAll(f, "header\nbody\n");
    sys.close(f);
    const src = try openRegular(d, "src", false);
    defer sys.close(src.fd);
    var head: [7]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), try sys.read(src.fd, &head));
    sys.close(try copyTo(src.fd, src.stat, d, "dst"));
    const dst = try openRegular(d, "dst", false);
    defer sys.close(dst.fd);
    const got = try readAll(gpa, dst.fd, 100);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("header\nbody\n", got);
    try std.testing.expectEqual(@as(u64, 7), linux.lseek(src.fd, 0, linux.SEEK.CUR));
}

test "openRegular reports IsDir for a directory" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-open-regular-dir-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    _ = linux.mkdirat(d, "subdir", 0o700);
    try std.testing.expectError(error.IsDir, openRegular(d, "subdir", false));
    try std.testing.expectEqualStrings("[Errno 21] Is a directory", sys.describe(error.IsDir));
}

test "openRegular reports not a regular file for a FIFO" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-open-regular-fifo-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    _ = try sys.call(linux.mknodat, .{ d, "pipe", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    try std.testing.expectError(error.NotRegularFile, openRegular(d, "pipe", false));
    try std.testing.expectEqualStrings("not a regular file", sys.describe(error.NotRegularFile));
}

test "copyTo reports not a regular file for a FIFO destination" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-copy-fifo-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const srcfd = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    try sys.writeAll(srcfd, "text\n");
    sys.close(srcfd);
    const src = try openRegular(d, "src", false);
    defer sys.close(src.fd);
    _ = try sys.call(linux.mknodat, .{ d, "dst", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    try std.testing.expectError(error.NotRegularFile, copyTo(src.fd, src.stat, d, "dst"));
    try std.testing.expectEqualStrings("not a regular file", sys.describe(error.NotRegularFile));
}

/// A filesystem's answer to each ACL form, GPFS native, generic NFSv4 and
/// POSIX access: the bytes of a form it shows, or its errno. Any other name
/// is unsupported. Records what copyAcls sets.
const FakeAcls = struct {
    const Answer = union(enum) { bytes: []const u8, errno: linux.E };
    const forms = [_][]const u8{ "system.gpfs_nfs4_acl", "system.nfs4_acl", "system.posix_acl_access" };
    var answers: [3]Answer = undefined;
    var sets: usize = 0;
    var set_name: []const u8 = "";
    var set_buf: [32]u8 = undefined;
    var set_len: usize = 0;

    fn reset(a: [3]Answer) void {
        answers = a;
        sets = 0;
        set_name = "";
        set_len = 0;
    }
    fn rc(e: linux.E) usize {
        return @bitCast(-@as(isize, @backingInt(e)));
    }
    fn get(_: fd_t, name: [:0]const u8, buf: []u8) usize {
        for (forms, answers) |form, answer| if (std.mem.eql(u8, form, name)) return switch (answer) {
            .bytes => |b| blk: {
                @memcpy(buf[0..b.len], b);
                break :blk b.len;
            },
            .errno => |e| rc(e),
        };
        return rc(.OPNOTSUPP);
    }
    fn set(_: fd_t, name: [:0]const u8, value: []const u8) usize {
        sets += 1;
        set_name = name;
        @memcpy(set_buf[0..value.len], value);
        set_len = value.len;
        return 0;
    }
};

test "replaceContents copies the most native ACL form, GPFS's included" {
    const F = FakeAcls;
    const unsupported: F.Answer = .{ .errno = .OPNOTSUPP };
    const cases = [_]struct { answers: [3]F.Answer, name: []const u8, bytes: []const u8 }{
        // GPFS: its native NFSv4 ACL alone.
        .{ .answers = .{ .{ .bytes = "gpfs" }, unsupported, unsupported }, .name = "system.gpfs_nfs4_acl", .bytes = "gpfs" },
        // GPFS showing the same ACL through the generic and POSIX forms too.
        .{ .answers = .{ .{ .bytes = "gpfs" }, .{ .bytes = "generic" }, .{ .bytes = "posix" } }, .name = "system.gpfs_nfs4_acl", .bytes = "gpfs" },
        // An NFSv4 mount.
        .{ .answers = .{ unsupported, .{ .bytes = "nfs4" }, unsupported }, .name = "system.nfs4_acl", .bytes = "nfs4" },
        // A POSIX ACL on GPFS, which answers EINVAL for the NFSv4 forms.
        .{ .answers = .{ .{ .errno = .INVAL }, .{ .errno = .INVAL }, .{ .bytes = "posix" } }, .name = "system.posix_acl_access", .bytes = "posix" },
    };
    for (cases) |c| {
        F.reset(c.answers);
        try copyAcls(F, 0, 1);
        try std.testing.expectEqual(@as(usize, 1), F.sets);
        try std.testing.expectEqualStrings(c.name, F.set_name);
        try std.testing.expectEqualStrings(c.bytes, F.set_buf[0..F.set_len]);
    }
    // No ACL at all.
    F.reset(.{ unsupported, unsupported, .{ .errno = .NODATA } });
    try copyAcls(F, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), F.sets);
    // A form that could not be read and no other: refused, not dropped.
    F.reset(.{ .{ .errno = .INVAL }, unsupported, .{ .errno = .NODATA } });
    try std.testing.expectError(error.InvalidArgument, copyAcls(F, 0, 1));
}

test "copyAcls portable mode allows an unsupported destination ACL form" {
    const F = FakeAcls;
    const unsupported: F.Answer = .{ .errno = .OPNOTSUPP };
    F.reset(.{ .{ .bytes = "gpfs" }, unsupported, unsupported });
    const Portable = struct {
        fn get(fd: fd_t, name: [:0]const u8, buf: []u8) usize {
            return F.get(fd, name, buf);
        }
        fn set(_: fd_t, _: [:0]const u8, _: []const u8) usize {
            return @bitCast(-@as(isize, @backingInt(linux.E.OPNOTSUPP)));
        }
    };
    try copyAclsWithPolicy(Portable, 0, 1, .portable);
    try std.testing.expectError(error.Unsupported, copyAclsWithPolicy(Portable, 0, 1, .strict));
}

const MoveProbe = struct {
    seen: std.ArrayList([]const u8) = .empty,
    fail_step: []const u8 = "",
    fail_error: ?Error = null,

    fn reach(ctx: ?*anyopaque, step: []const u8) void {
        const self: *MoveProbe = @ptrCast(@alignCast(ctx.?));
        self.seen.append(std.testing.allocator, std.testing.allocator.dupe(u8, step) catch return) catch {};
    }
    fn fail(ctx: ?*anyopaque, step: []const u8) ?Error {
        const self: *MoveProbe = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, step, self.fail_step)) return self.fail_error;
        return null;
    }
    fn hit(self: MoveProbe, step: []const u8) bool {
        for (self.seen.items) |s| if (std.mem.eql(u8, s, step)) return true;
        return false;
    }
    fn deinit(self: *MoveProbe) void {
        for (self.seen.items) |s| std.testing.allocator.free(s);
        self.seen.deinit(std.testing.allocator);
    }
};

test "moveAcross falls back on EXDEV and removes the source after publish" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-move-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const srcf = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try sys.writeAll(srcf, "payload\n");
    sys.close(srcf);

    var probe = MoveProbe{};
    defer probe.deinit();
    try moveAcrossInternal(gpa, d, "src", d, "dst", .{ .policy = .strict }, .{
        .force_cross_device_rename = true,
        .reach_fn = MoveProbe.reach,
        .fail_fn = MoveProbe.fail,
        .ctx = &probe,
    });
    try std.testing.expect(probe.hit("move.rename"));
    try std.testing.expect(probe.hit("move.publish"));
    try std.testing.expect(probe.hit("move.remove-source"));
    try std.testing.expectError(error.NotFound, statAt(d, "src", false));
    const dst = try openRegular(d, "dst", false);
    defer sys.close(dst.fd);
    const text = try readAll(gpa, dst.fd, 100);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("payload\n", text);
}

test "moveAcross keeps the source when publish fails before rename" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-move-fail-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    const srcf = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try sys.writeAll(srcf, "payload\n");
    sys.close(srcf);

    var probe = MoveProbe{ .fail_step = "move.publish", .fail_error = error.NoSpace };
    defer probe.deinit();
    try std.testing.expectError(error.NoSpace, moveAcrossInternal(gpa, d, "src", d, "dst", .{ .policy = .strict }, .{
        .force_cross_device_rename = true,
        .reach_fn = MoveProbe.reach,
        .fail_fn = MoveProbe.fail,
        .ctx = &probe,
    }));
    const src = try openRegular(d, "src", false);
    defer sys.close(src.fd);
    const text = try readAll(gpa, src.fd, 100);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("payload\n", text);
    try std.testing.expectError(error.NotFound, statAt(d, "dst", false));
}

test "fsx public helpers return expected errors on bad paths and descriptors" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-fsx-err-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }

    const reg_fd = try sys.openat(d, "reg", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try sys.writeAll(reg_fd, "0123456789");
    sys.close(reg_fd);
    var dir_z: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(d, (try sys.z(&dir_z, "sub")).ptr, 0o700);
    var lnk_z: [sys.path_max:0]u8 = undefined;
    _ = linux.symlinkat("reg", d, (try sys.z(&lnk_z, "lnk")).ptr);
    var dlnk_z: [sys.path_max:0]u8 = undefined;
    _ = linux.symlinkat("sub", d, (try sys.z(&dlnk_z, "dlnk")).ptr);

    try std.testing.expectError(error.InvalidArgument, fstat(-1));
    try std.testing.expectError(error.NotFound, statAt(d, "missing", false));
    var out: [sys.path_max]u8 = undefined;
    try std.testing.expectError(error.NotFound, realpathFd(-1, &out));
    try std.testing.expectError(error.NotFound, realpath(d, "missing", &out));

    try std.testing.expectError(error.NotFound, openRegular(d, "missing", false));
    try std.testing.expectError(error.SymLink, openRegular(d, "lnk", false));
    try std.testing.expectError(error.IsDir, openRegular(d, "sub", false));

    try std.testing.expectError(error.NotFound, openDir(d, "missing", false));
    try std.testing.expectError(error.NotDir, openDir(d, "reg", false));
    try std.testing.expectError(error.NotDir, openDir(d, "dlnk", false));

    const opened = try openRegular(d, "reg", false);
    defer sys.close(opened.fd);
    try std.testing.expectError(error.SymLink, copyTo(opened.fd, opened.stat, d, "lnk"));
    try std.testing.expectError(error.IsDir, copyTo(opened.fd, opened.stat, d, "sub"));
    try std.testing.expectError(error.SymLink, appendLine(gpa, d, "lnk", "x"));
    try std.testing.expectError(error.IsDir, appendLine(gpa, d, "sub", "x"));
    try std.testing.expectError(error.StreamTooLong, readAll(gpa, opened.fd, 4));
    try std.testing.expectError(error.NotFound, moveAcross(gpa, d, "missing", d, "dst", .{}));
    try std.testing.expectError(error.NotFound, replaceContents(gpa, d, "missing", "x"));
    try std.testing.expectError(error.SymLink, replaceContents(gpa, d, "lnk", "x"));
    try std.testing.expectError(error.NotFound, entryType(d, .{ .name = "missing", .type = DT.UNKNOWN }));
    var bad_it = try DirIter.init(gpa, -1);
    defer bad_it.deinit(gpa);
    try std.testing.expectError(error.InvalidArgument, bad_it.next());
    try std.testing.expectError(error.NotFound, deleteTree(gpa, d, "missing"));
}

test "moveAcross reports not a regular file for a FIFO source on EXDEV fallback" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-move-fifo-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    _ = try sys.call(linux.mknodat, .{ d, "pipe", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    try std.testing.expectError(error.NotRegularFile, moveAcrossInternal(gpa, d, "pipe", d, "dst", .{ .policy = .strict }, .{
        .force_cross_device_rename = true,
    }));
    try std.testing.expectEqualStrings("not a regular file", sys.describe(error.NotRegularFile));
}

test "moveAcross reports not a regular file for a FIFO entry in a moved tree" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-move-tree-fifo-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const d = try openDir(cwd, base, false);
    defer {
        deleteTree(gpa, cwd, base) catch {};
        sys.close(d);
    }
    _ = linux.mkdirat(d, "tree", 0o700);
    const tree = try openDir(d, "tree", false);
    defer sys.close(tree);
    _ = try sys.call(linux.mknodat, .{ tree, "pipe", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });

    try std.testing.expectError(error.NotRegularFile, moveAcrossInternal(gpa, d, "tree", d, "dst", .{ .policy = .strict }, .{
        .force_cross_device_rename = true,
    }));
    try std.testing.expectEqualStrings("not a regular file", sys.describe(error.NotRegularFile));
}
