//! Same-directory replacement of a file whose access metadata must survive:
//! the bytes, owner, mode and every listed ACL form are written to a
//! temporary file, read back, made durable, closed, and only then renamed
//! over the destination. The ACL forms are the GPFS native NFSv4 ACL, the
//! generic NFSv4 ACL and the POSIX access ACL, most native first; a
//! filesystem may expose one ACL through several of them.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");
const pytext = @import("pytext.zig");

const Allocator = std.mem.Allocator;

/// The ACL forms `atomicWrite` keeps, most native first: `fsx.acl_attributes`.
pub const acl_attributes = fsx.acl_attributes;
const posix_access = "system.posix_acl_access";

/// The calls atomicWrite makes on a file descriptor, as raw system-call
/// results. Programs leave them alone; tests replace them to emulate a
/// filesystem's ACL model or a failing call, in a `replaceable` build only
/// (this library's tests, a tool's -Dtest-ops artifact). `created` runs on
/// the temporary file right after its O_EXCL creation, where a filesystem
/// applies an inherited ACL. `close` is the temporary file's close before
/// the rename, and the parent directory's close after its sync; the caller
/// does not retry either.
pub const Ops = struct {
    flistxattr: *const fn (fd: sys.fd_t, buf: []u8) usize = realList,
    fgetxattr: *const fn (fd: sys.fd_t, name: [:0]const u8, buf: []u8) usize = realGet,
    fsetxattr: *const fn (fd: sys.fd_t, name: [:0]const u8, value: []const u8) usize = realSet,
    fremovexattr: *const fn (fd: sys.fd_t, name: [:0]const u8) usize = realRemove,
    fchmod: *const fn (fd: sys.fd_t, mode: u32) usize = realChmod,
    fchown: *const fn (fd: sys.fd_t, uid: linux.uid_t, gid: linux.gid_t) usize = realChown,
    fsync: *const fn (fd: sys.fd_t) usize = realFsync,
    close: *const fn (fd: sys.fd_t) usize = realClose,
    openat: *const fn (dir: sys.fd_t, path: [*:0]const u8, flags: sys.O, mode: linux.mode_t) usize = realOpenat,
    write: *const fn (fd: sys.fd_t, bytes: []const u8) usize = realWrite,
    renameat: *const fn (old_dir: sys.fd_t, old_path: [*:0]const u8, new_dir: sys.fd_t, new_path: [*:0]const u8) usize = realRenameat,
    geteuid: *const fn () linux.uid_t = realGeteuid,
    created: *const fn (fd: sys.fd_t) void = realCreated,
};

var test_ops: Ops = .{};
const real_ops: Ops = .{};

/// Whether `ops` can be replaced: in this library's tests, and in a tool's
/// test artifact built with -Dtest-ops; never in a released binary.
pub const replaceable = builtin.is_test or @import("zig_common_options").test_ops;

/// The calls in use. A replaceable build may assign through it
/// (`ops.* = ...`); any other build points it at constant real calls.
pub const ops = if (replaceable) &test_ops else &real_ops;

fn realList(fd: sys.fd_t, buf: []u8) usize {
    return linux.flistxattr(fd, buf.ptr, buf.len);
}
fn realGet(fd: sys.fd_t, name: [:0]const u8, buf: []u8) usize {
    return linux.fgetxattr(fd, name.ptr, buf.ptr, buf.len);
}
fn realSet(fd: sys.fd_t, name: [:0]const u8, value: []const u8) usize {
    return linux.fsetxattr(fd, name.ptr, value.ptr, value.len, 0);
}
fn realRemove(fd: sys.fd_t, name: [:0]const u8) usize {
    return linux.fremovexattr(fd, name.ptr);
}
fn realChmod(fd: sys.fd_t, mode: u32) usize {
    return linux.fchmod(fd, @intCast(mode));
}
fn realChown(fd: sys.fd_t, uid: linux.uid_t, gid: linux.gid_t) usize {
    return linux.fchown(fd, uid, gid);
}
fn realFsync(fd: sys.fd_t) usize {
    return linux.fsync(fd);
}
fn realClose(fd: sys.fd_t) usize {
    return linux.close(fd);
}
fn realOpenat(dir: sys.fd_t, path: [*:0]const u8, flags: sys.O, mode: linux.mode_t) usize {
    return linux.openat(dir, path, flags, mode);
}
fn realWrite(fd: sys.fd_t, bytes: []const u8) usize {
    return linux.write(fd, bytes.ptr, bytes.len);
}
fn realRenameat(old_dir: sys.fd_t, old_path: [*:0]const u8, new_dir: sys.fd_t, new_path: [*:0]const u8) usize {
    return linux.renameat(old_dir, old_path, new_dir, new_path);
}
fn realGeteuid() linux.uid_t {
    return linux.geteuid();
}
fn realCreated(_: sys.fd_t) void {}

/// Call one of `ops`, retrying on EINTR.
fn op(f: anytype, args: anytype) sys.Error!usize {
    while (true) {
        if (try sys.result(@call(.auto, f, args))) |r| return r;
    }
}

fn openTemp(path: []const u8, flags: sys.O, mode: linux.mode_t) sys.Error!sys.fd_t {
    var zb: [sys.path_max:0]u8 = undefined;
    var f = flags;
    f.CLOEXEC = true;
    const rc = try op(ops.openat, .{ fsx.cwd, (try sys.z(&zb, path)).ptr, f, mode });
    return @intCast(rc);
}

fn writeTemp(fd: sys.fd_t, bytes: []const u8) sys.Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try op(ops.write, .{ fd, bytes[off..] });
        if (n == 0) return error.NoSpace;
        off += n;
    }
}

/// Close the temporary file once. EINTR is not retried, as Linux has
/// freed the descriptor, and is not an error, as `sys.result` treats
/// EINTR. Any other errno is returned with `sys.last_errno` set.
fn closeTemp(fd: sys.fd_t) sys.Error!void {
    _ = try sys.result(ops.close(fd));
}

/// Close a temporary file whose result is not the one being returned.
/// Linux frees the descriptor whatever close reports, so the result is
/// ignored, and `sys.last_errno` stays the errno of the failure in hand.
fn closeDiscarded(fd: sys.fd_t) void {
    const saved = sys.last_errno;
    defer sys.last_errno = saved;
    _ = ops.close(fd);
}

fn renameTemp(old_path: []const u8, new_path: []const u8) sys.Error!void {
    var za: [sys.path_max:0]u8 = undefined;
    var zb: [sys.path_max:0]u8 = undefined;
    _ = try op(ops.renameat, .{ fsx.cwd, (try sys.z(&za, old_path)).ptr, fsx.cwd, (try sys.z(&zb, new_path)).ptr });
}

/// Python's OSError text for an error from one of the calls, so a message
/// reads "[Errno 13] Permission denied" as the Python tool prints it; the
/// errno comes from `sys.last_errno` (see `sys.describe`).
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Refused => "refused",
        error.OutOfMemory => "[Errno 12] Cannot allocate memory",
        else => |e| sys.describe(@errorCast(e)),
    };
}

/// Python's text for an OSError from a step of `atomicWrite`. `path` is the
/// filename and `path2` the second filename of a rename. A null path is a
/// call that carries none, such as write or fsync of an open descriptor.
/// The error itself is unchanged; `why.msg` holds the text.
fn failOs(a: Allocator, why: *Why, err: sys.Error, path: ?[]const u8, path2: ?[]const u8) Error {
    const text = sys.describe(err);
    if (path2) |second| {
        const q1 = pytext.reprStrAlloc(a, path orelse "") catch {
            why.msg = unallocated_refusal;
            return err;
        };
        defer a.free(q1);
        const q2 = pytext.reprStrAlloc(a, second) catch {
            why.msg = unallocated_refusal;
            return err;
        };
        defer a.free(q2);
        why.msg = a.print("{s}: {s} -> {s}", .{ text, q1, q2 }) catch unallocated_refusal;
    } else if (path) |one| {
        const q1 = pytext.reprStrAlloc(a, one) catch {
            why.msg = unallocated_refusal;
            return err;
        };
        defer a.free(q1);
        why.msg = a.print("{s}: {s}", .{ text, q1 }) catch unallocated_refusal;
    } else why.msg = a.print("{s}", .{text}) catch unallocated_refusal;
    return err;
}

/// Why a replacement failed; filled in when an error is returned. The
/// message may be allocated from the allocator given with `why` and belongs
/// to the caller: call `deinit` after any error.
pub const Why = struct {
    /// The reason for the failure; empty until there is one.
    msg: []const u8 = "",

    /// Free the message when it was allocated from `a`, and empty it. An
    /// empty `Why` may be passed, and `deinit` may be called again.
    pub fn deinit(why: *Why, a: Allocator) void {
        if (why.msg.len > 0 and why.msg.ptr != unallocated_refusal.ptr) a.free(why.msg);
        why.* = .{};
    }
};

/// The errors of this module: `error.Refused`, `error.OutOfMemory`, or the
/// `sys.Error` of a failed call, which `describe` words as Python does.
/// `atomicWrite` callers deinitialize `Why` after any error.
pub const Error = error{ Refused, OutOfMemory } || sys.Error;

/// The message of a refusal that could not allocate its own.
const unallocated_refusal: []const u8 = "refused";

fn refuse(a: Allocator, why: *Why, comptime f: []const u8, args: anytype) Error {
    why.msg = a.print(f, args) catch unallocated_refusal;
    return error.Refused;
}

/// The value of each ACL attribute present, keyed by its name.
pub const Acls = struct {
    /// One slot per `acl_attributes` form, in that order: the attribute's
    /// bytes, or null when the file does not have that form.
    present: [acl_attributes.len]?[]const u8 = .{ null, null, null },

    /// True when `x` and `y` have the same forms, with the same bytes.
    pub fn eql(x: Acls, y: Acls) bool {
        for (x.present, y.present) |p, q| {
            if ((p == null) != (q == null)) return false;
            if (p != null and !std.mem.eql(u8, p.?, q.?)) return false;
        }
        return true;
    }

    /// Free the values, allocated from `a` by the read that returned them.
    pub fn deinit(acls: Acls, a: Allocator) void {
        for (acls.present) |p| if (p) |v| a.free(v);
    }
};

/// The access metadata of a file, as `readMetadata` returns it: its stat,
/// for the owner, group and mode, and its ACLs.
pub const Metadata = struct {
    info: fsx.Stat,
    acls: Acls,

    /// Free the ACL values, allocated from `a` by `readMetadata`.
    pub fn deinit(m: Metadata, a: Allocator) void {
        m.acls.deinit(a);
    }
};

/// (dev, ino, uid, gid, mode, ctime): what a concurrent change moves.
fn identity(s: fsx.Stat) [7]i128 {
    return .{ s.dev, s.ino, s.uid, s.gid, s.mode, s.ctime.sec, s.ctime.nsec };
}

fn sameIdentity(x: fsx.Stat, y: fsx.Stat) bool {
    return std.mem.eql(i128, &identity(x), &identity(y));
}

fn isNfs4Family(name: []const u8) bool {
    return std.mem.eql(u8, name, "system.gpfs_nfs4_acl") or std.mem.eql(u8, name, "system.nfs4_acl");
}

/// Names of the listed ACL attributes; any other system.* attribute is
/// unsupported.
fn listedAcls(a: Allocator, fd: sys.fd_t, why: *Why) Error![acl_attributes.len]bool {
    var buf: [64 * 1024]u8 = undefined;
    const n = try op(ops.flistxattr, .{ fd, &buf });
    var listed = [_]bool{ false, false, false };
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        var known = false;
        for (acl_attributes, 0..) |acl, i| if (std.mem.eql(u8, acl, name)) {
            listed[i] = true;
            known = true;
        };
        if (!known and std.mem.startsWith(u8, name, "system."))
            return refuse(a, why, "unsupported access-control attribute {s}", .{name});
    }
    return listed;
}

/// One `fgetxattr`, retrying when a signal interrupts it. `op` cannot be
/// used here: the errno itself decides whether a missing attribute is an
/// error, and `op` collapses errnos into `sys.Error`.
fn xattrGet(fd: sys.fd_t, name: [:0]const u8, buf: []u8) usize {
    while (true) {
        const rc = ops.fgetxattr(fd, name, buf);
        if (linux.errno(rc) != .INTR) return rc;
    }
}

fn readAllAcls(a: Allocator, fd: sys.fd_t, why: *Why) Error!Acls {
    const listed = try listedAcls(a, fd, why);
    var acls: Acls = .{};
    errdefer acls.deinit(a);
    var buf: [64 * 1024]u8 = undefined;
    for (acl_attributes, 0..) |name, i| {
        const rc = xattrGet(fd, name, &buf);
        const e = linux.errno(rc);
        if (e == .SUCCESS) {
            acls.present[i] = try a.dupe(u8, buf[0..rc]);
            continue;
        }
        if (listed[i]) {
            if (e == .NODATA) return refuse(a, why, "{s} was listed but is no longer readable", .{name});
            return refuse(a, why, "cannot read {s}: {s}", .{ name, sys.describeErrno(e) });
        }
        if (e == .NODATA or e == .OPNOTSUPP) continue;
        // An unlisted NFSv4-family name may answer EINVAL where the same
        // inspection lists a POSIX access ACL, which is read here.
        if (e == .INVAL and isNfs4Family(name) and listed[2]) continue;
        return refuse(a, why, "cannot read {s}: {s}", .{ name, sys.describeErrno(e) });
    }
    if (listed[2] and acls.present[2] == null) return refuse(a, why, "{s} was listed but is no longer readable", .{posix_access});
    return acls;
}

/// Every listed or virtual ACL of an open regular file, read twice; a change
/// between the reads, or of the file's identity, is refused. The values are
/// allocated from `a`; `Acls.deinit` frees them.
pub fn readAcls(a: Allocator, fd: sys.fd_t, why: *Why) Error!Acls {
    const before = try fsx.fstat(fd);
    const acls = try readAllAcls(a, fd, why);
    errdefer acls.deinit(a);
    const again = try readAllAcls(a, fd, why);
    defer again.deinit(a);
    if (!acls.eql(again) or !sameIdentity(try fsx.fstat(fd), before))
        return refuse(a, why, "access metadata changed during inspection", .{});
    return acls;
}

/// The stat and ACLs of the regular file at `path`; `Metadata.deinit` frees
/// the ACLs, allocated from `a`.
pub fn readMetadata(a: Allocator, path: []const u8, why: *Why) Error!Metadata {
    const fd = try sys.openat(fsx.cwd, path, .{ .NOFOLLOW = true, .NONBLOCK = true }, 0);
    defer sys.close(fd);
    const info = try fsx.fstat(fd);
    if (!info.isReg()) return refuse(a, why, "metadata source is not a regular file: {s}", .{path});
    const acls = try readAcls(a, fd, why);
    errdefer acls.deinit(a);
    if (!sameIdentity(try fsx.fstat(fd), info)) return refuse(a, why, "access metadata changed during inspection", .{});
    return .{ .info = info, .acls = acls };
}

fn sameMetadata(x: Metadata, y: Metadata) bool {
    return sameIdentity(x.info, y.info) and x.acls.eql(y.acls);
}

/// Ownership and mode first (chown can clear set-id bits, chmod can rewrite
/// an NFSv4 ACL or a POSIX mask), then the most native ACL, then any extra
/// form removed, then everything read back.
fn restoreMetadata(a: Allocator, fd: sys.fd_t, metadata: ?Metadata, mode: u32, why: *Why) Error!void {
    const m = metadata orelse {
        _ = try op(ops.fchmod, .{ fd, mode });
        return;
    };
    _ = try op(ops.fchown, .{ fd, m.info.uid, m.info.gid });
    _ = try op(ops.fchmod, .{ fd, mode });
    var primary: ?usize = null;
    for (m.acls.present, 0..) |p, i| if (p != null) {
        primary = i;
        break;
    };
    if (primary) |i| {
        const now = try readAcls(a, fd, why);
        defer now.deinit(a);
        if (!now.eql(m.acls)) {
            const v = m.acls.present[i].?;
            _ = try op(ops.fsetxattr, .{ fd, acl_attributes[i], v });
        }
    }
    for (acl_attributes) |_| {
        const present = try readAcls(a, fd, why);
        defer present.deinit(a);
        var extra: ?usize = null;
        for (present.present, m.acls.present, 0..) |p, want, i| if (p != null and want == null) {
            extra = i;
            break;
        };
        const i = extra orelse break;
        _ = try op(ops.fremovexattr, .{ fd, acl_attributes[i] });
    }
    const restored = try fsx.fstat(fd);
    if (restored.uid != m.info.uid or restored.gid != m.info.gid or restored.perm() != mode)
        return refuse(a, why, "ownership or mode did not round-trip: expected {d}:{d} {o}, found {d}:{d} {o}", .{ m.info.uid, m.info.gid, mode, restored.uid, restored.gid, restored.perm() });
    const restored_acls = try readAcls(a, fd, why);
    defer restored_acls.deinit(a);
    if (!restored_acls.eql(m.acls)) return refuse(a, why, "access-control attributes did not round-trip", .{});
}

/// Called before each named step; a test hook can stop the program there.
/// In a replaceable build (tests, a tool's -Dtest-ops artifact) `fail_fn`
/// can also make the step fail; in any other build it is never asked.
pub const Faults = struct {
    /// Passed to both functions.
    ctx: ?*anyopaque = null,
    reach_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    /// True makes the step fail. Asked only in a replaceable build.
    fail_fn: ?*const fn (?*anyopaque, []const u8) bool = null,

    /// Call `reach_fn`, when there is one, with the name of the step about
    /// to run.
    pub fn reach(f: Faults, step: []const u8) void {
        if (f.reach_fn) |r| r(f.ctx, step);
    }

    /// Reach `step`, then whether a test asked it to fail.
    pub fn fails(f: Faults, step: []const u8) bool {
        f.reach(step);
        if (comptime !replaceable) return false;
        const ff = f.fail_fn orelse return false;
        return ff(f.ctx, step);
    }
};

/// The refusal text for a step a test made fail: Python's str() of
/// OSError(errno.EIO, "injected failure at STEP"). It is a refusal, so
/// describe() does not apply to it.
pub fn injected(a: Allocator, why: *Why, step: []const u8) Error {
    return refuse(a, why, "[Errno 5] injected failure at {s}", .{step});
}

fn exists(path: []const u8) bool {
    _ = fsx.statAt(fsx.cwd, path, false) catch return false;
    return true;
}

/// The process umask, read from the Umask line of /proc/self/status
/// (Linux 4.7 and later) so that no other thread sees it changed. Without
/// that line it is set to 0 and back, which another thread creating a file
/// at that moment would see.
fn currentUmask() u32 {
    if (umaskFromProc()) |m| return m;
    const old = linux.syscall1(.umask, 0);
    _ = linux.syscall1(.umask, old);
    return @intCast(old);
}

fn umaskFromProc() ?u32 {
    const fd = sys.openat(fsx.cwd, "/proc/self/status", .{}, 0) catch return null;
    defer sys.close(fd);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = sys.read(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |line| {
        const rest = if (std.mem.startsWith(u8, line, "Umask:")) line["Umask:".len..] else continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, rest, " \t"), 8) catch null;
    }
    return null;
}

/// Mode for a new file: the existing file's mode, otherwise 0644 less the
/// umask.
pub fn fileMode(path: []const u8) u32 {
    if (fsx.statAt(fsx.cwd, path, false)) |st| {
        if (!st.isLink()) return st.perm();
    } else |_| {}
    return 0o644 & ~currentUmask();
}

/// Open `path` read-only, fsync it and close it. For a directory, that
/// makes a rename or a new name in it durable. A failed close is returned
/// with `sys.last_errno` set. A close that EINTR interrupts is not retried
/// and is not an error, as `sys.result` treats EINTR. The close goes
/// through `ops.close`. On an earlier error the cleanup close is ignored
/// and that errno is kept.
pub fn fsyncDir(path: []const u8) sys.Error!void {
    const fd = try sys.openat(fsx.cwd, path, .{}, 0);
    var open = true;
    errdefer if (open) closeDiscarded(fd);
    try sys.fsync(fd);
    open = false;
    try closeTemp(fd);
}

/// os.makedirs(path, exist_ok=True): a name that exists as something
/// other than a directory is EEXIST, as Python re-raises FileExistsError,
/// a name under a file is ENOTDIR, as its mkdir call reports, and a name
/// under a dangling link is ENOENT. The recursion below a name only runs
/// when that name is absent, as Python checks `exists(head)` first and
/// swallows the recursion's FileExistsError.
pub fn makedirs(path: []const u8) sys.Error!void {
    var failed_path: ?[]const u8 = null;
    return makedirsTracked(path, &failed_path);
}

/// `makedirs`, also returning the path passed to the system call that
/// failed. The slice points into `path` and remains null on success.
pub fn makedirsTracked(path: []const u8, failed_path: *?[]const u8) sys.Error!void {
    failed_path.* = null;
    if (fsx.statAt(fsx.cwd, path, true)) |st| {
        if (st.isDir()) return;
        failed_path.* = path;
        return error.Exists;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) {
        if (fsx.statAt(fsx.cwd, parent, true)) |_| {} else |_| {
            makedirsTracked(parent, failed_path) catch |err| switch (err) {
                error.Exists => failed_path.* = null,
                else => return err,
            };
        }
    };
    var zb: [sys.path_max:0]u8 = undefined;
    const zpath = sys.z(&zb, path) catch |err| {
        failed_path.* = path;
        return err;
    };
    _ = sys.call(linux.mkdirat, .{ fsx.cwd, zpath.ptr, @as(linux.mode_t, 0o777) }) catch |err| switch (err) {
        error.Exists => {
            // A name another process created meanwhile passes only when
            // it is a directory; anything else keeps Python's EEXIST.
            const st = fsx.statAt(fsx.cwd, path, true) catch {
                failed_path.* = path;
                return error.Exists;
            };
            if (!st.isDir()) {
                failed_path.* = path;
                return error.Exists;
            }
        },
        else => {
            failed_path.* = path;
            return err;
        },
    };
}

test "makedirs surfaces the errnos of os.makedirs with exist_ok" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/zig-common-makedirs-{d}", .{ cwd, linux.getpid() });
    defer gpa.free(base);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};

    // an existing directory passes, as Python's isdir branch does
    try makedirs(base);

    const file = try std.fmt.allocPrint(gpa, "{s}/f", .{base});
    defer gpa.free(file);
    const fd = try sys.openat(fsx.cwd, file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    sys.close(fd);
    try std.testing.expectError(error.Exists, makedirs(file));
    try std.testing.expectEqualStrings("[Errno 17] File exists", sys.describe(error.Exists));

    const below_file = try std.fmt.allocPrint(gpa, "{s}/f/child", .{base});
    defer gpa.free(below_file);
    try std.testing.expectError(error.NotDir, makedirs(below_file));
    try std.testing.expectEqualStrings("[Errno 20] Not a directory", sys.describe(error.NotDir));

    // a dangling link at the final name also raises EEXIST in Python
    const dangling = try std.fmt.allocPrint(gpa, "{s}/dangling", .{base});
    defer gpa.free(dangling);
    _ = linux.symlinkat("nowhere", fsx.cwd, (try sys.z(&zb, dangling)).ptr);
    try std.testing.expectError(error.Exists, makedirs(dangling));

    // and with the dangling link above it, the missing parent is ENOENT
    const below_dangling = try std.fmt.allocPrint(gpa, "{s}/dangling/child", .{base});
    defer gpa.free(below_dangling);
    try std.testing.expectError(error.NotFound, makedirs(below_dangling));
    try std.testing.expectEqualStrings("[Errno 2] No such file or directory", sys.describe(error.NotFound));

    // A caller receives the ancestor passed to the mkdir that failed, not
    // the deeper leaf whose recursive creation was requested.
    const nested_target = try std.fmt.allocPrint(gpa, "{s}/dangling/child/grandchild/file", .{base});
    defer gpa.free(nested_target);
    const failed_ancestor = try std.fmt.allocPrint(gpa, "{s}/dangling/child", .{base});
    defer gpa.free(failed_ancestor);
    var why: Why = .{};
    defer why.deinit(gpa);
    try std.testing.expectError(error.NotFound, atomicWrite(gpa, nested_target, "x", .{}, &why));
    const quoted = try pytext.reprStrAlloc(gpa, failed_ancestor);
    defer gpa.free(quoted);
    const want = try std.fmt.allocPrint(gpa, "[Errno 2] No such file or directory: {s}", .{quoted});
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, why.msg);
}

/// What `atomicWrite` gives the new file besides its bytes, and the names
/// of its fault points.
pub const WriteOptions = struct {
    /// The permission bits. Null takes those of the metadata source, or,
    /// for a new file without one, 0644 less the umask.
    mode: ?u32 = null,
    /// A file whose owner, group, mode and ACLs the new file gets in place
    /// of the existing file's.
    metadata_from: ?[]const u8 = null,
    faults: Faults = .{},
    /// The first part of each fault point's name: `STEP.write`,
    /// `STEP.fsync` and `STEP.rename`.
    step: []const u8 = "write",
};

/// atomic_write: replace `path` only after its bytes and access metadata
/// are durable. The temporary file is synced and closed before the rename.
/// A failed close is reported the way a failed write or fsync is, with
/// no path in the message; the temporary file is removed and the
/// destination is left as it was. The descriptor is closed once on every
/// path. A close that EINTR interrupts is not retried, as Linux has freed
/// the descriptor, and is not an error, as `sys.result` treats EINTR; the
/// fsync before it has already flushed the bytes. An existing file keeps
/// its owner, mode and ACL forms, including the absence of one;
/// `metadata_from` names another file whose metadata to apply. Fault
/// points STEP.write, STEP.fsync and STEP.rename precede those
/// operations, and in a replaceable build can fail them (Faults.fails);
/// the destination is never unlinked first. The close goes through
/// `ops.close`. After the rename the parent directory is synced and closed
/// through that same call. A failed close of the directory is reported
/// with no path, and the destination keeps the bytes the rename published.
/// Everything it allocates from `a` is freed before it returns, except the
/// failure message in `why`. Call `why.deinit(a)` after any error.
pub fn atomicWrite(a: Allocator, path: []const u8, data: []const u8, opts: WriteOptions, why: *Why) Error!void {
    sys.last_errno = .SUCCESS;
    const parent = if (std.fs.path.dirname(path)) |d| (if (d.len > 0) d else ".") else ".";
    var failed_path: ?[]const u8 = null;
    makedirsTracked(parent, &failed_path) catch |err| return failOs(a, why, err, failed_path orelse parent, null);
    if (fsx.statAt(fsx.cwd, path, false)) |st| {
        if (st.isLink()) return refuse(a, why, "refusing to replace a symlink: {s}", .{path});
    } else |_| {}
    const metadata_path: ?[]const u8 = opts.metadata_from orelse (if (exists(path)) path else null);
    var metadata: ?Metadata = null;
    defer if (metadata) |m| m.deinit(a);
    if (metadata_path) |mp| {
        var inner: Why = .{};
        defer inner.deinit(a);
        metadata = readMetadata(a, mp, &inner) catch |err| return refuse(a, why, "cannot read access metadata for {s}: {s}", .{ mp, if (err == error.Refused) inner.msg else describe(err) });
    }
    const mode: u32 = opts.mode orelse (if (metadata) |m| m.info.perm() else fileMode(path));
    const tmp = try a.print("{s}/.{s}.new", .{ parent, std.fs.path.basename(path) });
    defer a.free(tmp);
    if (fsx.statAt(fsx.cwd, tmp, false)) |stale| {
        // A privileged writer hands its temporary file to the metadata owner
        // before a crash can interrupt it.
        const euid = ops.geteuid();
        const owner_ok = stale.uid == euid or (metadata != null and stale.uid == metadata.?.info.uid);
        if (!stale.isReg() or !owner_ok or stale.nlink != 1)
            return refuse(a, why, "temporary file must be an owned regular file with one link: {s}", .{tmp});
        sys.unlinkat(fsx.cwd, tmp, 0) catch |err| return failOs(a, why, err, tmp, null);
    } else |_| {}

    {
        const step = try a.print("{s}.write", .{opts.step});
        defer a.free(step);
        if (opts.faults.fails(step)) return injected(a, why, step);
    }
    const fd = openTemp(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600) catch |err|
        return failOs(a, why, err, tmp, null);
    const created = fsx.fstat(fd) catch |err| {
        // os.fstat names no path. Record that before the cleanup calls.
        const failed = failOs(a, why, err, null, null);
        // Created above with O_EXCL, so it is this call's file. A failed
        // cleanup must not replace the errno the message was built from.
        closeDiscarded(fd);
        const saved = sys.last_errno;
        defer sys.last_errno = saved;
        sys.unlinkat(fsx.cwd, tmp, 0) catch {};
        return failed;
    };
    ops.created(fd);
    var open = true;
    var renamed = false;
    errdefer if (!renamed) discard(tmp, created);
    defer if (open) closeDiscarded(fd);
    writeTemp(fd, data) catch |err| return failOs(a, why, err, null, null);
    {
        var inner: Why = .{};
        defer inner.deinit(a);
        restoreMetadata(a, fd, metadata, mode, &inner) catch |err| return refuse(a, why, "cannot preserve access metadata for {s}: {s}", .{ path, if (err == error.Refused) inner.msg else describe(err) });
    }
    {
        const step = try a.print("{s}.fsync", .{opts.step});
        defer a.free(step);
        if (opts.faults.fails(step)) return injected(a, why, step);
    }
    _ = op(ops.fsync, .{fd}) catch |err| return failOs(a, why, err, null, null);
    // Once, before the rename. A later failure must not close again.
    open = false;
    closeTemp(fd) catch |err| return failOs(a, why, err, null, null);
    if (metadata) |m| {
        var inner: Why = .{};
        defer inner.deinit(a);
        const current = readMetadata(a, metadata_path.?, &inner) catch |err| return refuse(a, why, "cannot recheck access metadata for {s}: {s}", .{ metadata_path.?, if (err == error.Refused) inner.msg else describe(err) });
        defer current.deinit(a);
        if (!sameMetadata(current, m)) return refuse(a, why, "access metadata of {s} changed before {s} was replaced", .{ metadata_path.?, path });
    }
    {
        const step = try a.print("{s}.rename", .{opts.step});
        defer a.free(step);
        if (opts.faults.fails(step)) return injected(a, why, step);
    }
    renameTemp(tmp, path) catch |err| return failOs(a, why, err, tmp, path);
    renamed = true;
    // Opening the directory names it. Flushing the descriptor names no file.
    const directory = sys.openat(fsx.cwd, parent, .{}, 0) catch |err| return failOs(a, why, err, parent, null);
    var dir_open = true;
    defer if (dir_open) closeDiscarded(directory);
    sys.fsync(directory) catch |err| return failOs(a, why, err, null, null);
    dir_open = false;
    closeTemp(directory) catch |err| return failOs(a, why, err, null, null);
}

/// atomic_write pinned to an open directory: replace `dir/name` with
/// `bytes` at exactly `mode`, whatever the process umask leaves, as
/// the tools' metrics writer does with the descriptor it holds. The
/// bytes go to a temporary file in the same directory, synced and
/// closed, and only then renamed over the destination. A failed write,
/// fchmod, fsync or close is returned with `sys.last_errno` set to its
/// errno; the destination is left as it was and the temporary file is
/// removed. A write lost on NFS may be reported only by the close. The
/// descriptor is closed once on every path. A close that EINTR
/// interrupts is not retried, as Linux has freed the descriptor, and is
/// not an error, as `sys.result` treats EINTR; the fsync before it has
/// already flushed the bytes. Shares atomicWrite's write, sync, close
/// and rename steps, through the same ops a replaceable build may fail.
/// Everything it allocates from `a` is freed before it returns.
pub fn atomicWriteAt(a: Allocator, dir: sys.fd_t, name: []const u8, data: []const u8, mode: u32) (Allocator.Error || sys.Error)!void {
    sys.last_errno = .SUCCESS;
    var rnd: [4]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
    const tmp = try a.print(".{s}.{d}.{x:0>8}.tmp", .{ name, linux.getpid(), std.mem.readInt(u32, &rnd, .little) });
    defer a.free(tmp);
    var zb: [sys.path_max:0]u8 = undefined;
    const ztmp = try sys.z(&zb, tmp);
    const flags: sys.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true };
    const fd: sys.fd_t = @intCast(try op(ops.openat, .{ dir, ztmp.ptr, flags, @as(linux.mode_t, 0o600) }));
    var open = true;
    var done = false;
    defer {
        if (open) closeDiscarded(fd);
        if (!done) {
            // The temporary name may already be gone. That failure is not
            // the call the caller is reporting.
            const saved = sys.last_errno;
            defer sys.last_errno = saved;
            sys.unlinkat(dir, tmp, 0) catch {};
        }
    }
    // openat applies the umask to the create, so the exact mode the
    // caller names is set on the descriptor before anything is written
    _ = try op(ops.fchmod, .{ fd, mode });
    try writeTemp(fd, data);
    _ = try op(ops.fsync, .{fd});
    // Once, before the rename. A later failure must not close again.
    open = false;
    try closeTemp(fd);
    var zn: [sys.path_max:0]u8 = undefined;
    _ = try op(ops.renameat, .{ dir, ztmp.ptr, dir, (try sys.z(&zn, name)).ptr });
    done = true;
    try sys.fsync(dir);
}

fn discard(tmp: []const u8, created: fsx.Stat) void {
    // stat or unlink can fail when the temporary name was removed
    // already. That failure is not the call the caller is reporting.
    const saved = sys.last_errno;
    defer sys.last_errno = saved;
    const cur = fsx.statAt(fsx.cwd, tmp, false) catch return;
    if (cur.dev == created.dev and cur.ino == created.ino) sys.unlinkat(fsx.cwd, tmp, 0) catch {};
}

var saved_nofile: linux.rlimit = undefined;
var nofile_lowered = false;

fn renameThenExhaustFiles(old_dir: sys.fd_t, old_path: [*:0]const u8, new_dir: sys.fd_t, new_path: [*:0]const u8) usize {
    const rc = linux.renameat(old_dir, old_path, new_dir, new_path);
    if (linux.errno(rc) != .SUCCESS) return rc;
    if (linux.errno(linux.prlimit(0, .NOFILE, null, &saved_nofile)) != .SUCCESS) return @bitCast(-@as(isize, @backingInt(linux.E.IO)));
    const none: linux.rlimit = .{ .cur = 0, .max = saved_nofile.max };
    if (linux.errno(linux.prlimit(0, .NOFILE, &none, null)) != .SUCCESS) return @bitCast(-@as(isize, @backingInt(linux.E.IO)));
    nofile_lowered = true;
    return rc;
}

fn restoreFileLimit() void {
    if (nofile_lowered) _ = linux.prlimit(0, .NOFILE, &saved_nofile, null);
    nofile_lowered = false;
}

test "Why.deinit frees a refusal's message only when it was allocated" {
    const gpa = std.testing.allocator;
    var why: Why = .{};
    why.deinit(gpa);
    try std.testing.expectEqual(error.Refused, refuse(gpa, &why, "cannot {s}", .{"write"}));
    try std.testing.expectEqualStrings("cannot write", why.msg);
    why.deinit(gpa);
    try std.testing.expectEqualStrings("", why.msg);
    try std.testing.expectEqual(error.Refused, refuse(std.testing.failing_allocator, &why, "cannot {s}", .{"write"}));
    try std.testing.expectEqualStrings("refused", why.msg);
    why.deinit(gpa);
    try std.testing.expectEqualStrings("", why.msg);
}

test "an OOM while formatting any OSError path keeps the system error" {
    const gpa = std.testing.allocator;
    var why: Why = .{};
    try std.testing.expectEqual(error.NoSpace, failOs(std.testing.failing_allocator, &why, error.NoSpace, "path", null));
    try std.testing.expectEqualStrings("refused", why.msg);
    why.deinit(gpa);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    try std.testing.expectEqual(error.NoSpace, failOs(failing.allocator(), &why, error.NoSpace, "path", null));
    try std.testing.expectEqualStrings("refused", why.msg);
    why.deinit(gpa);

    for (0..3) |fail_index| {
        var two_path_failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        try std.testing.expectEqual(error.NoSpace, failOs(two_path_failing.allocator(), &why, error.NoSpace, "old", "new"));
        try std.testing.expectEqualStrings("refused", why.msg);
        why.deinit(gpa);
    }
}

test "atomicWrite keeps the mode and refuses a symlink" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-atomic-{d}", .{ cwd, linux.getpid() });
    try makedirs(base);
    defer fsx.deleteTree(a, fsx.cwd, base) catch {};
    const p = try a.print("{s}/j.json", .{base});
    var why: Why = .{};
    defer why.deinit(a);
    try atomicWrite(a, p, "one\n", .{ .mode = 0o640 }, &why);
    try std.testing.expectEqual(@as(u32, 0o640), (try fsx.statAt(fsx.cwd, p, false)).perm());
    try atomicWrite(a, p, "two\n", .{}, &why);
    try std.testing.expectEqual(@as(u32, 0o640), (try fsx.statAt(fsx.cwd, p, false)).perm());
    const f = try fsx.openRegular(fsx.cwd, p, false);
    defer sys.close(f.fd);
    try std.testing.expectEqualStrings("two\n", try fsx.readAll(a, f.fd, 100));
    const link = try a.print("{s}/l.json", .{base});
    var zl: [sys.path_max:0]u8 = undefined;
    var zt: [sys.path_max:0]u8 = undefined;
    _ = linux.symlinkat((try sys.z(&zt, p)).ptr, fsx.cwd, (try sys.z(&zl, link)).ptr);
    try std.testing.expectError(error.Refused, atomicWrite(a, link, "x", .{}, &why));
    try std.testing.expect(std.mem.startsWith(u8, why.msg, "refusing to replace a symlink"));
    try std.testing.expect(!exists(try a.print("{s}/.j.json.new", .{base})));
}

fn failAt(ctx: ?*anyopaque, step: []const u8) bool {
    const want: *const []const u8 = @ptrCast(@alignCast(ctx.?));
    return std.mem.eql(u8, want.*, step);
}

test "a step a test makes fail leaves the destination and no temporary file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const dir = try a.print("{s}/.zig-cache/fails-test-{d}", .{ cwd, linux.getpid() });
    try makedirs(dir);
    defer fsx.deleteTree(a, fsx.cwd, dir) catch {};
    const path = try a.print("{s}/f", .{dir});
    var why: Why = .{};
    defer why.deinit(a);
    try atomicWrite(a, path, "old\n", .{}, &why);
    for ([_][]const u8{ "j.write", "j.fsync", "j.rename" }) |step| {
        var want: []const u8 = step;
        const faults: Faults = .{ .ctx = @ptrCast(&want), .fail_fn = failAt };
        try std.testing.expectError(error.Refused, atomicWrite(a, path, "new\n", .{ .faults = faults, .step = "j" }, &why));
        try std.testing.expectEqualStrings(try a.print("[Errno 5] injected failure at {s}", .{step}), why.msg);
        const f = try fsx.openRegular(fsx.cwd, path, false);
        defer sys.close(f.fd);
        try std.testing.expectEqualStrings("old\n", try fsx.readAll(a, f.fd, 16));
        try std.testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, try a.print("{s}/.f.new", .{dir}), false));
        why.deinit(a);
    }
}

test "opening a file in an unwritable directory names the temporary file" {
    if (linux.geteuid() == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const dir = try a.print("{s}/.zig-cache/atomic-ro-{d}", .{ cwd, linux.getpid() });
    try makedirs(dir);
    const directory = try sys.openat(fsx.cwd, dir, .{ .DIRECTORY = true }, 0);
    _ = linux.fchmod(directory, 0o555);
    sys.close(directory);
    defer {
        const again = sys.openat(fsx.cwd, dir, .{ .DIRECTORY = true }, 0) catch unreachable;
        _ = linux.fchmod(again, 0o755);
        sys.close(again);
        fsx.deleteTree(a, fsx.cwd, dir) catch {};
    }
    const path = try a.print("{s}/metrics.prom", .{dir});
    var why: Why = .{};
    defer why.deinit(a);
    try std.testing.expectError(error.AccessDenied, atomicWrite(a, path, "x\n", .{}, &why));
    const tmp = try a.print("{s}/.metrics.prom.new", .{dir});
    const quoted = try pytext.reprStrAlloc(a, tmp);
    defer a.free(quoted);
    const want = try a.print("[Errno 13] Permission denied: {s}", .{quoted});
    try std.testing.expectEqualStrings(want, why.msg);
    try std.testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, tmp, false));
}

test "atomicWrite frees what it allocates" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const dir = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/atomic-noleak-{d}", .{ cwd, linux.getpid() });
    defer gpa.free(dir);
    try makedirs(dir);
    defer fsx.deleteTree(gpa, fsx.cwd, dir) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/j.json", .{dir});
    defer gpa.free(path);
    var why: Why = .{};
    try atomicWrite(gpa, path, "one\n", .{}, &why);
    try atomicWrite(gpa, path, "two\n", .{}, &why);
    try std.testing.expectEqual(@as(usize, 0), why.msg.len);
}

test "a post-rename parent-open failure keeps its errno" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const dir = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/atomic-parent-open-{d}", .{ cwd, linux.getpid() });
    defer gpa.free(dir);
    try makedirs(dir);
    defer fsx.deleteTree(gpa, fsx.cwd, dir) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/f", .{dir});
    defer gpa.free(path);
    var why: Why = .{};
    defer why.deinit(gpa);
    const old_ops = ops.*;
    defer ops.* = old_ops;
    ops.renameat = renameThenExhaustFiles;
    defer restoreFileLimit();

    try std.testing.expectError(error.Unexpected, atomicWrite(gpa, path, "new\n", .{}, &why));
    try std.testing.expectEqual(linux.E.MFILE, sys.last_errno);
    const quoted = try pytext.reprStrAlloc(gpa, dir);
    defer gpa.free(quoted);
    const want = try std.fmt.allocPrint(gpa, "[Errno 24] Too many open files: {s}", .{quoted});
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, why.msg);
    restoreFileLimit();
    const live = try fsx.openRegular(fsx.cwd, path, false);
    defer sys.close(live.fd);
    const bytes = try fsx.readAll(gpa, live.fd, 16);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("new\n", bytes);
}

test "an interrupted ACL read is retried" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const dir = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/atomic-eintr-{d}", .{ cwd, linux.getpid() });
    defer gpa.free(dir);
    try makedirs(dir);
    defer fsx.deleteTree(gpa, fsx.cwd, dir) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/f", .{dir});
    defer gpa.free(path);
    const created = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    sys.close(created);
    const fd = try sys.openat(fsx.cwd, path, .{}, 0);
    defer sys.close(fd);
    const old = ops.*;
    defer ops.* = old;
    const S = struct {
        var left: u8 = 0;
        fn get(fd_: sys.fd_t, name: [:0]const u8, buf: []u8) usize {
            if (left > 0) {
                left -= 1;
                return @bitCast(-@as(isize, @backingInt(linux.E.INTR)));
            }
            return linux.fgetxattr(fd_, name.ptr, buf.ptr, buf.len);
        }
    };
    S.left = 2;
    ops.fgetxattr = S.get;
    var why: Why = .{};
    const acls = try readAcls(gpa, fd, &why);
    defer acls.deinit(gpa);
}

test "atomicWriteAt publishes the exact mode under any umask" {
    const gpa = std.testing.allocator;
    var pb: [sys.path_max]u8 = undefined;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.mem.print(&pb, "{s}/.zig-cache/zig-common-atomic-at-{d}", .{ cwd, linux.getpid() });
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(dir);
    }

    // the umask bites the create but not the published mode, which is
    // exactly what the caller names, as the metrics writer's chmod does
    const old: u32 = @intCast(linux.syscall1(.umask, 0o077));
    defer _ = linux.syscall1(.umask, old);
    try atomicWriteAt(gpa, dir, "metrics", "first\n", 0o644);
    const first = try fsx.statAt(dir, "metrics", false);
    try std.testing.expectEqual(@as(u32, 0o644), first.perm());

    // an existing destination is replaced with the mode it is given and
    // keeps its bytes when a step fails, with no temporary left behind
    try atomicWriteAt(gpa, dir, "metrics", "second\n", 0o640);
    const second = try fsx.statAt(dir, "metrics", false);
    try std.testing.expectEqual(@as(u32, 0o640), second.perm());
    const f = try fsx.openRegular(dir, "metrics", false);
    defer sys.close(f.fd);
    const second_text = try fsx.readAll(gpa, f.fd, 100);
    defer gpa.free(second_text);
    try std.testing.expectEqualStrings("second\n", second_text);

    const S = struct {
        var fail_fsync = false;
        fn fsync(fd_: sys.fd_t) usize {
            if (fail_fsync) return @bitCast(-@as(isize, @backingInt(linux.E.IO)));
            return linux.fsync(fd_);
        }
    };
    defer ops.* = .{};
    S.fail_fsync = true;
    ops.fsync = S.fsync;
    try std.testing.expectError(error.Unexpected, atomicWriteAt(gpa, dir, "metrics", "broken\n", 0o644));
    S.fail_fsync = false;
    const after = try fsx.openRegular(dir, "metrics", false);
    defer sys.close(after.fd);
    const after_text = try fsx.readAll(gpa, after.fd, 100);
    defer gpa.free(after_text);
    try std.testing.expectEqualStrings("second\n", after_text);
    var it = try fsx.DirIter.init(gpa, dir);
    defer it.deinit(gpa);
    while (try it.next()) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.name, ".tmp") == null);
    }
}

test "the umask is read without changing it" {
    const old: u32 = @intCast(linux.syscall1(.umask, 0o027));
    defer _ = linux.syscall1(.umask, old);
    try std.testing.expectEqual(@as(?u32, 0o027), umaskFromProc());
    try std.testing.expectEqual(@as(u32, 0o027), currentUmask());
    try std.testing.expectEqual(@as(u32, 0o640), fileMode("/nonexistent/zig-common-umask-test"));
}
