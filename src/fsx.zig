//! File handling with the checks done on the open file descriptor, not on a
//! path that can change between a check and its use.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const atomic = @import("atomic.zig");
const test_support = @import("test_support.zig");
const pytext = @import("pytext.zig");

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
/// following symbolic links. The caller owns the returned slice. A
/// relative path is `error.NotFound` when that directory has been
/// removed, as `os.getcwd` reports.
pub fn absPath(gpa: Allocator, path: []const u8) (Error || Allocator.Error)![]u8 {
    if (std.mem.startsWith(u8, path, "/")) return normPath(gpa, path);
    var buf: [sys.path_max]u8 = undefined;
    const cwd_path = try getcwd(&buf);
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

test "absPath reports a removed working directory" {
    const gpa = std.testing.allocator;
    var here_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &here_buf);
    var hz: [sys.path_max:0]u8 = undefined;
    const here_z = try sys.z(&hz, here);
    var gb: [sys.path_max]u8 = undefined;
    const gone = try std.fmt.bufPrint(&gb, "{s}/.zig-cache/zig-common-abspath-gone-{d}", .{ here, linux.getpid() });
    var gz: [sys.path_max:0]u8 = undefined;
    const gone_z = try sys.z(&gz, gone);
    try std.testing.expectEqual(@as(usize, 0), linux.mkdirat(cwd, gone_z.ptr, 0o700));
    try std.testing.expectEqual(@as(usize, 0), linux.chdir(gone_z.ptr));
    defer _ = linux.chdir(here_z.ptr);
    try sys.unlinkat(cwd, gone, linux.AT.REMOVEDIR);

    // os.path.abspath raises ENOENT from getcwd. A relative path with a
    // "." segment still needs that directory.
    try std.testing.expectError(error.NotFound, absPath(gpa, "sub/./file"));
    try std.testing.expectEqual(linux.E.NOENT, sys.last_errno);

    const abs = try absPath(gpa, "/tmp/./x/../y");
    defer gpa.free(abs);
    try std.testing.expectEqualStrings("/tmp/y", abs);
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
/// to a temporary file in `dir`, synced and closed, then renamed over
/// `name`, so a short write (a full disk, a file-size limit) leaves an
/// existing destination as it was and does not publish a partial file
/// under `name`. An existing regular file keeps its owner, when this
/// process may set it, and its mode; a new file gets the source's
/// permission bits less the umask. A destination that is a symbolic link
/// or not a regular file is refused. A destination with other hard links
/// keeps those links on the previous inode; `name` is the new inode.
/// A failed close before that rename is returned with `sys.last_errno`
/// set, the destination is left as it was, and the temporary file is
/// removed. A write lost on a network file system may be reported only
/// by the close. The temporary descriptor is closed once on every path.
/// A close that EINTR interrupts is not retried, as Linux has freed the
/// descriptor, and is not an error, as `sys.result` treats EINTR. The
/// directory that receives `name` is synced and closed after the rename.
/// A failed close there is returned with `sys.last_errno` set and `name`
/// is left as the rename made it. Both closes are replaceable through
/// `publish_ops`. The temporary descriptor is duplicated before that
/// close, and the duplicate is returned. It shares the open file
/// description, so the close of one still reports a lost network write
/// and the duplicate stays at the end the write left. It still refers
/// to the inode that was written if `name` is replaced after the rename.
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
    var open = true;
    var done = false;
    errdefer {
        if (open) {
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            _ = publish_ops.close(fd);
        }
        if (!done) {
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            sys.unlinkat(dir, tmp, 0) catch {};
        }
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
    // Same open file description as fd, so the offset stays where the
    // write left it, and CLOEXEC matches openat. Reopening tmp by name
    // would let another actor swap that name after the close.
    const published: fd_t = @intCast(try sys.call(linux.fcntl, .{
        fd,
        linux.F.DUPFD_CLOEXEC,
        @as(usize, 0),
    }));
    errdefer {
        // The error being returned keeps its errno.
        const saved = sys.last_errno;
        defer sys.last_errno = saved;
        sys.close(published);
    }
    // Once, before the rename. A later failure must not close again.
    open = false;
    try closeBeforePublish(fd);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
    try fsyncNameParent(dir, name);
    return published;
}

/// Append `line` and a newline to `dir/name` in one write, creating the file
/// with mode 0666 less the umask. A symbolic link or non-regular file at the
/// name is refused. The descriptor is closed once on every path. A failed
/// close after the write is returned with `sys.last_errno` set to its errno.
/// A close that EINTR interrupts is not retried, as Linux has freed the
/// descriptor, and is not an error, as `sys.result` treats EINTR. A write
/// lost on NFS may be reported only by the close. The line may or may not
/// be present when that close fails, because the descriptor is already gone
/// and the file cannot be shortened back to its old size. A short write is
/// still rolled back to the size before it. The cleanup close on that path
/// and on any earlier error ignores its result so the earlier error keeps
/// its errno. The close is replaceable through `publish_ops`.
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
    var open = true;
    defer {
        if (open) {
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            _ = publish_ops.close(fd);
        }
    }
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
    // The descriptor is gone after this close, failed or not, so the file
    // cannot be shortened back to `st.size`. The line may or may not remain.
    open = false;
    try closeBeforePublish(fd);
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
    trace_fn: ?*const fn (?*anyopaque, MoveCall) void = null,
    ctx: ?*anyopaque = null,
};

/// A rename or directory sync that moveAcross completed; the descriptor of
/// a sync is open only while the trace runs.
const MoveCall = union(enum) {
    rename,
    fsync: fd_t,
};

fn moveFaultsStep(faults: MoveFaults, step: []const u8) Error!void {
    if (faults.reach_fn) |f| f(faults.ctx, step);
    if (faults.fail_fn) |f| if (f(faults.ctx, step)) |err| return err;
}

fn moveRename(faults: MoveFaults, old_dir: fd_t, old_name: []const u8, new_dir: fd_t, new_name: []const u8) Error!void {
    try sys.renameat(old_dir, old_name, new_dir, new_name);
    if (faults.trace_fn) |f| f(faults.ctx, .rename);
}

fn moveFsync(faults: MoveFaults, dir: fd_t) Error!void {
    try sys.fsync(dir);
    if (faults.trace_fn) |f| f(faults.ctx, .{ .fsync = dir });
}

/// `fsyncNameParent` for moveAcross, reported to its trace.
fn moveFsyncNameParent(faults: MoveFaults, dir: fd_t, name: []const u8) Error!void {
    const parent_dir = try openDir(dir, std.fs.path.dirname(name) orelse ".", true);
    var open = true;
    errdefer if (open) {
        // The error being returned keeps its errno.
        const saved = sys.last_errno;
        defer sys.last_errno = saved;
        _ = publish_ops.close(parent_dir);
    };
    try moveFsync(faults, parent_dir);
    open = false;
    try closeBeforePublish(parent_dir);
}

/// Whether `a_dir/a_name` and `b_dir/b_name` name entries of the same
/// directory by the same path. False does not mean the directories differ.
fn sameNameParent(a_dir: fd_t, a_name: []const u8, b_dir: fd_t, b_name: []const u8) bool {
    const a = std.fs.path.dirname(a_name) orelse ".";
    const b = std.fs.path.dirname(b_name) orelse ".";
    return a_dir == b_dir and std.mem.eql(u8, a, b);
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
    var open = true;
    errdefer if (open) {
        // The error being returned keeps its errno.
        const saved = sys.last_errno;
        defer sys.last_errno = saved;
        _ = publish_ops.close(parent_dir);
    };
    try sys.fsync(parent_dir);
    open = false;
    try closeBeforePublish(parent_dir);
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

/// The close of a file about to be published by `replaceContents` or by the
/// cross-device copy inside `moveAcross`, the close after `appendLine`
/// writes, and the close of a directory after the sync that makes that
/// directory durable, as a raw system-call result. Replaceable in the same
/// builds as `atomic.ops`; constant real calls in any other build. A close
/// that EINTR interrupts is not retried.
pub const PublishOps = struct {
    close: *const fn (fd: fd_t) usize = realPublishClose,
};

var test_publish_ops: PublishOps = .{};
const real_publish_ops: PublishOps = .{};
/// The close in use. A replaceable build may assign through it
/// (`publish_ops.* = ...`); any other build points it at constant real calls.
pub const publish_ops = if (atomic.replaceable) &test_publish_ops else &real_publish_ops;

fn realPublishClose(fd: fd_t) usize {
    return linux.close(fd);
}

/// Close `fd` once. `replaceContents` and the cross-device copy inside
/// `moveAcross` do this before the file is published; `appendLine` does this
/// after the write; a directory is closed after the sync that makes it
/// durable. EINTR is success and is not retried, as Linux has freed the
/// descriptor and `sys.result` does not treat EINTR as an error. Any other
/// errno is returned with `sys.last_errno` set. The caller does not close
/// `fd` again.
fn closeBeforePublish(fd: fd_t) Error!void {
    _ = try sys.result(publish_ops.close(fd));
}

fn copyRegularInto(src_fd: fd_t, src: Stat, dst_dir: fd_t, name: []const u8, policy: MoveAcrossPolicy) Error!void {
    const fd = try sys.openat(dst_dir, name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, 0o600);
    var open = true;
    errdefer {
        if (open) _ = publish_ops.close(fd);
        // The error being returned keeps its errno.
        const saved = sys.last_errno;
        defer sys.last_errno = saved;
        sys.unlinkat(dst_dir, name, 0) catch {};
    }
    try copyFd(src_fd, fd);
    try setModeOwnerAndAcl(src_fd, src, fd, policy);
    try sys.fsync(fd);
    open = false;
    try closeBeforePublish(fd);
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
                try copyRegularInto(opened.fd, opened.stat, dst_fd, e.name, policy);
            },
            DT.DIR => {
                var zbuf: [sys.path_max:0]u8 = undefined;
                _ = try sys.call(linux.mkdirat, .{ dst_fd, (try sys.z(&zbuf, e.name)).ptr, @as(linux.mode_t, 0o700) });
                const sdir = try openDir(src_fd, e.name, false);
                defer sys.close(sdir);
                const ddir = try openDir(dst_fd, e.name, false);
                var dopen = true;
                errdefer if (dopen) {
                    // The error being returned keeps its errno.
                    const saved = sys.last_errno;
                    defer sys.last_errno = saved;
                    _ = publish_ops.close(ddir);
                };
                try copyTreeContents(gpa, sdir, ddir, policy);
                const st = try fstat(sdir);
                try setModeOwnerAndAcl(sdir, st, ddir, policy);
                try sys.fsync(ddir);
                dopen = false;
                try closeBeforePublish(ddir);
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
        // The error being returned keeps its errno.
        const saved = sys.last_errno;
        defer sys.last_errno = saved;
        if (src.isDir()) {
            deleteTree(gpa, dst_dir, tmp) catch {};
        } else {
            sys.unlinkat(dst_dir, tmp, 0) catch {};
        }
    };

    if (src.isReg()) {
        const opened = try openRegular(src_dir, src_name, false);
        defer sys.close(opened.fd);
        try copyRegularInto(opened.fd, opened.stat, dst_dir, tmp, opts.policy);
    } else if (src.isDir()) {
        var zbuf: [sys.path_max:0]u8 = undefined;
        _ = try sys.call(linux.mkdirat, .{ dst_dir, (try sys.z(&zbuf, tmp)).ptr, @as(linux.mode_t, 0o700) });
        const sdir = try openDir(src_dir, src_name, false);
        defer sys.close(sdir);
        const ddir = try openDir(dst_dir, tmp, false);
        var dopen = true;
        errdefer if (dopen) {
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            _ = publish_ops.close(ddir);
        };
        try copyTreeContents(gpa, sdir, ddir, opts.policy);
        try setModeOwnerAndAcl(sdir, src, ddir, opts.policy);
        try sys.fsync(ddir);
        dopen = false;
        try closeBeforePublish(ddir);
    } else if (src.isLink()) {
        try copyLinkAt(src_dir, src_name, dst_dir, tmp);
    } else {
        return error.NotRegularFile;
    }

    try moveFaultsStep(faults, "move.publish");
    try moveRename(faults, dst_dir, tmp, dst_dir, dst_name);
    published = true;
    try moveFsyncNameParent(faults, dst_dir, dst_name);
    try moveFaultsStep(faults, "move.remove-source");
    if (src.isDir()) {
        try deleteTree(gpa, src_dir, src_name);
    } else {
        try sys.unlinkat(src_dir, src_name, 0);
    }
    try moveFsyncNameParent(faults, src_dir, src_name);
}

fn moveAcrossInternal(gpa: Allocator, src_dir: fd_t, src_name: []const u8, dst_dir: fd_t, dst_name: []const u8, opts: MoveAcrossOptions, faults: MoveFaults) (Error || Allocator.Error)!void {
    try moveFaultsStep(faults, "move.rename");
    if (!faults.force_cross_device_rename) {
        if (moveRename(faults, src_dir, src_name, dst_dir, dst_name)) |_| {
            try moveFsyncNameParent(faults, dst_dir, dst_name);
            if (!sameNameParent(src_dir, src_name, dst_dir, dst_name)) try moveFsyncNameParent(faults, src_dir, src_name);
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
/// path, syncs and closes each copied regular file and each copied
/// directory, then atomically publishes with rename and removes the source.
/// A failed close before that rename is returned with `sys.last_errno` set,
/// the destination name is left as it was, and the temporary path is
/// removed. The parent directory is synced and closed after the rename. A
/// failed close there is returned and the published name is left as the
/// rename made it. Each of these descriptors is closed once. A close that
/// EINTR interrupts is not retried and is not an error, as `sys.result`
/// treats EINTR. The close is replaceable through `publish_ops`.
pub fn moveAcross(gpa: Allocator, src_dir: fd_t, src_name: []const u8, dst_dir: fd_t, dst_name: []const u8, opts: MoveAcrossOptions) (Error || Allocator.Error)!void {
    return moveAcrossInternal(gpa, src_dir, src_name, dst_dir, dst_name, opts, .{});
}

/// Replace the contents of the regular file `dir/name` atomically. The new
/// file keeps the old one's owner (when this process may set it), mode and
/// access ACL, in the most native of the `acl_attributes` forms the old one
/// has. The bytes are written beside the old file, synced and closed, then
/// renamed over it. A failed write, fchmod, fsync or close is returned with
/// `sys.last_errno` set to its errno; the name is left as it was and the
/// temporary file is removed. A write lost on NFS may be reported only by
/// the close. The temporary descriptor is closed once on every path. A close
/// that EINTR interrupts is not retried, as Linux has freed the descriptor,
/// and is not an error, as `sys.result` treats EINTR. The close is
/// replaceable through `publish_ops`.
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
    var open = true;
    var done = false;
    defer {
        if (open) _ = publish_ops.close(fd);
        if (!done) {
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            sys.unlinkat(dir, tmp, 0) catch {};
        }
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
    open = false;
    try closeBeforePublish(fd);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
}

/// Eight random characters from `a-z`, `0-9` and `_`, the alphabet of
/// Python's `tempfile`.
fn randomName() Error![8]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_";
    var rnd: [8]u8 = undefined;
    // A name from bytes getrandom did not fill would not be random.
    const got = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
    if (got != rnd.len) return error.Unexpected;
    for (&rnd) |*b| b.* = alphabet[b.* % alphabet.len];
    return rnd;
}

/// Create a private 0700 directory `{dir}/{prefix}XXXXXXXX` with a random
/// suffix, retrying on `error.Exists`, and return its path allocated from
/// `gpa`. The caller owns the returned slice.
pub fn mkdtemp(gpa: Allocator, dir: []const u8, prefix: []const u8) (Error || Allocator.Error)![]u8 {
    var why: atomic.Why = .{};
    defer why.deinit(gpa);
    return mkdtempReport(gpa, dir, prefix, &why);
}

/// mkdtemp that names the directory it failed in: on failure `why` holds
/// the OSError text Python gives, `pytext.osError` of the path. When the
/// failure is the create itself, the path is the directory joined with the
/// name it tried, random part included, in one repr as Python writes it.
pub fn mkdtempReport(gpa: Allocator, dir: []const u8, prefix: []const u8, why: *atomic.Why) (Error || Allocator.Error)![]u8 {
    return mkdtempReportInner(gpa, dir, prefix, why) catch |err| {
        if (why.msg.len == 0) reportMkError(gpa, why, err, dir, null);
        return err;
    };
}

fn reportMkError(gpa: Allocator, why: *atomic.Why, err: anyerror, dir: []const u8, name: ?[]const u8) void {
    why.deinit(gpa);
    const path = if (name) |n| std.fs.path.join(gpa, &.{ dir, n }) catch return else dir;
    defer if (name != null) gpa.free(path);
    why.msg = pytext.osError(gpa, err, path) catch return;
}

fn mkdtempReportInner(gpa: Allocator, dir: []const u8, prefix: []const u8, why: *atomic.Why) (Error || Allocator.Error)![]u8 {
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        const rnd = try randomName();
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
            else => {
                reportMkError(gpa, why, err, dir, name);
                return err;
            },
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

/// Fail unless `msg` is `pytext.osError` of `err` and the path a create
/// tried, `dir` joined with `prefix` and eight characters of the random
/// alphabet. Those characters need no escape and do not change the quote
/// repr picks, so they are the eight bytes before the closing quote.
fn expectTriedPath(gpa: Allocator, msg: []const u8, err: anyerror, dir: []const u8, prefix: []const u8) !void {
    try std.testing.expect(msg.len > 9);
    const rnd = msg[msg.len - 9 .. msg.len - 1];
    for (rnd) |b| try std.testing.expect(std.ascii.isLower(b) or std.ascii.isDigit(b) or b == '_');
    const name = try std.mem.concat(gpa, u8, &.{ prefix, rnd });
    defer gpa.free(name);
    const tried = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(tried);
    const want = try pytext.osError(gpa, err, tried);
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, msg);
}

test "mkdtempReport names the path a failed create tried" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-mkdtemp-report-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    defer sys.unlinkat(cwd, sys.z(&zb, base) catch "", linux.AT.REMOVEDIR) catch {};

    var why: atomic.Why = .{};
    defer why.deinit(gpa);
    // a missing directory: the whole path the create tried is in one repr
    const missing = try std.fmt.allocPrint(gpa, "{s}/missing", .{base});
    defer gpa.free(missing);
    try std.testing.expectError(error.NotFound, mkdtempReport(gpa, missing, "pre-", &why));
    try expectTriedPath(gpa, why.msg, error.NotFound, missing, "pre-");

    // a quote in the directory makes repr pick the other quote for all of it
    const quoted = try std.fmt.allocPrint(gpa, "{s}/it's", .{base});
    defer gpa.free(quoted);
    try std.testing.expectError(error.NotFound, mkdtempReport(gpa, quoted, "pre-", &why));
    try std.testing.expect(std.mem.endsWith(u8, why.msg, "\""));
    try expectTriedPath(gpa, why.msg, error.NotFound, quoted, "pre-");

    // a file in the parent's place: ENOTDIR's errno text, the same path
    const blocker = try std.fmt.allocPrint(gpa, "{s}/blocker", .{base});
    defer gpa.free(blocker);
    const fd = try sys.openat(cwd, blocker, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys.writeAll(fd, "x") catch {};
    sys.close(fd);
    var zb2: [sys.path_max:0]u8 = undefined;
    defer sys.unlinkat(cwd, sys.z(&zb2, blocker) catch "", 0) catch {};
    const under = try std.fmt.allocPrint(gpa, "{s}/blocker/sub", .{base});
    defer gpa.free(under);
    try std.testing.expectError(error.NotDir, mkdtempReport(gpa, under, "pre-", &why));
    try expectTriedPath(gpa, why.msg, error.NotDir, under, "pre-");
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

/// A file `mkstemp` made.
pub const TempFile = struct {
    /// Open for reading and writing, close-on-exec.
    fd: fd_t,
    /// The path, allocated from the `gpa` given to `mkstemp`.
    path: []u8,
};

/// `tempfile.mkstemp(prefix=prefix, dir=dir)`: a new file
/// `{dir}/{prefix}XXXXXXXX` with a random suffix, mode 0600, opened for
/// reading and writing without following a link. Like Python, it makes
/// `dir` absolute with `absPath` first, so the path is absolute for a
/// relative `dir` too. Python tries 10000 names and goes on only after a
/// name that exists. When the open fails with another error, `failed`
/// receives the path that was refused, for the caller to format with
/// `pytext.osError`, as Python's error names it. It is null when no name
/// was tried or when every name existed.
pub fn mkstemp(gpa: Allocator, dir: []const u8, prefix: []const u8, failed: *?[]u8) (Error || Allocator.Error)!TempFile {
    failed.* = null;
    const abs = try absPath(gpa, dir);
    defer gpa.free(abs);
    var tries: usize = 0;
    while (tries < 10000) : (tries += 1) {
        const rnd = try randomName();
        const name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, rnd });
        defer gpa.free(name);
        const path = try std.fs.path.join(gpa, &.{ abs, name });
        const fd = sys.openat(cwd, path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch |err| switch (err) {
            error.Exists => {
                gpa.free(path);
                continue;
            },
            else => {
                failed.* = path;
                return err;
            },
        };
        return .{ .fd = fd, .path = path };
    }
    return error.Exists;
}

test "mkstemp makes a private file and names the path it was refused" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, "{s}/.zig-cache/zig-common-mkstemp-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    defer deleteTree(gpa, cwd, base) catch {};

    var failed: ?[]u8 = null;
    const made = try mkstemp(gpa, base, "pre-", &failed);
    defer gpa.free(made.path);
    defer sys.close(made.fd);
    try std.testing.expect(failed == null);
    const expected_prefix = try std.fmt.allocPrint(gpa, "{s}/pre-", .{base});
    defer gpa.free(expected_prefix);
    try std.testing.expect(std.mem.startsWith(u8, made.path, expected_prefix));
    try std.testing.expectEqual(expected_prefix.len + 8, made.path.len);
    const st = try fstat(made.fd);
    try std.testing.expect(st.isReg());
    try std.testing.expectEqual(@as(u32, 0o600), st.perm());
    try sys.writeAll(made.fd, "x");

    const missing = try std.fmt.allocPrint(gpa, "{s}/missing", .{base});
    defer gpa.free(missing);
    try std.testing.expectError(error.NotFound, mkstemp(gpa, missing, "pre-", &failed));
    defer if (failed) |p| gpa.free(p);
    const path = failed orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, path, missing));
    try std.testing.expectEqual(missing.len + "/pre-".len + 8, path.len);
}

test "mkstemp makes a relative directory absolute as Python does" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &cwd_buf);
    var rb: [sys.path_max]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rb, ".zig-cache/zig-common-mkstemp-rel-{d}", .{linux.getpid()});
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, rel)).ptr, 0o700);
    defer deleteTree(gpa, cwd, rel) catch {};
    const abs = try std.fs.path.join(gpa, &.{ here, rel });
    defer gpa.free(abs);

    var failed: ?[]u8 = null;
    const dotted = try std.fmt.allocPrint(gpa, "./{s}/../{s}", .{ rel, std.fs.path.basename(rel) });
    defer gpa.free(dotted);
    const made = try mkstemp(gpa, dotted, "pre-", &failed);
    defer gpa.free(made.path);
    defer sys.close(made.fd);
    const expected_prefix = try std.fmt.allocPrint(gpa, "{s}/pre-", .{abs});
    defer gpa.free(expected_prefix);
    try std.testing.expect(std.mem.startsWith(u8, made.path, expected_prefix));
    try std.testing.expectEqual(expected_prefix.len + 8, made.path.len);

    const missing = try std.fmt.allocPrint(gpa, "{s}/missing", .{rel});
    defer gpa.free(missing);
    try std.testing.expectError(error.NotFound, mkstemp(gpa, missing, "pre-", &failed));
    defer if (failed) |p| gpa.free(p);
    const refused = failed orelse return error.TestUnexpectedResult;
    const missing_prefix = try std.fmt.allocPrint(gpa, "{s}/missing/pre-", .{abs});
    defer gpa.free(missing_prefix);
    try std.testing.expect(std.mem.startsWith(u8, refused, missing_prefix));
    try std.testing.expectEqual(missing_prefix.len + 8, refused.len);
}

/// The directories `tempfile.gettempdir` tries, in its order: the values of
/// TMPDIR, TEMP and TMP that are set and not empty, then `/tmp`,
/// `/var/tmp` and `/usr/tmp`, then the working directory, or "." when that
/// cannot be read. `env` is anything with `get(name) ?[]const u8`, such as
/// `Env` or a string map. The strings are as given, not made absolute. The
/// last one, the working directory, is a copy allocated from `gpa`;
/// `freeTempDirCandidates` frees it with the list.
pub fn tempDirCandidates(gpa: Allocator, env: anytype) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |name| {
        const v = env.get(name) orelse continue;
        if (v.len > 0) try list.append(gpa, v);
    }
    try list.appendSlice(gpa, &.{ "/tmp", "/var/tmp", "/usr/tmp" });
    var buf: [sys.path_max]u8 = undefined;
    const here = try gpa.dupe(u8, getcwd(&buf) catch ".");
    errdefer gpa.free(here);
    try list.append(gpa, here);
    return list.toOwnedSlice(gpa);
}

/// Free a list `tempDirCandidates` returned, with the copy at its end.
pub fn freeTempDirCandidates(gpa: Allocator, candidates: []const []const u8) void {
    gpa.free(candidates[candidates.len - 1]);
    gpa.free(candidates);
}

/// `os.getcwd()`: the working directory as the kernel names it, which is an
/// error when the directory has been removed.
fn getcwd(buf: *[sys.path_max]u8) Error![]const u8 {
    const n = try sys.call(linux.getcwd, .{ buf, buf.len });
    return buf[0..n -| 1];
}

fn realTempProbeClose(fd: fd_t) usize {
    return linux.close(fd);
}

/// The close of the probe file `tempDirUsable` writes before a directory
/// can be chosen. Replaceable in the same builds as `publish_ops`; a
/// constant real close in any other build. A close that EINTR interrupts
/// is not retried.
const TempProbeOps = struct {
    close: *const fn (fd: fd_t) usize = realTempProbeClose,
};

var test_temp_probe_ops: TempProbeOps = .{};
const real_temp_probe_ops: TempProbeOps = .{};
/// The close in use. A replaceable build may assign through it
/// (`temp_probe_ops.* = ...`); any other build points it at a constant
/// real close.
pub const temp_probe_ops = if (atomic.replaceable) &test_temp_probe_ops else &real_temp_probe_ops;

/// `tempfile._get_default_tempdir`'s probe of one directory: a new file with
/// a random name, `blat` written to it, closed and removed. Python tries
/// 100 names, goes on only after a name that exists, and gives up on the
/// directory at any other error. A short write is not an error there.
/// The probe is closed once. A failed close gives up on the directory, the
/// same way Python's `os.close` does: a write lost on NFS may be reported
/// only by the close, and that directory is not chosen. The probe file is
/// still removed. A close that EINTR interrupts is not retried and is not
/// an error, as `sys.result` treats EINTR. The close goes through
/// `temp_probe_ops`. A cleanup close after an earlier error ignores its
/// result so that error keeps its errno.
fn tempDirUsable(gpa: Allocator, dir: []const u8) bool {
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        const rnd = randomName() catch return false;
        const path = std.fs.path.join(gpa, &.{ dir, &rnd }) catch return false;
        defer gpa.free(path);
        const fd = sys.openat(cwd, path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch |err| switch (err) {
            error.Exists => continue,
            else => return false,
        };
        var open = true;
        defer if (open) {
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            _ = temp_probe_ops.close(fd);
        };
        const wrote = if (sys.call(linux.write, .{ fd, "blat", 4 })) |_| true else |_| false;
        if (!wrote) {
            open = false;
            // The error being returned keeps its errno.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            _ = temp_probe_ops.close(fd);
            sys.unlinkat(cwd, path, 0) catch return false;
            return false;
        }
        // Once. A later failure must not close again.
        open = false;
        if (sys.result(temp_probe_ops.close(fd))) |_| {} else |_| {
            // The close error keeps its errno across the removal.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            sys.unlinkat(cwd, path, 0) catch {};
            return false;
        }
        sys.unlinkat(cwd, path, 0) catch return false;
        return true;
    }
    return false;
}

/// The directory `_get_default_tempdir` probes for `candidate`, as a copy
/// allocated from `gpa`: "." as it is, any other value made absolute and
/// normalized like `os.path.abspath`. A relative value needs `os.getcwd()`,
/// and Python lets its error out of gettempdir.
fn tempDirPath(gpa: Allocator, candidate: []const u8) (Error || Allocator.Error)![]u8 {
    if (std.mem.eql(u8, candidate, ".")) return gpa.dupe(u8, candidate);
    if (candidate[0] == '/') return normPath(gpa, candidate);
    var buf: [sys.path_max]u8 = undefined;
    const here = try getcwd(&buf);
    const joined = try std.mem.concat(gpa, u8, &.{ here, "/", candidate });
    defer gpa.free(joined);
    return normPath(gpa, joined);
}

/// `tempfile.gettempdir`: the first of `tempDirCandidates` that takes the
/// probe file, made absolute and normalized like `os.path.abspath`. A
/// directory whose probe close fails did not take it. Python keeps the
/// answer for the life of the process, and so does `path` here: a later
/// call returns it without looking at the environment or the directory
/// again. A failure is not kept; each call tries again.
///
/// `path` and `message` are allocated from the `gpa` given to `get` and
/// owned by the `TempDir`; `deinit` frees them. Nothing else a call
/// allocates outlives it.
pub const TempDir = struct {
    /// The directory once one has been found.
    path: ?[]const u8 = null,
    /// After `error.NoTempDir`, `str()` of the FileNotFoundError Python
    /// raises, "[Errno 2] No usable temporary directory found in [...]",
    /// with the candidates as repr writes them, or "[Errno 2] No such file
    /// or directory" when a relative value needed a working directory that
    /// was removed. Each failed call replaces it.
    message: []const u8 = "",

    /// Free `path` and `message` and reset `td`.
    pub fn deinit(td: *TempDir, gpa: Allocator) void {
        if (td.path) |p| gpa.free(p);
        if (td.message.len > 0) gpa.free(td.message);
        td.* = .{};
    }

    /// The directory, from the cache or by trying the candidates.
    pub fn get(td: *TempDir, gpa: Allocator, env: anytype) error{ NoTempDir, OutOfMemory }![]const u8 {
        if (td.path) |p| return p;
        const candidates = try tempDirCandidates(gpa, env);
        defer freeTempDirCandidates(gpa, candidates);
        for (candidates) |candidate| {
            const dir = tempDirPath(gpa, candidate) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| {
                    td.setMessage(gpa, try gpa.dupe(u8, sys.describe(e)));
                    return error.NoTempDir;
                },
            };
            if (tempDirUsable(gpa, dir)) {
                td.path = dir;
                return dir;
            }
            gpa.free(dir);
        }
        td.setMessage(gpa, try noTempDirMessage(gpa, candidates));
        return error.NoTempDir;
    }

    fn setMessage(td: *TempDir, gpa: Allocator, message: []const u8) void {
        if (td.message.len > 0) gpa.free(td.message);
        td.message = message;
    }
};

fn noTempDirMessage(gpa: Allocator, candidates: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "[Errno 2] No usable temporary directory found in [");
    for (candidates, 0..) |c, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try pytext.reprStr(&out, gpa, c);
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

test "tempDirCandidates follows tempfile's order and skips empty values" {
    const gpa = std.testing.allocator;
    var env: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer env.deinit(gpa);
    try env.put(gpa, "TMP", "/m");
    try env.put(gpa, "TMPDIR", "rel/./dir/");
    try env.put(gpa, "TEMP", "");
    const got = try tempDirCandidates(gpa, env);
    defer freeTempDirCandidates(gpa, got);
    var buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &buf);
    const want = [_][]const u8{ "rel/./dir/", "/m", "/tmp", "/var/tmp", "/usr/tmp", here };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    const bare = try tempDirCandidates(gpa, std.StringHashMapUnmanaged([]const u8).empty);
    defer freeTempDirCandidates(gpa, bare);
    try std.testing.expectEqual(@as(usize, 4), bare.len);
}

test "TempDir takes the first usable candidate and keeps it" {
    const gpa = std.testing.allocator;
    var buf: [sys.path_max]u8 = undefined;
    const here = try realpath(cwd, ".", &buf);
    var pb: [sys.path_max]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, "{s}/.zig-cache/zig-common-tempdir-{d}", .{ here, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(cwd, (try sys.z(&zb, base)).ptr, 0o700);
    defer deleteTree(gpa, cwd, base) catch {};

    var env: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer env.deinit(gpa);
    const unnormalized = try std.fmt.allocPrint(gpa, "{s}/./sub/..//", .{base});
    defer gpa.free(unnormalized);
    try env.put(gpa, "TMPDIR", "/nonexistent-zig-common-dir");
    try env.put(gpa, "TEMP", unnormalized);
    var td: TempDir = .{};
    defer td.deinit(gpa);
    try std.testing.expectEqualStrings(base, try td.get(gpa, env));

    try env.put(gpa, "TEMP", "/nonexistent-zig-common-dir");
    try std.testing.expectEqualStrings(base, try td.get(gpa, env));

    var fresh: TempDir = .{};
    defer fresh.deinit(gpa);
    const system = try fresh.get(gpa, env);
    try std.testing.expect(!std.mem.eql(u8, system, base));
    try std.testing.expect(system[0] == '/');
}

test "TempDir frees what its failed calls allocate" {
    // std.testing.allocator fails the test on a leak, so each candidate
    // that fails, each join of a relative value and each replaced message
    // must be freed, and deinit must free what the TempDir keeps.
    const gpa = std.testing.allocator;
    var env: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer env.deinit(gpa);
    try env.put(gpa, "TMPDIR", "/nonexistent-zig-common-dir/./x/..");
    try env.put(gpa, "TEMP", "relative-zig-common-missing");
    try env.put(gpa, "TMP", "it's");
    var td: TempDir = .{};
    defer td.deinit(gpa);

    {
        // Under a file size limit of 0 with SIGXFSZ ignored, every probe
        // write fails with EFBIG, so every candidate fails, twice over.
        var lim: linux.rlimit = undefined;
        try std.testing.expectEqual(@as(usize, 0), linux.getrlimit(.FSIZE, &lim));
        const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        var old: linux.Sigaction = undefined;
        _ = linux.sigaction(linux.SIG.XFSZ, &ignore, &old);
        defer _ = linux.sigaction(linux.SIG.XFSZ, &old, null);
        const zero: linux.rlimit = .{ .cur = 0, .max = lim.max };
        try std.testing.expectEqual(@as(usize, 0), linux.setrlimit(.FSIZE, &zero));
        defer _ = linux.setrlimit(.FSIZE, &lim);
        try std.testing.expectError(error.NoTempDir, td.get(gpa, env));
        try std.testing.expectError(error.NoTempDir, td.get(gpa, env));
    }
    try std.testing.expect(td.path == null);
    try std.testing.expect(std.mem.startsWith(u8, td.message, "[Errno 2] No usable temporary directory found in ['/nonexistent-zig-common-dir/./x/..', 'relative-zig-common-missing', \"it's\", '/tmp', "));

    {
        // A relative value under a removed working directory replaces the
        // message with the error of os.getcwd().
        var here_buf: [sys.path_max]u8 = undefined;
        const here = try realpath(cwd, ".", &here_buf);
        var hz: [sys.path_max:0]u8 = undefined;
        const here_z = try sys.z(&hz, here);
        var gb: [sys.path_max]u8 = undefined;
        const gone = try std.fmt.bufPrint(&gb, "{s}/.zig-cache/zig-common-tempdir-gone-{d}", .{ here, linux.getpid() });
        var gz: [sys.path_max:0]u8 = undefined;
        const gone_z = try sys.z(&gz, gone);
        try std.testing.expectEqual(@as(usize, 0), linux.mkdirat(cwd, gone_z.ptr, 0o700));
        try std.testing.expectEqual(@as(usize, 0), linux.chdir(gone_z.ptr));
        defer _ = linux.chdir(here_z.ptr);
        try sys.unlinkat(cwd, gone, linux.AT.REMOVEDIR);
        try std.testing.expectError(error.NoTempDir, td.get(gpa, env));
        try std.testing.expectEqualStrings("[Errno 2] No such file or directory", td.message);
    }

    try env.put(gpa, "TMPDIR", "/tmp/./");
    const dir = try td.get(gpa, env);
    try std.testing.expectEqualStrings("/tmp", dir);
    try std.testing.expectEqual(dir.ptr, (try td.get(gpa, env)).ptr);
}

test "the temporary directory message quotes candidates as repr does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const msg = try noTempDirMessage(a, &.{ "/tmp", "it's", "a\"b'c\n", "\xff" });
    try std.testing.expectEqualStrings(
        "[Errno 2] No usable temporary directory found in ['/tmp', \"it's\", 'a\"b\\'c\\n', '\\udcff']",
        msg,
    );
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

test "a FIFO is not a regular file" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fifo");
    defer scratch.deinit();
    const d = scratch.fd;
    _ = linux.mkdirat(d, "tree", 0o700);
    const tree = try openDir(d, "tree", false);
    defer sys.close(tree);
    _ = try sys.call(linux.mknodat, .{ tree, "pipe", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    const srcfd = try sys.openat(d, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    try sys.writeAll(srcfd, "text\n");
    sys.close(srcfd);

    const Op = enum { open, append, copy_dest, move_source, move_tree };
    for ([_]Op{ .open, .append, .copy_dest, .move_source, .move_tree }) |op| {
        switch (op) {
            .open => try std.testing.expectError(error.NotRegularFile, openRegular(tree, "pipe", false)),
            .append => try std.testing.expectError(error.NotRegularFile, appendLine(gpa, tree, "pipe", "x")),
            .copy_dest => {
                const src = try openRegular(d, "src", false);
                defer sys.close(src.fd);
                try std.testing.expectError(error.NotRegularFile, copyTo(src.fd, src.stat, tree, "pipe"));
            },
            .move_source => try std.testing.expectError(error.NotRegularFile, moveAcrossInternal(gpa, tree, "pipe", tree, "dst", .{ .policy = .strict }, .{
                .force_cross_device_rename = true,
            })),
            .move_tree => try std.testing.expectError(error.NotRegularFile, moveAcrossInternal(gpa, d, "tree", d, "moved", .{ .policy = .strict }, .{
                .force_cross_device_rename = true,
            })),
        }
        try std.testing.expectEqualStrings("not a regular file", sys.describe(error.NotRegularFile));
    }
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

/// The renames and directory syncs one moveAcross call makes, in order. A
/// sync is kept as the device and inode of the directory it flushed.
const MoveTrace = struct {
    calls: [16]Call = undefined,
    len: usize = 0,

    const Call = union(enum) {
        rename,
        fsync: struct { dev: u64, ino: u64 },
    };

    fn record(ctx: ?*anyopaque, call: MoveCall) void {
        const self: *MoveTrace = @ptrCast(@alignCast(ctx.?));
        if (self.len == self.calls.len) return;
        self.calls[self.len] = switch (call) {
            .rename => .rename,
            .fsync => |fd| if (fstat(fd)) |st| .{ .fsync = .{ .dev = st.dev, .ino = st.ino } } else |_| .{ .fsync = .{ .dev = 0, .ino = 0 } },
        };
        self.len += 1;
    }

    fn faults(self: *MoveTrace, cross_device: bool) MoveFaults {
        return .{ .force_cross_device_rename = cross_device, .trace_fn = record, .ctx = self };
    }

    fn sync(dir: Stat) Call {
        return .{ .fsync = .{ .dev = dir.dev, .ino = dir.ino } };
    }

    fn expectCalls(self: *const MoveTrace, want: []const Call) !void {
        try std.testing.expectEqualSlices(Call, want, self.calls[0..self.len]);
    }

    /// Whether `dir` is synced after the last rename.
    fn syncedAfterPublish(self: *const MoveTrace, dir: Stat) bool {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            switch (self.calls[i]) {
                .rename => return false,
                .fsync => |s| if (s.dev == dir.dev and s.ino == dir.ino) return true,
            }
        }
        return false;
    }
};

/// Scratch directory under `.zig-cache` for the moveAcross trace tests.
const MoveScratch = struct {
    gpa: Allocator,
    scratch: test_support.ScratchDir,
    d: fd_t,

    fn init(gpa: Allocator, tag: []const u8) !MoveScratch {
        const scratch = try test_support.ScratchDir.init(gpa, tag);
        return .{ .gpa = gpa, .scratch = scratch, .d = scratch.fd };
    }

    fn deinit(self: MoveScratch) void {
        self.scratch.deinit();
    }

    fn mkdir(self: MoveScratch, name: []const u8) !Stat {
        var zb: [sys.path_max:0]u8 = undefined;
        _ = try sys.call(linux.mkdirat, .{ self.d, (try sys.z(&zb, name)).ptr, @as(linux.mode_t, 0o700) });
        return statAt(self.d, name, false);
    }

    fn put(self: MoveScratch, name: []const u8) !void {
        const fd = try sys.openat(self.d, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
        defer sys.close(fd);
        try sys.writeAll(fd, "moved\n");
    }

    fn expectMoved(self: MoveScratch, src: []const u8, dst: []const u8) !void {
        try std.testing.expectError(error.NotFound, statAt(self.d, src, false));
        const got = try openRegular(self.d, dst, false);
        defer sys.close(got.fd);
        const text = try readAll(self.gpa, got.fd, 64);
        defer self.gpa.free(text);
        try std.testing.expectEqualStrings("moved\n", text);
    }
};

test "moveAcross syncs the directories that publish a rename" {
    const gpa = std.testing.allocator;
    const s = try MoveScratch.init(gpa, "move-sync");
    defer s.deinit();
    const root = try fstat(s.d);
    const sub = try s.mkdir("sub");
    const a = try s.mkdir("a");

    const DirId = enum { root, sub, a };
    const Row = struct {
        src: []const u8,
        dst: []const u8,
        exdev: bool,
        /// Directories synced after the rename, in order. `exact` requires
        /// that list and nothing else; otherwise each must be synced.
        synced: []const DirId,
        exact: bool,
        /// File to create before the move. Null moves the previous destination.
        put: ?[]const u8,
    };
    const rows = [_]Row{
        .{ .src = "src", .dst = "dst", .exdev = false, .synced = &.{.root}, .exact = true, .put = "src" },
        .{ .src = "dst", .dst = "src", .exdev = true, .synced = &.{ .root, .root }, .exact = true, .put = null },
        .{ .src = "src", .dst = "sub/renamed", .exdev = false, .synced = &.{.sub}, .exact = false, .put = null },
        .{ .src = "src", .dst = "sub/copied", .exdev = true, .synced = &.{.sub}, .exact = false, .put = "src" },
        .{ .src = "src", .dst = "sub/flat", .exdev = false, .synced = &.{ .sub, .root }, .exact = false, .put = "src" },
        .{ .src = "a/src", .dst = "sub/from-a", .exdev = false, .synced = &.{ .sub, .a }, .exact = false, .put = "a/src" },
        .{ .src = "a/src", .dst = "sub/from-a-copy", .exdev = true, .synced = &.{ .sub, .a }, .exact = false, .put = "a/src" },
        .{ .src = "sub/from-a-copy", .dst = "sub/beside", .exdev = false, .synced = &.{.sub}, .exact = true, .put = null },
    };

    for (rows) |row| {
        if (row.put) |name| try s.put(name);
        var trace = MoveTrace{};
        try moveAcrossInternal(gpa, s.d, row.src, s.d, row.dst, .{}, trace.faults(row.exdev));
        try s.expectMoved(row.src, row.dst);
        const dirOf = struct {
            fn get(id: DirId, root_st: Stat, sub_st: Stat, a_st: Stat) Stat {
                return switch (id) {
                    .root => root_st,
                    .sub => sub_st,
                    .a => a_st,
                };
            }
        }.get;
        if (row.exact) {
            var want: [8]MoveTrace.Call = undefined;
            want[0] = .rename;
            for (row.synced, 0..) |id, i| want[i + 1] = MoveTrace.sync(dirOf(id, root, sub, a));
            try trace.expectCalls(want[0 .. row.synced.len + 1]);
        } else {
            for (row.synced) |id| try std.testing.expect(trace.syncedAfterPublish(dirOf(id, root, sub, a)));
        }
    }
}

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

// ---- publishing close: checked once, before the rename --------------------

const PublishHook = struct {
    var closes: usize = 0;
    var errno: linux.E = .SUCCESS;

    fn arm(e: linux.E) void {
        closes = 0;
        errno = e;
        publish_ops.* = .{ .close = close };
    }

    /// Linux frees the descriptor whatever close returns, so the hook closes
    /// it for real and then reports the errno it was given, on the first
    /// call only: a second close of the descriptor is EBADF.
    fn close(fd: fd_t) usize {
        closes += 1;
        const rc = linux.close(fd);
        if (errno == .SUCCESS or closes > 1) return rc;
        return @bitCast(-@as(isize, @backingInt(errno)));
    }
};

fn expectNoTmp(gpa: Allocator, dir: fd_t) !void {
    var it = try DirIter.init(gpa, dir);
    defer it.deinit(gpa);
    while (try it.next()) |e| try std.testing.expect(std.mem.indexOf(u8, e.name, ".tmp") == null);
}

fn expectText(gpa: Allocator, dir: fd_t, name: []const u8, text: []const u8) !void {
    const opened = try openRegular(dir, name, false);
    defer sys.close(opened.fd);
    const got = try readAll(gpa, opened.fd, 64);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(text, got);
}

fn putBytes(dir: fd_t, name: []const u8, text: []const u8) !void {
    const fd = try sys.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
    defer sys.close(fd);
    try sys.writeAll(fd, text);
}

fn crossMove(gpa: Allocator, dir: fd_t, src: []const u8, dst: []const u8) (Error || Allocator.Error)!void {
    try moveAcrossInternal(gpa, dir, src, dir, dst, .{ .policy = .strict }, .{
        .force_cross_device_rename = true,
    });
}

test "fsx publish close: replaceContents returns EIO and leaves the destination" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-repl-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "list", "old\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.IO);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, replaceContents(gpa, scratch.fd, "list", "new\n"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "list", "old\n");
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: replaceContents publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-repl-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "list", "old\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.INTR);
    try replaceContents(gpa, scratch.fd, "list", "new\n");
    try std.testing.expectEqual(@as(usize, 1), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "list", "new\n");
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: moveAcross file returns EIO and leaves the destination" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-move-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "keep\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.IO);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, crossMove(gpa, scratch.fd, "src", "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "src", "new\n");
    try expectText(gpa, scratch.fd, "dst", "keep\n");
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: moveAcross file publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-move-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "keep\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.INTR);
    try crossMove(gpa, scratch.fd, "src", "dst");
    // The file, then the destination parent and the source parent.
    try std.testing.expectEqual(@as(usize, 3), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "src", false));
    try expectText(gpa, scratch.fd, "dst", "new\n");
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: moveAcross tree returns EIO and leaves the destination" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-tree-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    var zb: [sys.path_max:0]u8 = undefined;
    _ = try sys.call(linux.mkdirat, .{ scratch.fd, (try sys.z(&zb, "src")).ptr, @as(linux.mode_t, 0o700) });
    const sub = try openDir(scratch.fd, "src", false);
    defer sys.close(sub);
    try putBytes(sub, "a", "tree\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.IO);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, crossMove(gpa, scratch.fd, "src", "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    // The file close fails, then the temporary directory is closed on the way out.
    try std.testing.expectEqual(@as(usize, 2), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, sub, "a", "tree\n");
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "dst", false));
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: moveAcross tree publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-tree-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    var zb: [sys.path_max:0]u8 = undefined;
    _ = try sys.call(linux.mkdirat, .{ scratch.fd, (try sys.z(&zb, "src")).ptr, @as(linux.mode_t, 0o700) });
    const sub = try openDir(scratch.fd, "src", false);
    try putBytes(sub, "a", "tree\n");
    sys.close(sub);
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.INTR);
    try crossMove(gpa, scratch.fd, "src", "dst");
    // The file, the temporary directory, then both parent directories.
    try std.testing.expectEqual(@as(usize, 4), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "src", false));
    try expectText(gpa, scratch.fd, "dst/a", "tree\n");
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: appendLine returns EIO" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-append-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "list", "old\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.IO);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, appendLine(gpa, scratch.fd, "list", "new"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    // The write finished before close failed, and the descriptor is already
    // gone, so the new line is not shortened away.
    try expectText(gpa, scratch.fd, "list", "old\nnew\n");
}

test "fsx publish close: appendLine keeps the line on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-append-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "list", "old\n");
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.INTR);
    try appendLine(gpa, scratch.fd, "list", "new");
    try std.testing.expectEqual(@as(usize, 1), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "list", "old\nnew\n");
}

test "fsx publish close: copyTo returns EIO and leaves the destination" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-copyto-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "old\n");
    const opened = try openRegular(scratch.fd, "src", false);
    defer sys.close(opened.fd);
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.IO);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, copyTo(opened.fd, opened.stat, scratch.fd, "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "dst", "old\n");
    try expectNoTmp(gpa, scratch.fd);
}

test "fsx publish close: copyTo publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-close-copyto-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "old\n");
    const opened = try openRegular(scratch.fd, "src", false);
    defer sys.close(opened.fd);
    const before = try test_support.fdCount(gpa);
    PublishHook.arm(.INTR);
    const fd = try copyTo(opened.fd, opened.stat, scratch.fd, "dst");
    // The same offset the write left, so a later write appends.
    try std.testing.expectEqual(@as(u64, 4), linux.lseek(fd, 0, linux.SEEK.CUR));
    sys.close(fd);
    // The file close, then the parent directory close. EINTR is not retried.
    try std.testing.expectEqual(@as(usize, 2), PublishHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "dst", "new\n");
    try expectNoTmp(gpa, scratch.fd);
}

const CopyToReplaceHook = struct {
    var dir: fd_t = -1;
    var directory_closes: usize = 0;

    fn arm(d: fd_t) void {
        dir = d;
        directory_closes = 0;
        publish_ops.* = .{ .close = close };
    }

    fn close(fd: fd_t) usize {
        const is_dir = if (fstat(fd)) |st| st.isDir() else |_| false;
        const rc = linux.close(fd);
        if (is_dir) {
            directory_closes += 1;
            if (directory_closes == 1) {
                sys.renameat(dir, "dst", dir, "published") catch unreachable;
                sys.renameat(dir, "other", dir, "dst") catch unreachable;
            }
        }
        return rc;
    }
};

test "copyTo returns the inode it published if the name is replaced" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-copyto-replaced");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "old\n");
    try putBytes(scratch.fd, "other", "other\n");
    const opened = try openRegular(scratch.fd, "src", false);
    defer sys.close(opened.fd);
    CopyToReplaceHook.arm(scratch.fd);
    const fd = try copyTo(opened.fd, opened.stat, scratch.fd, "dst");
    defer sys.close(fd);
    const returned = try fstat(fd);
    const published = try statAt(scratch.fd, "published", false);
    const replacement = try statAt(scratch.fd, "dst", false);
    try std.testing.expectEqual(published.ino, returned.ino);
    try std.testing.expect(returned.ino != replacement.ino);
    try expectText(gpa, scratch.fd, "published", "new\n");
    try expectText(gpa, scratch.fd, "dst", "other\n");
}

const DirCloseHook = struct {
    var closes: usize = 0;
    var errno: linux.E = .SUCCESS;
    /// 1-based index of the directory close that reports `errno`.
    var fail_at: usize = 1;

    fn arm(e: linux.E, at: usize) void {
        closes = 0;
        errno = e;
        fail_at = at;
        publish_ops.* = .{ .close = close };
    }

    /// Closes `fd` for real. A file is returned unchanged. `errno` is
    /// reported for one directory close, and later directory closes are the
    /// real result, so that call is not retried.
    fn close(fd: fd_t) usize {
        const is_dir = if (fstat(fd)) |st| st.isDir() else |_| false;
        const rc = linux.close(fd);
        if (!is_dir) return rc;
        closes += 1;
        if (errno == .SUCCESS or closes != fail_at) return rc;
        return @bitCast(-@as(isize, @backingInt(errno)));
    }
};

fn mkdirAt(dir: fd_t, name: []const u8) !void {
    var zb: [sys.path_max:0]u8 = undefined;
    _ = try sys.call(linux.mkdirat, .{ dir, (try sys.z(&zb, name)).ptr, @as(linux.mode_t, 0o700) });
}

test "dir close: moveAcross empty directory returns EIO and leaves the destination" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-empty-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try mkdirAt(scratch.fd, "src");
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.IO, 1);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, crossMove(gpa, scratch.fd, "src", "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expect((try statAt(scratch.fd, "src", false)).isDir());
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "dst", false));
    try expectNoTmp(gpa, scratch.fd);
}

test "dir close: moveAcross empty directory publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-empty-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try mkdirAt(scratch.fd, "src");
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.INTR, 1);
    try crossMove(gpa, scratch.fd, "src", "dst");
    // Temporary directory, then the destination parent and the source parent.
    try std.testing.expectEqual(@as(usize, 3), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "src", false));
    try std.testing.expect((try statAt(scratch.fd, "dst", false)).isDir());
    try expectNoTmp(gpa, scratch.fd);
}

test "dir close: copied subdirectory returns EIO and leaves the destination" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-sub-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try mkdirAt(scratch.fd, "src");
    const sub = try openDir(scratch.fd, "src", false);
    defer sys.close(sub);
    try mkdirAt(sub, "child");
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.IO, 1);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, crossMove(gpa, scratch.fd, "src", "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    // The child close fails, then the temporary directory is closed on the way out.
    try std.testing.expectEqual(@as(usize, 2), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expect((try statAt(sub, "child", false)).isDir());
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "dst", false));
    try expectNoTmp(gpa, scratch.fd);
}

test "dir close: copied subdirectory publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-sub-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try mkdirAt(scratch.fd, "src");
    const sub = try openDir(scratch.fd, "src", false);
    try mkdirAt(sub, "child");
    sys.close(sub);
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.INTR, 1);
    try crossMove(gpa, scratch.fd, "src", "dst");
    // Child directory, temporary root, then both parents.
    try std.testing.expectEqual(@as(usize, 4), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "src", false));
    try std.testing.expect((try statAt(scratch.fd, "dst/child", false)).isDir());
    try expectNoTmp(gpa, scratch.fd);
}

test "dir close: copyTo parent returns EIO and leaves the published file" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-copy-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "old\n");
    const opened = try openRegular(scratch.fd, "src", false);
    defer sys.close(opened.fd);
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.IO, 1);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, copyTo(opened.fd, opened.stat, scratch.fd, "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "dst", "new\n");
}

test "dir close: copyTo parent publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-copy-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try putBytes(scratch.fd, "src", "new\n");
    try putBytes(scratch.fd, "dst", "old\n");
    const opened = try openRegular(scratch.fd, "src", false);
    defer sys.close(opened.fd);
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.INTR, 1);
    const fd = try copyTo(opened.fd, opened.stat, scratch.fd, "dst");
    sys.close(fd);
    try std.testing.expectEqual(@as(usize, 1), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectText(gpa, scratch.fd, "dst", "new\n");
}

test "dir close: moveAcross parent sync returns EIO and leaves the published tree" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-parent-eio");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try mkdirAt(scratch.fd, "src");
    const before = try test_support.fdCount(gpa);
    // The second directory close is the destination parent, after the rename.
    DirCloseHook.arm(.IO, 2);
    sys.last_errno = .SUCCESS;
    try std.testing.expectError(error.Unexpected, crossMove(gpa, scratch.fd, "src", "dst"));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 2), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expect((try statAt(scratch.fd, "src", false)).isDir());
    try std.testing.expect((try statAt(scratch.fd, "dst", false)).isDir());
    try expectNoTmp(gpa, scratch.fd);
}

test "dir close: moveAcross parent sync publishes on EINTR" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-dir-close-parent-eintr");
    defer scratch.deinit();
    defer publish_ops.* = .{};
    try mkdirAt(scratch.fd, "src");
    const before = try test_support.fdCount(gpa);
    DirCloseHook.arm(.INTR, 2);
    try crossMove(gpa, scratch.fd, "src", "dst");
    // Temporary directory, destination parent, then the source parent.
    try std.testing.expectEqual(@as(usize, 3), DirCloseHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try std.testing.expectError(error.NotFound, statAt(scratch.fd, "src", false));
    try std.testing.expect((try statAt(scratch.fd, "dst", false)).isDir());
    try expectNoTmp(gpa, scratch.fd);
}

const TempProbeHook = struct {
    var closes: usize = 0;
    var errno: linux.E = .SUCCESS;

    fn arm(e: linux.E) void {
        closes = 0;
        errno = e;
        temp_probe_ops.* = .{ .close = close };
    }

    /// Linux frees the descriptor whatever close returns, so the hook closes
    /// it for real and then reports the errno it was given.
    fn close(fd: fd_t) usize {
        closes += 1;
        const rc = linux.close(fd);
        if (errno == .SUCCESS) return rc;
        return @bitCast(-@as(isize, @backingInt(errno)));
    }
};

fn expectEmptyDir(gpa: Allocator, dir: fd_t) !void {
    var it = try DirIter.init(gpa, dir);
    defer it.deinit(gpa);
    try std.testing.expect(try it.next() == null);
}

test "temp dir probe close: EIO leaves the directory unchosen" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-temp-probe-eio");
    defer scratch.deinit();
    defer temp_probe_ops.* = .{};
    const before = try test_support.fdCount(gpa);
    TempProbeHook.arm(.IO);
    sys.last_errno = .SUCCESS;
    try std.testing.expect(!tempDirUsable(gpa, scratch.path));
    try std.testing.expectEqual(linux.E.IO, sys.last_errno);
    try std.testing.expectEqual(@as(usize, 1), TempProbeHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectEmptyDir(gpa, scratch.fd);

    var env: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer env.deinit(gpa);
    try env.put(gpa, "TMPDIR", scratch.path);
    try env.put(gpa, "TEMP", "/nonexistent-zig-common-temp-probe");
    try env.put(gpa, "TMP", "/nonexistent-zig-common-temp-probe-2");
    TempProbeHook.arm(.IO);
    var td: TempDir = .{};
    defer td.deinit(gpa);
    try std.testing.expectError(error.NoTempDir, td.get(gpa, env));
    try std.testing.expect(td.path == null);
    try expectEmptyDir(gpa, scratch.fd);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
}

test "temp dir probe close: EINTR counts the directory usable" {
    const gpa = std.testing.allocator;
    const scratch = try test_support.ScratchDir.init(gpa, "fsx-temp-probe-eintr");
    defer scratch.deinit();
    defer temp_probe_ops.* = .{};
    const before = try test_support.fdCount(gpa);
    TempProbeHook.arm(.INTR);
    try std.testing.expect(tempDirUsable(gpa, scratch.path));
    try std.testing.expectEqual(@as(usize, 1), TempProbeHook.closes);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectEmptyDir(gpa, scratch.fd);

    TempProbeHook.arm(.INTR);
    var env: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer env.deinit(gpa);
    try env.put(gpa, "TMPDIR", scratch.path);
    var td: TempDir = .{};
    defer td.deinit(gpa);
    try std.testing.expectEqualStrings(scratch.path, try td.get(gpa, env));
    try std.testing.expect(td.path != null);
    try std.testing.expectEqual(@as(usize, 1), TempProbeHook.closes);
    try expectEmptyDir(gpa, scratch.fd);
    try std.testing.expectEqual(before, try test_support.fdCount(gpa));
}
