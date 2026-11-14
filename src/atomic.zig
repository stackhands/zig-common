//! Same-directory replacement of a file whose access metadata must survive:
//! the bytes, owner, mode and every listed ACL form are written to a
//! temporary file, read back, made durable, and only then renamed over the
//! destination. The ACL forms are the GPFS native NFSv4 ACL, the generic
//! NFSv4 ACL and the POSIX access ACL, most native first; a filesystem may
//! expose one ACL through several of them.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");

const Allocator = std.mem.Allocator;

pub const acl_attributes = [_][:0]const u8{ "system.gpfs_nfs4_acl", "system.nfs4_acl", "system.posix_acl_access" };
const posix_access = "system.posix_acl_access";

/// The calls atomicWrite makes on a file descriptor, as raw system-call
/// results. Programs leave them alone; tests replace them, under
/// builtin.is_test only, to emulate a filesystem's ACL model or a failing
/// call. `created` runs on the temporary file right after its O_EXCL
/// creation, where a filesystem applies an inherited ACL.
pub const Ops = struct {
    flistxattr: *const fn (fd: sys.fd_t, buf: []u8) usize = realList,
    fgetxattr: *const fn (fd: sys.fd_t, name: [:0]const u8, buf: []u8) usize = realGet,
    fsetxattr: *const fn (fd: sys.fd_t, name: [:0]const u8, value: []const u8) usize = realSet,
    fremovexattr: *const fn (fd: sys.fd_t, name: [:0]const u8) usize = realRemove,
    fchmod: *const fn (fd: sys.fd_t, mode: u32) usize = realChmod,
    fchown: *const fn (fd: sys.fd_t, uid: linux.uid_t, gid: linux.gid_t) usize = realChown,
    fsync: *const fn (fd: sys.fd_t) usize = realFsync,
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

/// Why a replacement was refused; filled in when an error is returned.
pub const Why = struct {
    msg: []const u8 = "",
};

pub const Error = error{ Refused, OutOfMemory } || sys.Error;

fn refuse(a: Allocator, why: *Why, comptime f: []const u8, args: anytype) Error {
    why.msg = a.print(f, args) catch "refused";
    return error.Refused;
}

/// The value of each ACL attribute present, keyed by its name.
pub const Acls = struct {
    present: [acl_attributes.len]?[]const u8 = .{ null, null, null },

    pub fn eql(x: Acls, y: Acls) bool {
        for (x.present, y.present) |p, q| {
            if ((p == null) != (q == null)) return false;
            if (p != null and !std.mem.eql(u8, p.?, q.?)) return false;
        }
        return true;
    }
};

pub const Metadata = struct { info: fsx.Stat, acls: Acls };

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

fn errnoText(e: linux.E) []const u8 {
    return switch (e) {
        .ACCES => "Permission denied",
        .PERM => "Operation not permitted",
        .IO => "Input/output error",
        .INVAL => "Invalid argument",
        .NODATA => "No data available",
        .OPNOTSUPP => "Operation not supported",
        else => @tagName(e),
    };
}

fn readAllAcls(a: Allocator, fd: sys.fd_t, why: *Why) Error!Acls {
    const listed = try listedAcls(a, fd, why);
    var acls: Acls = .{};
    var buf: [64 * 1024]u8 = undefined;
    for (acl_attributes, 0..) |name, i| {
        const rc = ops.fgetxattr(fd, name, &buf);
        const e = linux.errno(rc);
        if (e == .SUCCESS) {
            acls.present[i] = try a.dupe(u8, buf[0..rc]);
            continue;
        }
        if (listed[i]) {
            if (e == .NODATA) return refuse(a, why, "{s} was listed but is no longer readable", .{name});
            return refuse(a, why, "cannot read {s}: [Errno {d}] {s}", .{ name, @backingInt(e), errnoText(e) });
        }
        if (e == .NODATA or e == .OPNOTSUPP) continue;
        // An unlisted NFSv4-family name may answer EINVAL where the same
        // inspection lists a POSIX access ACL, which is read here.
        if (e == .INVAL and isNfs4Family(name) and listed[2]) continue;
        return refuse(a, why, "cannot read {s}: [Errno {d}] {s}", .{ name, @backingInt(e), errnoText(e) });
    }
    if (listed[2] and acls.present[2] == null) return refuse(a, why, "{s} was listed but is no longer readable", .{posix_access});
    return acls;
}

/// Every listed or virtual ACL of an open regular file, read twice; a change
/// between the reads, or of the file's identity, is refused.
pub fn readAcls(a: Allocator, fd: sys.fd_t, why: *Why) Error!Acls {
    const before = try fsx.fstat(fd);
    const acls = try readAllAcls(a, fd, why);
    const again = try readAllAcls(a, fd, why);
    if (!acls.eql(again) or !sameIdentity(try fsx.fstat(fd), before))
        return refuse(a, why, "access metadata changed during inspection", .{});
    return acls;
}

pub fn readMetadata(a: Allocator, path: []const u8, why: *Why) Error!Metadata {
    const fd = try sys.openat(fsx.cwd, path, .{ .NOFOLLOW = true, .NONBLOCK = true }, 0);
    defer sys.close(fd);
    const info = try fsx.fstat(fd);
    if (!info.isReg()) return refuse(a, why, "metadata source is not a regular file: {s}", .{path});
    const acls = try readAcls(a, fd, why);
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
        if (!(try readAcls(a, fd, why)).eql(m.acls)) {
            const v = m.acls.present[i].?;
            _ = try op(ops.fsetxattr, .{ fd, acl_attributes[i], v });
        }
    }
    for (acl_attributes) |_| {
        const present = try readAcls(a, fd, why);
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
    if (!(try readAcls(a, fd, why)).eql(m.acls)) return refuse(a, why, "access-control attributes did not round-trip", .{});
}

/// Called before each named step; a test hook can stop the program there.
/// In a replaceable build (tests, a tool's -Dtest-ops artifact) `fail_fn`
/// can also make the step fail; in any other build it is never asked.
pub const Faults = struct {
    ctx: ?*anyopaque = null,
    reach_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    fail_fn: ?*const fn (?*anyopaque, []const u8) bool = null,

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

pub fn fsyncDir(path: []const u8) sys.Error!void {
    const fd = try sys.openat(fsx.cwd, path, .{}, 0);
    defer sys.close(fd);
    try sys.fsync(fd);
}

/// os.makedirs(path, exist_ok=True).
pub fn makedirs(path: []const u8) sys.Error!void {
    if (fsx.statAt(fsx.cwd, path, true)) |st| {
        if (st.isDir()) return;
        return error.NotDir;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try makedirs(parent);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = sys.call(linux.mkdirat, .{ fsx.cwd, (try sys.z(&zb, path)).ptr, @as(linux.mode_t, 0o777) }) catch |err| switch (err) {
        error.Exists => {},
        else => return err,
    };
}

pub const WriteOptions = struct {
    mode: ?u32 = null,
    metadata_from: ?[]const u8 = null,
    faults: Faults = .{},
    step: []const u8 = "write",
};

/// atomic_write: replace `path` only after its bytes and access metadata
/// are durable. An existing file keeps its owner, mode and ACL forms,
/// including the absence of one; `metadata_from` names another file whose
/// metadata to apply. Fault points STEP.write, STEP.fsync and STEP.rename
/// precede those operations, and in a replaceable build can fail them
/// (Faults.fails); the destination is never unlinked first.
pub fn atomicWrite(a: Allocator, path: []const u8, data: []const u8, opts: WriteOptions, why: *Why) Error!void {
    sys.last_errno = .SUCCESS;
    const parent = if (std.fs.path.dirname(path)) |d| (if (d.len > 0) d else ".") else ".";
    try makedirs(parent);
    if (fsx.statAt(fsx.cwd, path, false)) |st| {
        if (st.isLink()) return refuse(a, why, "refusing to replace a symlink: {s}", .{path});
    } else |_| {}
    const metadata_path: ?[]const u8 = opts.metadata_from orelse (if (exists(path)) path else null);
    var metadata: ?Metadata = null;
    if (metadata_path) |mp| {
        var inner: Why = .{};
        metadata = readMetadata(a, mp, &inner) catch |err| return refuse(a, why, "cannot read access metadata for {s}: {s}", .{ mp, if (err == error.Refused) inner.msg else describe(err) });
    }
    const mode: u32 = opts.mode orelse (if (metadata) |m| m.info.perm() else fileMode(path));
    const tmp = try a.print("{s}/.{s}.new", .{ parent, std.fs.path.basename(path) });
    if (fsx.statAt(fsx.cwd, tmp, false)) |stale| {
        // A privileged writer hands its temporary file to the metadata owner
        // before a crash can interrupt it.
        const euid = ops.geteuid();
        const owner_ok = stale.uid == euid or (metadata != null and stale.uid == metadata.?.info.uid);
        if (!stale.isReg() or !owner_ok or stale.nlink != 1)
            return refuse(a, why, "temporary file must be an owned regular file with one link: {s}", .{tmp});
        try sys.unlinkat(fsx.cwd, tmp, 0);
    } else |_| {}

    {
        const step = try a.print("{s}.write", .{opts.step});
        if (opts.faults.fails(step)) return injected(a, why, step);
    }
    const fd = try sys.openat(fsx.cwd, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    const created = fsx.fstat(fd) catch |err| {
        sys.close(fd);
        // Created above with O_EXCL, so it is this call's file.
        sys.unlinkat(fsx.cwd, tmp, 0) catch {};
        return err;
    };
    ops.created(fd);
    errdefer discard(tmp, created);
    {
        defer sys.close(fd);
        try sys.writeAll(fd, data);
        var inner: Why = .{};
        restoreMetadata(a, fd, metadata, mode, &inner) catch |err| return refuse(a, why, "cannot preserve access metadata for {s}: {s}", .{ path, if (err == error.Refused) inner.msg else describe(err) });
        {
            const step = try a.print("{s}.fsync", .{opts.step});
            if (opts.faults.fails(step)) return injected(a, why, step);
        }
        _ = try op(ops.fsync, .{fd});
    }
    if (metadata) |m| {
        var inner: Why = .{};
        const current = readMetadata(a, metadata_path.?, &inner) catch |err| return refuse(a, why, "cannot recheck access metadata for {s}: {s}", .{ metadata_path.?, if (err == error.Refused) inner.msg else describe(err) });
        if (!sameMetadata(current, m)) return refuse(a, why, "access metadata of {s} changed before {s} was replaced", .{ metadata_path.?, path });
    }
    {
        const step = try a.print("{s}.rename", .{opts.step});
        if (opts.faults.fails(step)) return injected(a, why, step);
    }
    try sys.renameat(fsx.cwd, tmp, fsx.cwd, path);
    try fsyncDir(parent);
}

fn discard(tmp: []const u8, created: fsx.Stat) void {
    const cur = fsx.statAt(fsx.cwd, tmp, false) catch return;
    if (cur.dev == created.dev and cur.ino == created.ino) sys.unlinkat(fsx.cwd, tmp, 0) catch {};
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
    }
}

test "the umask is read without changing it" {
    const old: u32 = @intCast(linux.syscall1(.umask, 0o027));
    defer _ = linux.syscall1(.umask, old);
    try std.testing.expectEqual(@as(?u32, 0o027), umaskFromProc());
    try std.testing.expectEqual(@as(u32, 0o027), currentUmask());
    try std.testing.expectEqual(@as(u32, 0o640), fileMode("/nonexistent/zig-common-umask-test"));
}
