//! Tests of atomicWrite's access-metadata handling, ported from the Python
//! tool's tests (test_acl_models, test_acl_probe_compatibility,
//! test_posix_acl_descriptor, test_atomic_metadata, test_virtual_acl_restore,
//! test_stale_temporary).
//!
//! Filesystem ACL models are emulated at the descriptor calls through
//! `atomic.ops`: attributes are stored per inode, so they follow a rename.
//! The POSIX tests use the kernel's ACLs with a spy over the same calls. A
//! crash is a forked child that exits at the named fault point.
const std = @import("std");
const linux = std.os.linux;
const atomic = @import("atomic.zig");
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const GPFS: usize = 0;
const NFS4: usize = 1;
const POSIX: usize = 2;
const names = atomic.acl_attributes;
const posix_default = "system.posix_acl_default";

/// \x00\x01native-acl\xff\xfe\x00 and every byte value.
const OPAQUE = blk: {
    const head = "\x00\x01native-acl\xff\xfe\x00";
    var out: [head.len + 256]u8 = undefined;
    @memcpy(out[0..head.len], head);
    for (0..256) |i| out[head.len + i] = @intCast(i);
    break :blk out;
};

// ---- per-test state ------------------------------------------------------

var arena_state: std.heap.ArenaAllocator = undefined;
var A: Allocator = undefined;
var counter: usize = 0;

fn begin() void {
    arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    A = arena_state.allocator();
    model = null;
    over = .{};
    atomic.ops.* = .{};
}

fn end() void {
    atomic.ops.* = .{};
    model = null;
    over = .{};
    arena_state.deinit();
}

fn err(e: linux.E) usize {
    return @bitCast(-@as(isize, @backingInt(e)));
}

fn z(s: []const u8) [:0]const u8 {
    return A.dupeSentinel(u8, s, 0) catch unreachable;
}

/// A new directory below the build's cache, where the file system keeps
/// POSIX ACLs (a tmpfs /tmp may not).
fn tmpdir() []const u8 {
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = fsx.realpath(fsx.cwd, ".", &cwd_buf) catch unreachable;
    counter += 1;
    const path = A.print("{s}/.zig-cache/atomic-test-{d}-{d}", .{ cwd, linux.getpid(), counter }) catch unreachable;
    atomic.makedirs(path) catch unreachable;
    return path;
}

fn cleanup(dir: []const u8) void {
    fsx.deleteTree(A, fsx.cwd, dir) catch {};
}

fn join(dir: []const u8, name: []const u8) []const u8 {
    return A.print("{s}/{s}", .{ dir, name }) catch unreachable;
}

fn writeFile(path: []const u8, data: []const u8) void {
    const fd = sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch unreachable;
    defer sys.close(fd);
    sys.writeAll(fd, data) catch unreachable;
}

fn readFile(path: []const u8) []const u8 {
    const f = fsx.openRegular(fsx.cwd, path, false) catch unreachable;
    defer sys.close(f.fd);
    return fsx.readAll(A, f.fd, 1 << 20) catch unreachable;
}

fn chmod(path: []const u8, mode: u32) void {
    _ = linux.fchmodat(linux.AT.FDCWD, z(path).ptr, @intCast(mode));
}

fn modeOf(path: []const u8) u32 {
    return (fsx.statAt(fsx.cwd, path, true) catch unreachable).perm();
}

fn statOf(path: []const u8) fsx.Stat {
    return fsx.statAt(fsx.cwd, path, false) catch unreachable;
}

fn exists(path: []const u8) bool {
    _ = fsx.statAt(fsx.cwd, path, false) catch return false;
    return true;
}

fn isDir(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, false) catch return false;
    return st.isDir();
}

fn fdPath(fd: sys.fd_t) []const u8 {
    var buf: [sys.path_max]u8 = undefined;
    const link = A.print("/proc/self/fd/{d}", .{fd}) catch unreachable;
    const n = linux.readlinkat(linux.AT.FDCWD, z(link).ptr, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return "";
    return A.dupe(u8, buf[0..n]) catch unreachable;
}

fn keyOf(fd: sys.fd_t) [2]u64 {
    const st = fsx.fstat(fd) catch unreachable;
    return .{ st.dev, st.ino };
}

/// An attribute change updates ctime, as on a real file system.
fn touch(fd: sys.fd_t) void {
    const st = fsx.fstat(fd) catch unreachable;
    _ = linux.fchmod(fd, @intCast(st.perm()));
}

fn write(path: []const u8, data: []const u8, opts: atomic.WriteOptions) atomic.Error!void {
    var why: atomic.Why = .{};
    atomic.atomicWrite(A, path, data, opts, &why) catch |e| {
        last_why = why.msg;
        return e;
    };
}

var last_why: []const u8 = "";

fn expectRefused(result: atomic.Error!void, comptime contains: ?[]const u8) !void {
    try testing.expectError(error.Refused, result);
    if (contains) |c| {
        if (std.mem.find(u8, last_why, c) == null) {
            std.debug.print("refusal '{s}' does not contain '{s}'\n", .{ last_why, c });
            return error.TestUnexpectedResult;
        }
    }
}

const replace: atomic.WriteOptions = .{ .step = "replace" };

// ---- fault points ------------------------------------------------------------

var fault_step: []const u8 = "";
var fault_action: ?*const fn () void = null;
var reached: std.ArrayList([]const u8) = .empty;

fn reachHook(_: ?*anyopaque, step: []const u8) void {
    reached.append(A, A.dupe(u8, step) catch unreachable) catch {};
    if (std.mem.eql(u8, step, fault_step)) if (fault_action) |f| f();
}

fn hooked(step: []const u8, action: *const fn () void) atomic.WriteOptions {
    fault_step = step;
    fault_action = action;
    reached = .empty;
    return .{ .step = "replace", .faults = .{ .reach_fn = reachHook } };
}

fn wasReached(step: []const u8) bool {
    for (reached.items) |s| if (std.mem.eql(u8, s, step)) return true;
    return false;
}

fn exitNow() void {
    linux.exit_group(0);
}

/// atomicWrite in a forked child that exits at `step`, as a crash would.
fn crashAt(path: []const u8, data: []const u8, step: []const u8) !void {
    const pid: isize = @bitCast(linux.fork());
    if (pid == 0) {
        var why: atomic.Why = .{};
        atomic.atomicWrite(A, path, data, hooked(step, exitNow), &why) catch linux.exit_group(3);
        linux.exit_group(4);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), @ptrCast(&status), 0, null);
    try testing.expect(linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0);
}

// ---- overrides of the non-xattr calls ------------------------------------------

const Over = struct {
    fchown: ?linux.E = null,
    fsync: ?linux.E = null,
    fsync_action: ?*const fn (sys.fd_t) void = null,
    euid: ?linux.uid_t = null,
};
var over: Over = .{};

fn oChown(fd: sys.fd_t, uid: linux.uid_t, gid: linux.gid_t) usize {
    record(.chown, fd, null);
    if (over.fchown) |e| return err(e);
    return linux.fchown(fd, uid, gid);
}

fn oFsync(fd: sys.fd_t) usize {
    if (over.fsync_action) |f| f(fd);
    if (over.fsync) |e| return err(e);
    return linux.fsync(fd);
}

fn oEuid() linux.uid_t {
    return over.euid orelse linux.geteuid();
}

fn installOverrides() void {
    atomic.ops.fchown = oChown;
    atomic.ops.fsync = oFsync;
    atomic.ops.geteuid = oEuid;
}

// ---- ACL models ------------------------------------------------------------

const Op = enum { list, get, set, remove, chmod, chown };
const Call = struct { op: Op, path: []const u8, name: ?usize };

const Out = union(enum) {
    pass,
    fail: linux.E,
    /// listxattr: these names instead of the stored ones.
    list: []const []const u8,
};

const Hook = *const fn (fd: sys.fd_t, name: ?usize) Out;

const Attrs = [3]?[]const u8;

/// One file system's ACL interface. `supported` are the names getxattr and
/// setxattr accept; `views` derive other names from the native bytes by a
/// prefix. Writing a derived name replaces the native ACL with a translated
/// one. `chmod_rewrites` makes chmod regenerate the native ACL, as NFSv4
/// servers and GPFS do. With `kernel`, the calls go to the real file
/// system after the hooks: a spy, not a model.
const Model = struct {
    label: []const u8,
    native: usize,
    supported: [3]bool,
    views: [3]?[]const u8 = .{ null, null, null },
    chmod_rewrites: bool = true,
    kernel: bool = false,
    /// The virtual NFSv4 model: a new inode shows a mode-derived NFSv4 view
    /// that is never listed and cannot be removed.
    virtual: bool = false,
    replace_virtual: bool = true,
    lossy: bool = false,
    store: std.AutoHashMapUnmanaged([2]u64, Attrs) = .empty,
    calls: std.ArrayList(Call) = .empty,
    hooks: struct { list: ?Hook = null, get: ?Hook = null, set: ?Hook = null, remove: ?Hook = null, chmod: ?Hook = null } = .{},
    inherit: ?[]const u8 = null,

    fn attrs(m: *Model, fd: sys.fd_t) *Attrs {
        const g = m.store.getOrPut(A, keyOf(fd)) catch unreachable;
        if (!g.found_existing) g.value_ptr.* = .{ null, null, null };
        return g.value_ptr;
    }

    fn writeNative(m: *Model, at: *Attrs, value: []const u8) void {
        at[m.native] = A.dupe(u8, value) catch unreachable;
        for (m.views, 0..) |v, i| if (v) |prefix| {
            at[i] = std.mem.concat(A, u8, &.{ prefix, value }) catch unreachable;
        };
    }

    fn setPath(m: *Model, path: []const u8, name: usize, value: []const u8) void {
        if (m.kernel) {
            _ = linux.setxattr(z(path).ptr, names[name].ptr, value.ptr, value.len, 0);
            return;
        }
        const fd = sys.openat(fsx.cwd, path, .{}, 0) catch unreachable;
        defer sys.close(fd);
        const at = m.attrs(fd);
        if (name == m.native) m.writeNative(at, value) else at[name] = A.dupe(u8, value) catch unreachable;
        touch(fd);
    }

    fn getPath(m: *Model, path: []const u8) Attrs {
        if (m.kernel) {
            var out: Attrs = .{ null, null, null };
            var buf: [64 * 1024]u8 = undefined;
            for (names, 0..) |n, i| {
                const rc = linux.getxattr(z(path).ptr, n.ptr, &buf, buf.len);
                if (linux.errno(rc) == .SUCCESS) out[i] = A.dupe(u8, buf[0..rc]) catch unreachable;
            }
            return out;
        }
        const fd = sys.openat(fsx.cwd, path, .{}, 0) catch unreachable;
        defer sys.close(fd);
        return m.attrs(fd).*;
    }

    fn opsOf(m: *Model, op: Op) []const Call {
        var out: std.ArrayList(Call) = .empty;
        for (m.calls.items) |c| if (c.op == op) out.append(A, c) catch unreachable;
        return out.items;
    }
};

var model: ?*Model = null;

fn record(op: Op, fd: sys.fd_t, name: ?usize) void {
    const m = model orelse return;
    m.calls.append(A, .{ .op = op, .path = fdPath(fd), .name = name }) catch unreachable;
}

fn indexOf(name: [:0]const u8) usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    unreachable;
}

fn run(h: ?Hook, fd: sys.fd_t, name: ?usize) Out {
    const f = h orelse return .pass;
    return f(fd, name);
}

fn mList(fd: sys.fd_t, buf: []u8) usize {
    const m = model.?;
    record(.list, fd, null);
    var listed: std.ArrayList([]const u8) = .empty;
    switch (run(m.hooks.list, fd, null)) {
        .fail => |e| return err(e),
        .list => |l| listed.appendSlice(A, l) catch unreachable,
        .pass => {
            if (m.kernel) return linux.flistxattr(fd, buf.ptr, buf.len);
            for (m.attrs(fd).*, 0..) |v, i| if (v != null and !(m.virtual and i == NFS4)) listed.append(A, names[i]) catch unreachable;
        },
    }
    var n: usize = 0;
    for (listed.items) |name| {
        @memcpy(buf[n .. n + name.len], name);
        buf[n + name.len] = 0;
        n += name.len + 1;
    }
    return n;
}

fn mGet(fd: sys.fd_t, name: [:0]const u8, buf: []u8) usize {
    const m = model.?;
    const i = indexOf(name);
    record(.get, fd, i);
    switch (run(m.hooks.get, fd, i)) {
        .fail => |e| return err(e),
        else => {},
    }
    if (m.kernel) return linux.fgetxattr(fd, name.ptr, buf.ptr, buf.len);
    if (m.attrs(fd)[i]) |v| {
        @memcpy(buf[0..v.len], v);
        return v.len;
    }
    if (!m.supported[i]) return err(.OPNOTSUPP);
    return err(.NODATA);
}

fn mSet(fd: sys.fd_t, name: [:0]const u8, value: []const u8) usize {
    const m = model.?;
    const i = indexOf(name);
    record(.set, fd, i);
    switch (run(m.hooks.set, fd, i)) {
        .fail => |e| return err(e),
        else => {},
    }
    if (m.kernel) return linux.fsetxattr(fd, name.ptr, value.ptr, value.len, 0);
    if (!m.supported[i]) return err(.OPNOTSUPP);
    const v = if (m.lossy) value[0 .. value.len - 1] else value;
    const at = m.attrs(fd);
    if (i == m.native) m.writeNative(at, v) else m.writeNative(at, std.mem.concat(A, u8, &.{ "translated:", v }) catch unreachable);
    touch(fd);
    if (m.virtual and i == POSIX and m.replace_virtual) at[NFS4] = null;
    return 0;
}

fn mRemove(fd: sys.fd_t, name: [:0]const u8) usize {
    const m = model.?;
    const i = indexOf(name);
    record(.remove, fd, i);
    switch (run(m.hooks.remove, fd, i)) {
        .fail => |e| return err(e),
        else => {},
    }
    if (m.kernel) return linux.fremovexattr(fd, name.ptr);
    if (m.virtual and i == NFS4) return err(.PERM);
    const at = m.attrs(fd);
    if (!m.supported[i]) return err(.OPNOTSUPP);
    if (at[i] == null) return err(.NODATA);
    if (i == m.native) for (m.views, 0..) |v, j| if (v != null) {
        at[j] = null;
    };
    at[i] = null;
    touch(fd);
    return 0;
}

fn mChmod(fd: sys.fd_t, mode: u32) usize {
    const m = model.?;
    record(.chmod, fd, null);
    switch (run(m.hooks.chmod, fd, null)) {
        .fail => |e| return err(e),
        else => {},
    }
    const rc = linux.fchmod(fd, @intCast(mode));
    if (m.kernel) return rc;
    const at = m.attrs(fd);
    if (m.chmod_rewrites and at[m.native] != null) m.writeNative(at, A.print("chmod-regenerated:{o}", .{mode}) catch unreachable);
    if (m.virtual and at[NFS4] != null) at[NFS4] = A.print("mode-derived:{o}", .{mode}) catch unreachable;
    return rc;
}

fn mCreated(fd: sys.fd_t) void {
    const m = model.?;
    if (m.kernel) return;
    m.store.put(A, keyOf(fd), .{ null, null, null }) catch unreachable;
    const at = m.attrs(fd);
    if (m.inherit) |v| m.writeNative(at, v);
    if (m.virtual) at[NFS4] = "mode-derived:600";
}

fn install(m: *Model) void {
    model = m;
    atomic.ops.* = .{
        .flistxattr = mList,
        .fgetxattr = mGet,
        .fsetxattr = mSet,
        .fremovexattr = mRemove,
        .fchmod = mChmod,
        .created = mCreated,
    };
    installOverrides();
}

fn models() [4]Model {
    return .{
        .{ .label = "gpfs-native", .native = GPFS, .supported = .{ true, false, false } },
        .{ .label = "gpfs-native-with-generic-and-posix-views", .native = GPFS, .supported = .{ true, true, true }, .views = .{ null, "generic:", "posix-projection:" } },
        .{ .label = "nfs4-generic", .native = NFS4, .supported = .{ false, true, false } },
        .{ .label = "posix-access", .native = POSIX, .supported = .{ false, false, true }, .chmod_rewrites = false },
    };
}

fn eqlAttrs(x: Attrs, y: Attrs) bool {
    for (x, y) |p, q| {
        if ((p == null) != (q == null)) return false;
        if (p != null and !std.mem.eql(u8, p.?, q.?)) return false;
    }
    return true;
}

fn expectAttrs(want: Attrs, got: Attrs) !void {
    if (!eqlAttrs(want, got)) {
        std.debug.print("attributes differ\n", .{});
        return error.TestUnexpectedResult;
    }
}

fn allListed(a: Attrs) bool {
    return a[0] != null and a[1] != null and a[2] != null;
}

// ---- hook helpers ----------------------------------------------------------------

/// The target path a hook applies to; "" means the temporary file.
var target: []const u8 = "";
var hook_errno: linux.E = .SUCCESS;
var hook_count: usize = 0;
var hook_listed: Attrs = .{ null, null, null };
var hook_names: [3]bool = .{ false, false, false };

fn onTarget(fd: sys.fd_t) bool {
    const p = fdPath(fd);
    if (target.len == 0) return std.mem.endsWith(u8, p, ".new");
    return std.mem.eql(u8, p, target);
}

fn hFail(fd: sys.fd_t, _: ?usize) Out {
    return if (onTarget(fd)) .{ .fail = hook_errno } else .pass;
}

fn hEmptyList(fd: sys.fd_t, _: ?usize) Out {
    return if (onTarget(fd)) .{ .list = &.{} } else .pass;
}

fn hRichAcl(fd: sys.fd_t, _: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    var l: std.ArrayList([]const u8) = .empty;
    for (hook_listed, 0..) |v, i| if (v != null) l.append(A, names[i]) catch unreachable;
    l.append(A, "system.richacl") catch unreachable;
    return .{ .list = l.items };
}

/// getxattr fails with `hook_errno` for names not listed in `hook_listed`.
fn hUnlisted(fd: sys.fd_t, name: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    if (hook_listed[name.?] == null) return .{ .fail = hook_errno };
    return .pass;
}

/// getxattr fails with `hook_errno` for the names in `hook_names`.
fn hNames(fd: sys.fd_t, name: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    if (hook_names[name.?]) return .{ .fail = hook_errno };
    return .pass;
}

fn hChangeOnSecondList(fd: sys.fd_t, _: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    hook_count += 1;
    if (hook_count == 2) model.?.setPath(target, model.?.native, "other");
    return .pass;
}

fn hChmodSource(fd: sys.fd_t, _: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    chmod(target, 0o600);
    return .pass;
}

fn hRecomputeMode(fd: sys.fd_t, _: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    _ = linux.fchmod(fd, 0o600);
    return .pass;
}

// ---- the model scenario ------------------------------------------------------------

const Scenario = struct { dir: []const u8, path: []const u8, expected: Attrs };

fn scenario(m: *Model) Scenario {
    const dir = tmpdir();
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o640);
    install(m);
    m.setPath(path, m.native, &OPAQUE);
    return .{ .dir = dir, .path = path, .expected = m.getPath(path) };
}

fn assertUnchanged(m: *Model, s: Scenario) !void {
    try testing.expectEqualStrings("old", readFile(s.path));
    try expectAttrs(s.expected, m.getPath(s.path));
    try testing.expectEqual(@as(u32, 0o640), modeOf(s.path));
    try testing.expect(!exists(join(s.dir, ".module.lua.new")));
}

fn reset(m: *Model) void {
    m.hooks = .{};
    target = "";
}

fn tempKinds(m: *Model) []const Op {
    var out: std.ArrayList(Op) = .empty;
    for (m.calls.items) |c| if (std.mem.endsWith(u8, c.path, ".new")) out.append(A, c.op) catch unreachable;
    return out.items;
}

fn firstIndex(kinds: []const Op, op: Op) usize {
    for (kinds, 0..) |k, i| if (k == op) return i;
    return std.math.maxInt(usize);
}

// ---- test_acl_models ----------------------------------------------------------------

test "native bytes round trip through descriptors after chmod" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        const before = statOf(s.path);
        try write(s.path, "new", replace);
        const after = statOf(s.path);
        try testing.expectEqualStrings("new", readFile(s.path));
        try expectAttrs(s.expected, m.getPath(s.path));
        try testing.expectEqualSlices(u8, &OPAQUE, m.getPath(s.path)[m.native].?);
        try testing.expectEqual(before.uid, after.uid);
        try testing.expectEqual(before.gid, after.gid);
        try testing.expectEqual(@as(u32, 0o640), after.perm());
        const writes = m.opsOf(.set);
        try testing.expectEqual(@as(usize, 1), writes.len);
        try testing.expectEqual(m.native, writes[0].name.?);
        const kinds = tempKinds(&m);
        try testing.expect(firstIndex(kinds, .chmod) < firstIndex(kinds, .set));
    }
}

test "a projection is never written in place of the native ACL" {
    begin();
    defer end();
    var m = models()[1];
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    install(&m);
    m.setPath(path, GPFS, &OPAQUE);
    try write(path, "new", replace);
    const at = m.getPath(path);
    try testing.expectEqualSlices(u8, &OPAQUE, at[GPFS].?);
    try testing.expectEqualSlices(u8, "generic:" ++ OPAQUE, at[NFS4].?);
    try testing.expectEqualSlices(u8, "posix-projection:" ++ OPAQUE, at[POSIX].?);
    for (m.opsOf(.set)) |c| try testing.expect(c.name.? == GPFS);
}

test "a projection that disagrees with the native ACL is refused" {
    begin();
    defer end();
    var m = models()[1];
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    install(&m);
    m.setPath(path, GPFS, &OPAQUE);
    m.setPath(path, POSIX, "independent posix acl");
    const expected = m.getPath(path);
    try expectRefused(write(path, "new", replace), "did not round-trip");
    try testing.expectEqualStrings("old", readFile(path));
    try expectAttrs(expected, m.getPath(path));
}

test "a denied list is refused, not treated as absence" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        hook_errno = .ACCES;
        m.hooks.list = hFail;
        try expectRefused(write(s.path, "new", replace), "Permission denied");
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "an unsupported list is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        // ENOTSUP and EOPNOTSUPP are one value on Linux.
        target = s.path;
        hook_errno = .OPNOTSUPP;
        m.hooks.list = hFail;
        try expectRefused(write(s.path, "new", replace), null);
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "a denied read of a listed ACL is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        for ([_]linux.E{ .ACCES, .PERM, .IO }) |code| {
            target = s.path;
            hook_errno = code;
            m.hooks.get = hFail;
            try expectRefused(write(s.path, "new", replace), null);
            reset(&m);
            try assertUnchanged(&m, s);
        }
    }
}

test "a listed, then unreadable ACL is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        hook_errno = .NODATA;
        m.hooks.get = hFail;
        try expectRefused(write(s.path, "new", replace), "listed but is no longer readable");
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "a denied probe of an unlisted ACL name is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        hook_errno = .ACCES;
        hook_listed = s.expected;
        m.hooks.get = hUnlisted;
        if (allListed(s.expected)) {
            try write(s.path, "new", replace);
            try expectAttrs(s.expected, m.getPath(s.path));
            reset(&m);
            continue;
        }
        try expectRefused(write(s.path, "new", replace), null);
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "a readable virtual ACL is preserved when the listing is empty" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        const info = statOf(s.path);
        target = s.path;
        m.hooks.list = hEmptyList;
        try write(s.path, "new", replace);
        reset(&m);
        try testing.expectEqualStrings("new", readFile(s.path));
        try expectAttrs(s.expected, m.getPath(s.path));
        try testing.expectEqualSlices(u8, &OPAQUE, m.getPath(s.path)[m.native].?);
        const restored = statOf(s.path);
        try testing.expectEqual(info.uid, restored.uid);
        try testing.expectEqual(info.gid, restored.gid);
        try testing.expectEqual(@as(u32, 0o640), restored.perm());
        try testing.expect(!exists(join(s.dir, ".module.lua.new")));
    }
}

test "an unknown system attribute is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        hook_listed = s.expected;
        m.hooks.list = hRichAcl;
        try expectRefused(write(s.path, "new", replace), "unsupported access-control attribute system.richacl");
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "attributes changed during inspection are refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        hook_count = 0;
        m.hooks.list = hChangeOnSecondList;
        try expectRefused(write(s.path, "new", replace), "changed during inspection");
        reset(&m);
        m.setPath(s.path, m.native, &OPAQUE);
        try assertUnchanged(&m, s);
    }
}

test "an ownership or mode change during inspection is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        m.hooks.list = hChmodSource;
        try expectRefused(write(s.path, "new", replace), "changed during inspection");
        reset(&m);
        try testing.expectEqual(@as(u32, 0o600), modeOf(s.path));
        chmod(s.path, 0o640);
        try assertUnchanged(&m, s);
    }
}

var change_path: []const u8 = "";
var change_name: usize = 0;
var change_value: []const u8 = "";

fn changeSource() void {
    model.?.setPath(change_path, change_name, change_value);
}

test "a source ACL change before the rename is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        change_path = s.path;
        change_name = m.native;
        change_value = "changed";
        try expectRefused(write(s.path, "new", hooked("replace.fsync", changeSource)), "changed before");
        try testing.expect(!wasReached("replace.rename"));
        try testing.expectEqualStrings("old", readFile(s.path));
        try testing.expectEqualStrings("changed", m.getPath(s.path)[m.native].?);
        try testing.expect(!exists(join(s.dir, ".module.lua.new")));
    }
}

test "a denied ACL write is refused and leaves no temporary file" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        for ([_]linux.E{ .ACCES, .PERM, .OPNOTSUPP }) |code| {
            target = "";
            hook_errno = code;
            m.hooks.set = hFail;
            try expectRefused(write(s.path, "new", replace), "cannot preserve access metadata");
            reset(&m);
            try assertUnchanged(&m, s);
        }
    }
}

test "a written ACL that reads back differently is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        m.lossy = true;
        try expectRefused(write(s.path, "new", replace), "did not round-trip");
        m.lossy = false;
        try assertUnchanged(&m, s);
    }
}

test "a mode recomputed by ACL restoration is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = "";
        m.hooks.set = hRecomputeMode;
        try expectRefused(write(s.path, "new", replace), "ownership or mode did not round-trip");
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "an inherited ACL is removed when the source has none" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        const plain = join(s.dir, "plain.lua");
        writeFile(plain, "old");
        chmod(plain, 0o644);
        m.inherit = "inherited";
        try write(plain, "new", replace);
        try testing.expectEqualStrings("new", readFile(plain));
        try expectAttrs(.{ null, null, null }, m.getPath(plain));
        try testing.expectEqual(@as(u32, 0o644), modeOf(plain));
        var removed = false;
        for (m.opsOf(.remove)) |c| if (c.name.? == m.native) {
            removed = true;
        };
        try testing.expect(removed);
    }
}

test "a denied removal of an inherited ACL is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        const plain = join(s.dir, "plain.lua");
        writeFile(plain, "old");
        m.inherit = "inherited";
        target = "";
        hook_errno = .PERM;
        m.hooks.remove = hFail;
        try expectRefused(write(plain, "new", replace), "cannot preserve access metadata");
        try testing.expectEqualStrings("old", readFile(plain));
        try expectAttrs(.{ null, null, null }, m.getPath(plain));
        try testing.expect(!exists(join(s.dir, ".plain.lua.new")));
    }
}

test "a symlink is still refused before inspection" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        const link = join(s.dir, "link.lua");
        _ = linux.symlinkat(z(s.path).ptr, linux.AT.FDCWD, z(link).ptr);
        m.calls = .empty;
        try expectRefused(write(link, "new", replace), "symlink");
        try testing.expect((fsx.statAt(fsx.cwd, link, false) catch unreachable).isLink());
        try testing.expectEqual(@as(usize, 0), m.calls.items.len);
        try assertUnchanged(&m, s);
    }
}

test "a symlinked metadata source is refused" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        const link = join(s.dir, "policy.lua");
        _ = linux.symlinkat(z(s.path).ptr, linux.AT.FDCWD, z(link).ptr);
        const out = join(s.dir, "target.lua");
        try expectRefused(write(out, "new", .{ .step = "replace", .metadata_from = link }), "cannot read access metadata");
        try testing.expect(!exists(out));
        try assertUnchanged(&m, s);
    }
}

// ---- test_acl_probe_compatibility -------------------------------------------------

fn posixOnly(label: []const u8) Model {
    return .{ .label = label, .native = POSIX, .supported = .{ false, false, true }, .chmod_rewrites = false };
}

fn nfs4Only(label: []const u8) Model {
    return .{ .label = label, .native = NFS4, .supported = .{ false, true, false } };
}

fn gpfsOnly(label: []const u8) Model {
    return .{ .label = label, .native = GPFS, .supported = .{ true, false, false } };
}

test "an unlisted EINVAL probe is treated as not provided when POSIX is listed" {
    begin();
    defer end();
    var m = posixOnly("posix-access-einval-foreign");
    const s = scenario(&m);
    defer cleanup(s.dir);
    target = s.path;
    hook_errno = .INVAL;
    hook_listed = s.expected;
    m.hooks.get = hUnlisted;
    try write(s.path, "new", replace);
    reset(&m);
    try testing.expectEqualStrings("new", readFile(s.path));
    try expectAttrs(s.expected, m.getPath(s.path));
    try testing.expectEqual(@as(u32, 0o640), modeOf(s.path));
}

test "a listed EINVAL read is refused, not treated as absent" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        target = s.path;
        hook_errno = .INVAL;
        m.hooks.get = hFail;
        try expectRefused(write(s.path, "new", replace), null);
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

test "an unlisted EINVAL does not weaken EACCES or EPERM probes" {
    begin();
    defer end();
    for (models()) |m0| {
        var m = m0;
        const s = scenario(&m);
        defer cleanup(s.dir);
        if (allListed(s.expected)) continue;
        for ([_]linux.E{ .ACCES, .PERM }) |code| {
            target = s.path;
            hook_errno = code;
            hook_listed = s.expected;
            m.hooks.get = hUnlisted;
            try expectRefused(write(s.path, "new", replace), null);
            reset(&m);
            try assertUnchanged(&m, s);
        }
    }
}

test "an unlisted NFSv4-family EINVAL with a listed POSIX ACL keeps the POSIX bytes" {
    begin();
    defer end();
    var m = posixOnly("posix-only");
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o640);
    install(&m);
    const posix_bytes = OPAQUE ++ "|posix-retained";
    m.setPath(path, POSIX, posix_bytes);
    try expectAttrs(.{ null, null, posix_bytes }, m.getPath(path));
    target = path;
    hook_errno = .INVAL;
    hook_names = .{ true, true, false };
    m.hooks.get = hNames;
    try write(path, "new", replace);
    reset(&m);
    try testing.expectEqualStrings("new", readFile(path));
    try expectAttrs(.{ null, null, posix_bytes }, m.getPath(path));
    try testing.expectEqual(@as(u32, 0o640), modeOf(path));
}

test "an unlisted POSIX EINVAL without a positive model is refused" {
    begin();
    defer end();
    var m = nfs4Only("nfs4-only");
    const s = scenario(&m);
    defer cleanup(s.dir);
    target = s.path;
    hook_errno = .INVAL;
    hook_names = .{ false, false, true };
    m.hooks.get = hNames;
    try expectRefused(write(s.path, "new", replace), null);
    reset(&m);
    try assertUnchanged(&m, s);
}

test "an unlisted NFSv4 EINVAL without a listed POSIX ACL is refused" {
    begin();
    defer end();
    var m = nfs4Only("nfs4-only-no-posix");
    const s = scenario(&m);
    defer cleanup(s.dir);
    target = s.path;
    hook_errno = .INVAL;
    hook_names = .{ true, false, true };
    m.hooks.get = hNames;
    try expectRefused(write(s.path, "new", replace), null);
    reset(&m);
    try assertUnchanged(&m, s);
}

test "a listed NFSv4 EINVAL is refused" {
    begin();
    defer end();
    var m = nfs4Only("nfs4-generic-listed");
    const s = scenario(&m);
    defer cleanup(s.dir);
    target = s.path;
    hook_errno = .INVAL;
    m.hooks.get = hFail;
    try expectRefused(write(s.path, "new", replace), null);
    reset(&m);
    try assertUnchanged(&m, s);
}

test "a listed GPFS EINVAL is refused" {
    begin();
    defer end();
    var m = gpfsOnly("gpfs-native-listed");
    const s = scenario(&m);
    defer cleanup(s.dir);
    target = s.path;
    hook_errno = .INVAL;
    m.hooks.get = hFail;
    try expectRefused(write(s.path, "new", replace), null);
    reset(&m);
    try assertUnchanged(&m, s);
}

test "the narrow EINVAL guard still refuses a denied NFSv4 probe" {
    begin();
    defer end();
    var m = posixOnly("posix-only-denied-nfs4");
    const s = scenario(&m);
    defer cleanup(s.dir);
    for ([_]linux.E{ .ACCES, .PERM }) |code| {
        target = s.path;
        hook_errno = code;
        hook_names = .{ true, true, false };
        m.hooks.get = hNames;
        try expectRefused(write(s.path, "new", replace), null);
        reset(&m);
        try assertUnchanged(&m, s);
    }
}

fn hChangePosixOnSecondList(fd: sys.fd_t, _: ?usize) Out {
    if (!onTarget(fd)) return .pass;
    hook_count += 1;
    if (hook_count == 2) model.?.setPath(target, POSIX, "other-posix");
    return .pass;
}

test "the narrow EINVAL guard still refuses changing metadata" {
    begin();
    defer end();
    var m = posixOnly("posix-only-changing");
    const s = scenario(&m);
    defer cleanup(s.dir);
    target = s.path;
    hook_count = 0;
    hook_errno = .INVAL;
    hook_names = .{ true, true, false };
    m.hooks.list = hChangePosixOnSecondList;
    m.hooks.get = hNames;
    try expectRefused(write(s.path, "new", replace), "changed during inspection");
    reset(&m);
    m.setPath(s.path, POSIX, &OPAQUE);
    try assertUnchanged(&m, s);
}

// ---- test_virtual_acl_restore ------------------------------------------------------

fn virtualModel(replace_virtual: bool) Model {
    return .{ .label = "virtual-nfs4-with-posix-access", .native = POSIX, .supported = .{ false, true, true }, .chmod_rewrites = false, .virtual = true, .replace_virtual = replace_virtual };
}

test "a required POSIX ACL replaces an unremovable virtual view" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o640);
    const before = statOf(path);
    var m = virtualModel(true);
    install(&m);
    m.setPath(path, POSIX, &OPAQUE);
    const expected = m.getPath(path);
    try write(path, "new", replace);
    try testing.expectEqualStrings("new", readFile(path));
    try expectAttrs(expected, m.getPath(path));
    try expectAttrs(.{ null, null, &OPAQUE }, m.getPath(path));
    const after = statOf(path);
    try testing.expectEqual(before.uid, after.uid);
    try testing.expectEqual(@as(u32, 0o640), after.perm());
    const writes = m.opsOf(.set);
    try testing.expectEqual(@as(usize, 1), writes.len);
    try testing.expectEqual(POSIX, writes[0].name.?);
    try testing.expectEqual(@as(usize, 0), m.opsOf(.remove).len);
    const kinds = tempKinds(&m);
    try testing.expect(firstIndex(kinds, .chmod) < firstIndex(kinds, .set));
    try testing.expect(!exists(join(dir, ".module.lua.new")));
}

fn noop() void {}

test "a virtual view that survives the required ACL is refused" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o640);
    var m = virtualModel(false);
    install(&m);
    m.setPath(path, POSIX, &OPAQUE);
    const expected = m.getPath(path);
    try expectRefused(write(path, "new", hooked("", noop)), "cannot preserve access metadata");
    try testing.expectEqualStrings("old", readFile(path));
    try expectAttrs(expected, m.getPath(path));
    try testing.expectEqual(@as(u32, 0o640), modeOf(path));
    const kinds = tempKinds(&m);
    try testing.expect(firstIndex(kinds, .set) < firstIndex(kinds, .remove));
    try testing.expect(!wasReached("replace.rename"));
    try testing.expect(!exists(join(dir, ".module.lua.new")));
}

test "an absent source ACL does not accept an unremovable virtual view" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o640);
    var m = virtualModel(true);
    install(&m);
    try expectAttrs(.{ null, null, null }, m.getPath(path));
    try expectRefused(write(path, "new", replace), "cannot preserve access metadata");
    try testing.expectEqualStrings("old", readFile(path));
    try expectAttrs(.{ null, null, null }, m.getPath(path));
    try testing.expectEqual(@as(u32, 0o640), modeOf(path));
    try testing.expect(m.opsOf(.remove).len > 0);
    try testing.expect(!exists(join(dir, ".module.lua.new")));
}

// ---- POSIX ACLs through the kernel ----------------------------------------------------

const USER_OBJ: u16 = 0x01;
const USER: u16 = 0x02;
const GROUP_OBJ: u16 = 0x04;
const MASK: u16 = 0x10;
const OTHER: u16 = 0x20;
const UNDEFINED: u32 = 0xffffffff;

/// A POSIX access ACL in the kernel's xattr form: version 2, then
/// (tag, perm, id) entries, little-endian.
fn acl(user_obj: u16, named: u16, group_obj: u16, mask: u16, other: u16) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn u16le(o: *std.ArrayList(u8), v: u16) void {
            o.appendSlice(A, &std.mem.toBytes(std.mem.nativeToLittle(u16, v))) catch unreachable;
        }
        fn u32le(o: *std.ArrayList(u8), v: u32) void {
            o.appendSlice(A, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch unreachable;
        }
    };
    w.u32le(&out, 2);
    const entries = [_][3]u32{ .{ USER_OBJ, user_obj, UNDEFINED }, .{ USER, named, 65534 }, .{ GROUP_OBJ, group_obj, UNDEFINED }, .{ MASK, mask, UNDEFINED }, .{ OTHER, other, UNDEFINED } };
    for (entries) |e| {
        w.u16le(&out, @intCast(e[0]));
        w.u16le(&out, @intCast(e[1]));
        w.u32le(&out, e[2]);
    }
    return out.items;
}

fn setPathXattr(path: []const u8, name: []const u8, value: []const u8) bool {
    return linux.errno(linux.setxattr(z(path).ptr, z(name).ptr, value.ptr, value.len, 0)) == .SUCCESS;
}

fn getPathXattr(path: []const u8, name: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const rc = linux.getxattr(z(path).ptr, z(name).ptr, &buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    return A.dupe(u8, buf[0..rc]) catch unreachable;
}

fn getPathErrno(path: []const u8, name: []const u8) linux.E {
    var buf: [4096]u8 = undefined;
    return linux.errno(linux.getxattr(z(path).ptr, z(name).ptr, &buf, buf.len));
}

fn spy() Model {
    return .{ .label = "kernel", .native = POSIX, .supported = .{ false, false, true }, .chmod_rewrites = false, .kernel = true };
}

const Posix = struct { dir: []const u8, path: []const u8, stored: []const u8 };

/// A module file with a POSIX access ACL, or null where the file system
/// has no POSIX ACLs (the test is then skipped).
fn posixModule(value: []const u8, mode: u32) ?Posix {
    const dir = tmpdir();
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, mode);
    if (!setPathXattr(path, names[POSIX], value)) {
        cleanup(dir);
        return null;
    }
    return .{ .dir = dir, .path = path, .stored = getPathXattr(path, names[POSIX]).? };
}

test "a mask wider than the group owner round-trips with its mode" {
    begin();
    defer end();
    const p = posixModule(acl(6, 6, 4, 6, 0), 0o660) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    try testing.expectEqual(@as(u32, 0o660), modeOf(p.path));
    try write(p.path, "new", replace);
    try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
    try testing.expectEqual(@as(u32, 0o660), modeOf(p.path));
}

test "a mask narrower than the group owner round-trips with its mode" {
    begin();
    defer end();
    const p = posixModule(acl(6, 6, 6, 4, 4), 0o644) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    try testing.expectEqual(@as(u32, 0o644), modeOf(p.path));
    try write(p.path, "new", replace);
    try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
    try testing.expectEqual(@as(u32, 0o644), modeOf(p.path));
}

test "a requested mode that contradicts the mask is refused" {
    begin();
    defer end();
    const p = posixModule(acl(6, 6, 4, 6, 0), 0o660) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    try expectRefused(write(p.path, "new", .{ .step = "replace", .mode = 0o600 }), "ownership or mode did not round-trip");
    try testing.expectEqualStrings("old", readFile(p.path));
    try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
    try testing.expectEqual(@as(u32, 0o660), modeOf(p.path));
}

test "the ACL is written through the descriptor after ownership and mode" {
    begin();
    defer end();
    const p = posixModule(acl(6, 4, 4, 4, 0), 0o640) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    var m = spy();
    install(&m);
    try write(p.path, "new", replace);
    const kinds = tempKinds(&m);
    try testing.expect(firstIndex(kinds, .chown) < firstIndex(kinds, .chmod));
    try testing.expect(firstIndex(kinds, .chmod) < firstIndex(kinds, .set));
    var listed_source = false;
    for (m.calls.items) |c| if (c.op == .list and std.mem.eql(u8, c.path, p.path)) {
        listed_source = true;
    };
    try testing.expect(listed_source);
    try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
}

fn hRemoveOnRead(fd: sys.fd_t, name: ?usize) Out {
    if (onTarget(fd) and name.? == POSIX) _ = linux.removexattr(z(target).ptr, names[POSIX].ptr);
    return .pass;
}

test "an ACL removed between list and read is refused" {
    begin();
    defer end();
    const p = posixModule(acl(6, 4, 4, 4, 0), 0o640) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    var m = spy();
    install(&m);
    target = p.path;
    m.hooks.get = hRemoveOnRead;
    try expectRefused(write(p.path, "new", replace), "listed but is no longer readable");
    try testing.expectEqualStrings("old", readFile(p.path));
    try testing.expect(!exists(join(p.dir, ".module.lua.new")));
}

var replacement_acl: []const u8 = "";

fn hReplaceOnSecondRead(fd: sys.fd_t, name: ?usize) Out {
    if (onTarget(fd) and name.? == POSIX) {
        hook_count += 1;
        if (hook_count == 2) _ = setPathXattr(target, names[POSIX], replacement_acl);
    }
    return .pass;
}

test "an ACL replaced between reads is refused" {
    begin();
    defer end();
    const p = posixModule(acl(6, 4, 4, 4, 0), 0o640) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    var m = spy();
    install(&m);
    target = p.path;
    hook_count = 0;
    replacement_acl = acl(6, 0, 4, 4, 0);
    m.hooks.get = hReplaceOnSecondRead;
    try expectRefused(write(p.path, "new", replace), "changed during inspection");
    try testing.expectEqualStrings("old", readFile(p.path));
}

fn setReplacementOnPath() void {
    _ = setPathXattr(change_path, names[POSIX], replacement_acl);
}

test "an ACL changed before the rename is refused" {
    begin();
    defer end();
    const p = posixModule(acl(6, 4, 4, 4, 0), 0o640) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    change_path = p.path;
    replacement_acl = acl(6, 6, 4, 6, 0);
    try expectRefused(write(p.path, "new", hooked("replace.fsync", setReplacementOnPath)), "changed before");
    try testing.expectEqualStrings("old", readFile(p.path));
    try testing.expect(!std.mem.eql(u8, p.stored, getPathXattr(p.path, names[POSIX]).?));
    try testing.expectEqual(@as(u32, 0o660), modeOf(p.path));
    try testing.expect(!exists(join(p.dir, ".module.lua.new")));
}

fn hFailAny(_: sys.fd_t, _: ?usize) Out {
    return .{ .fail = hook_errno };
}

test "denied descriptor operations are refused" {
    begin();
    defer end();
    const cases = [_]struct { op: Op, code: linux.E }{
        .{ .op = .list, .code = .ACCES }, .{ .op = .list, .code = .OPNOTSUPP },
        .{ .op = .get, .code = .ACCES },  .{ .op = .get, .code = .PERM },
        .{ .op = .set, .code = .ACCES },  .{ .op = .set, .code = .PERM },
        .{ .op = .chmod, .code = .PERM },
    };
    for (cases) |c| {
        const p = posixModule(acl(6, 4, 4, 4, 0), 0o640) orelse return error.SkipZigTest;
        defer cleanup(p.dir);
        var m = spy();
        install(&m);
        hook_errno = c.code;
        switch (c.op) {
            .list => m.hooks.list = hFailAny,
            .get => m.hooks.get = hFailAny,
            .set => m.hooks.set = hFailAny,
            .chmod => m.hooks.chmod = hFailAny,
            else => unreachable,
        }
        try expectRefused(write(p.path, "new", replace), null);
        atomic.ops.* = .{};
        try testing.expectEqualStrings("old", readFile(p.path));
        try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
        try testing.expectEqual(@as(u32, 0o640), modeOf(p.path));
        try testing.expect(!exists(join(p.dir, ".module.lua.new")));
    }
}

test "an inherited default ACL that cannot be removed is refused" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    if (!setPathXattr(dir, posix_default, acl(6, 4, 4, 4, 0))) return error.SkipZigTest;
    var m = spy();
    install(&m);
    hook_errno = .PERM;
    m.hooks.remove = hFailAny;
    try expectRefused(write(path, "new", replace), "cannot preserve access metadata");
    atomic.ops.* = .{};
    try testing.expectEqualStrings("old", readFile(path));
    try testing.expectEqual(linux.E.NODATA, getPathErrno(path, names[POSIX]));
    try testing.expect(!exists(join(dir, ".module.lua.new")));
}

// ---- test_atomic_metadata -------------------------------------------------------------

fn accessAcl() []const u8 {
    return acl(6, 4, 4, 4, 0);
}

test "a replacement keeps owner, group, mode and the access ACL" {
    begin();
    defer end();
    const p = posixModule(accessAcl(), 0o644) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    const before = statOf(p.path);
    try write(p.path, "new", replace);
    const after = statOf(p.path);
    try testing.expectEqualStrings("new", readFile(p.path));
    try testing.expectEqual(before.uid, after.uid);
    try testing.expectEqual(before.gid, after.gid);
    try testing.expectEqual(before.perm(), after.perm());
    try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
}

test "a replacement does not gain the parent's default ACL" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    if (!setPathXattr(dir, posix_default, accessAcl())) return error.SkipZigTest;
    try write(path, "new", replace);
    try testing.expectEqual(linux.E.NODATA, getPathErrno(path, names[POSIX]));
    try testing.expectEqualStrings("new", readFile(path));
}

test "an ACL copy failure keeps the live bytes" {
    begin();
    defer end();
    const p = posixModule(accessAcl(), 0o644) orelse return error.SkipZigTest;
    defer cleanup(p.dir);
    var m = spy();
    install(&m);
    hook_errno = .PERM;
    m.hooks.set = hFailAny;
    try expectRefused(write(p.path, "new", replace), null);
    atomic.ops.* = .{};
    try testing.expectEqualStrings("old", readFile(p.path));
    try testing.expectEqualSlices(u8, p.stored, getPathXattr(p.path, names[POSIX]).?);
}

test "a denied fchown reads as Python's EPERM text" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    installOverrides();
    over.fchown = .PERM;
    try expectRefused(write(path, "new", replace), "[Errno 1] Operation not permitted");
    over.fchown = .ACCES;
    try expectRefused(write(path, "new", replace), "[Errno 13] Permission denied");
}

test "an ownership copy failure keeps the live bytes" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    installOverrides();
    over.fchown = .PERM;
    try expectRefused(write(path, "new", replace), null);
    try testing.expectEqualStrings("old", readFile(path));
}

test "a resume replaces an owned read-only temporary file" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o444);
    try crashAt(path, "partial", "replace.rename");
    try testing.expectEqualStrings("old", readFile(path));
    try testing.expect(exists(join(dir, ".module.lua.new")));
    try write(path, "new", replace);
    try testing.expectEqualStrings("new", readFile(path));
    try testing.expectEqual(@as(u32, 0o444), modeOf(path));
}

fn linkFile(old: []const u8, new: []const u8) void {
    _ = linux.linkat(linux.AT.FDCWD, z(old).ptr, linux.AT.FDCWD, z(new).ptr, 0);
}

test "a hard-linked temporary file cannot modify another file" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "module.lua");
    const outside = join(dir, "outside");
    writeFile(path, "old");
    writeFile(outside, "protected");
    linkFile(outside, join(dir, ".module.lua.new"));
    try expectRefused(write(path, "new", replace), null);
    try testing.expectEqualStrings("old", readFile(path));
    try testing.expectEqualStrings("protected", readFile(outside));
}

// ---- test_stale_temporary ----------------------------------------------------------------

fn staleModule(dir: []const u8) [2][]const u8 {
    const path = join(dir, "module.lua");
    writeFile(path, "old");
    chmod(path, 0o640);
    return .{ path, join(dir, ".module.lua.new") };
}

fn otherEuid() linux.uid_t {
    return linux.getuid() + 4242;
}

test "a metadata refusal removes its temporary file" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const pt = staleModule(dir);
    installOverrides();
    over.fchown = .PERM;
    try expectRefused(write(pt[0], "new", replace), null);
    try testing.expect(!exists(pt[1]));
    try testing.expectEqualStrings("old", readFile(pt[0]));
    over = .{};
    try write(pt[0], "new", replace);
    try testing.expectEqualStrings("new", readFile(pt[0]));
}

test "an fsync error removes its temporary file" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const pt = staleModule(dir);
    installOverrides();
    over.fsync = .IO;
    if (write(pt[0], "new", replace)) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expect(!exists(pt[1]));
    try testing.expectEqualStrings("old", readFile(pt[0]));
}

var swap_dir: []const u8 = "";

fn swapTemporary(_: sys.fd_t) void {
    const tmp = join(swap_dir, ".module.lua.new");
    sys.renameat(fsx.cwd, tmp, fsx.cwd, join(swap_dir, "kept")) catch unreachable;
    writeFile(tmp, "someone else");
}

test "a temporary file replaced by another writer is not removed" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const pt = staleModule(dir);
    swap_dir = dir;
    installOverrides();
    over.fsync_action = swapTemporary;
    over.fsync = .IO;
    if (write(pt[0], "new", replace)) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectEqualStrings("someone else", readFile(pt[1]));
    try testing.expectEqualStrings("old", readFile(pt[0]));
}

test "a privileged resume accepts a temporary owned by the module owner" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const pt = staleModule(dir);
    installOverrides();
    over.euid = otherEuid();
    try crashAt(pt[0], "partial", "replace.rename");
    try testing.expectEqual(statOf(pt[0]).uid, statOf(pt[1]).uid);
    try write(pt[0], "new", replace);
    try testing.expectEqualStrings("new", readFile(pt[0]));
    try testing.expectEqual(@as(u32, 0o640), modeOf(pt[0]));
    try testing.expect(!exists(pt[1]));
}

test "a privileged write refuses a foreign temporary without a metadata owner" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const path = join(dir, "new.lua");
    const tmp = join(dir, ".new.lua.new");
    writeFile(tmp, "foreign");
    installOverrides();
    over.euid = otherEuid();
    try expectRefused(write(path, "new", replace), "owned regular file");
    try testing.expectEqualStrings("foreign", readFile(tmp));
    try testing.expect(!exists(path));
}

test "a privileged write still refuses a hard-linked temporary" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const pt = staleModule(dir);
    const outside = join(dir, "outside");
    writeFile(outside, "protected");
    linkFile(outside, pt[1]);
    installOverrides();
    over.euid = otherEuid();
    try expectRefused(write(pt[0], "new", replace), "owned regular file");
    try testing.expectEqualStrings("protected", readFile(outside));
    try testing.expectEqualStrings("old", readFile(pt[0]));
}

test "a privileged write refuses a temporary directory" {
    begin();
    defer end();
    const dir = tmpdir();
    defer cleanup(dir);
    const pt = staleModule(dir);
    atomic.makedirs(pt[1]) catch unreachable;
    installOverrides();
    over.euid = otherEuid();
    try expectRefused(write(pt[0], "new", replace), "owned regular file");
    try testing.expect(isDir(pt[1]));
    try testing.expectEqualStrings("old", readFile(pt[0]));
}
