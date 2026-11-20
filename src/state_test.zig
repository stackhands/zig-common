//! Tests of RootLock, ported from the Python tool's test_cluster_lock: the
//! flock gate and the POSIX record lock on its sidecar. A failing system
//! call is injected through `state.lock_ops`; another process is a forked
//! child.
const std = @import("std");
const linux = std.os.linux;
const state = @import("state.zig");
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");
const atomic = @import("atomic.zig");
const testing = std.testing;
const RootLock = state.RootLock;

var arena_state: std.heap.ArenaAllocator = undefined;
var A: std.mem.Allocator = undefined;
var counter: usize = 0;

fn begin() []const u8 {
    arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    A = arena_state.allocator();
    state.lock_ops.* = .{};
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = fsx.realpath(fsx.cwd, ".", &cwd_buf) catch unreachable;
    counter += 1;
    const root = A.print("{s}/.zig-cache/lock-test-{d}-{d}", .{ cwd, linux.getpid(), counter }) catch unreachable;
    atomic.makedirs(root) catch unreachable;
    return root;
}

fn end(root: []const u8) void {
    state.lock_ops.* = .{};
    fsx.deleteTree(A, fsx.cwd, root) catch {};
    arena_state.deinit();
}

fn err(e: linux.E) usize {
    return @bitCast(-@as(isize, @backingInt(e)));
}

fn fdCount(gpa: std.mem.Allocator) usize {
    const fd = fsx.openDir(fsx.cwd, "/proc/self/fd", true) catch unreachable;
    defer sys.close(fd);
    var it = fsx.DirIter.init(gpa, fd) catch unreachable;
    defer it.deinit(gpa);
    var n: usize = 0;
    while (it.next() catch null) |_| n += 1;
    return n - 1; // the directory's own descriptor
}

fn waitExit(pid: isize) u32 {
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), @ptrCast(&status), 0, null);
    if (!linux.W.IFEXITED(status)) return 255;
    return linux.W.EXITSTATUS(status);
}

fn noFlock(_: fsx.fd_t, _: i32) usize {
    return 0;
}

/// Another process whose flock is a no-op, as on a node whose kernel gate
/// is not shared, must still be excluded by the record lock.
fn assertRemoteExcluded(root: []const u8) !void {
    const pid: isize = @bitCast(linux.fork());
    if (pid == 0) {
        state.lock_ops.flock = noFlock;
        if (RootLock.acquire(A, root, 0)) |l| {
            l.release();
            linux.exit_group(1);
        } else |e| linux.exit_group(if (e == error.Busy) 0 else 2);
    }
    try testing.expectEqual(@as(u32, 0), waitExit(pid));
}

/// The gate itself is held: a new descriptor cannot flock it.
fn assertGateHeld(root: []const u8) !void {
    const fd = try sys.openat(fsx.cwd, try A.print("{s}/.lock", .{root}), .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(fd);
    const rc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    try testing.expectEqual(linux.E.AGAIN, linux.errno(rc));
}

fn acquireAndRelease(root: []const u8) !void {
    const l = try RootLock.acquire(A, root, 0);
    l.release();
}

test "the record lock excludes an independent kernel gate" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    assertRemoteExcluded(root) catch |e| {
        holder.release();
        return e;
    };
    holder.release();
    try acquireAndRelease(root);
}

test "failed local contenders keep the record lock" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    defer holder.release();
    for (0..4) |_| {
        try testing.expectError(error.Busy, RootLock.acquire(A, root, 0));
        try testing.expect(state.osFailure() == null);
    }
    try assertRemoteExcluded(root);
}

var eintr_left: u8 = 0;

fn eintrFlock(fd: fsx.fd_t, op: i32) usize {
    if (eintr_left > 0 and (op & std.posix.LOCK.NB) != 0) {
        eintr_left -= 1;
        return err(.INTR);
    }
    return linux.flock(fd, op);
}

test "an interrupted non-blocking flock is retried" {
    const root = begin();
    defer end(root);
    eintr_left = 1;
    state.lock_ops.flock = eintrFlock;
    const held = try RootLock.acquire(A, root, 0);
    held.release();
    try testing.expectEqual(@as(u8, 0), eintr_left);

    eintr_left = 1;
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    const fd = (try state.openPrivate(dir, "extra", true)).?;
    defer sys.close(fd);
    try state.lockExclusive(fd, 0);
    _ = linux.flock(fd, std.posix.LOCK.UN);
    try testing.expectEqual(@as(u8, 0), eintr_left);
}

test "a second acquire by the holder keeps both locks" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    defer holder.release();
    try testing.expectError(error.Busy, RootLock.acquire(A, root, 0));
    try assertGateHeld(root);
    try assertRemoteExcluded(root);
}

var fail_target: enum { flock, fcntl, ftruncate, write, open_sidecar } = .flock;

fn eioFlock(_: fsx.fd_t, _: i32) usize {
    return err(.IO);
}
fn eioFcntl(_: fsx.fd_t, _: i32, _: usize) usize {
    return err(.IO);
}
fn eioFtruncate(_: fsx.fd_t, _: i64) usize {
    return err(.IO);
}
fn eioWrite(_: fsx.fd_t, _: []const u8) usize {
    return err(.IO);
}
fn eioOpen(_: fsx.fd_t, _: [*:0]const u8) usize {
    return err(.IO);
}

test "acquisition errors release the descriptors and the gate" {
    const root = begin();
    defer end(root);
    inline for (.{ "flock", "fcntl", "ftruncate", "write" }) |target| {
        const before = fdCount(A);
        if (comptime std.mem.eql(u8, target, "flock")) state.lock_ops.flock = eioFlock;
        if (comptime std.mem.eql(u8, target, "fcntl")) state.lock_ops.fcntl = eioFcntl;
        if (comptime std.mem.eql(u8, target, "ftruncate")) state.lock_ops.ftruncate = eioFtruncate;
        if (comptime std.mem.eql(u8, target, "write")) state.lock_ops.write = eioWrite;
        if (RootLock.acquire(A, root, null)) |l| {
            l.release();
            return error.TestUnexpectedResult;
        } else |_| {}
        const failure = state.osFailure() orelse unreachable;
        try testing.expectEqualStrings("", failure.path);
        try testing.expectEqualStrings("[Errno 5] Input/output error", failure.text);
        state.lock_ops.* = .{};
        try testing.expectEqual(before, fdCount(A));
        try acquireAndRelease(root);
    }
}

test "a sidecar open failure releases the local gate" {
    const root = begin();
    defer end(root);
    state.lock_ops.open_sidecar = eioOpen;
    try testing.expectError(error.Unexpected, RootLock.acquire(A, root, 0));
    const failure = state.osFailure() orelse unreachable;
    try testing.expectEqualStrings(try A.print("{s}/.lock.posix", .{root}), failure.path);
    try testing.expectEqualStrings("[Errno 5] Input/output error", failure.text);
    state.lock_ops.* = .{};
    try acquireAndRelease(root);
}

fn oPathOpen(dir: fsx.fd_t, name: [*:0]const u8) usize {
    return linux.openat(dir, name, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
}

test "an fchmod failure carries no filename" {
    const root = begin();
    defer end(root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try createFile(dir, ".lock.posix", "");
    state.lock_ops.open_sidecar = oPathOpen;
    try testing.expectError(error.InvalidArgument, RootLock.acquire(A, root, 0));
    const failure = state.osFailure() orelse unreachable;
    try testing.expectEqualStrings("", failure.path);
    try testing.expectEqualStrings("[Errno 9] Bad file descriptor", failure.text);
}

test "a forked child's release does not unlock the parent" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    defer holder.release();
    const pid: isize = @bitCast(linux.fork());
    if (pid == 0) {
        holder.release();
        linux.exit_group(0);
    }
    try testing.expectEqual(@as(u32, 0), waitExit(pid));
    try testing.expectError(error.Busy, RootLock.acquire(A, root, 0));
    try assertGateHeld(root);
    try assertRemoteExcluded(root);
}

test "a release error still closes both layers" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    const before = fdCount(A);
    state.lock_ops.fcntl = eioFcntl;
    holder.release();
    state.lock_ops.* = .{};
    try testing.expectEqual(before - 2, fdCount(A));
    try acquireAndRelease(root);
}

test "a hard-linked sidecar is refused" {
    const root = begin();
    defer end(root);
    const sidecar = try A.print("{s}/.lock.posix", .{root});
    const fd = try sys.openat(fsx.cwd, sidecar, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys.close(fd);
    var za: [sys.path_max:0]u8 = undefined;
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.linkat(linux.AT.FDCWD, (try sys.z(&za, sidecar)).ptr, linux.AT.FDCWD, (try sys.z(&zb, try A.print("{s}/sidecar-alias", .{root}))).ptr, 0);
    try testing.expectError(error.NotPrivate, RootLock.acquire(A, root, 0));
    try testing.expect(state.osFailure() == null);
}

test "a timed acquire does not wait forever" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    defer holder.release();
    var t0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t0);
    try testing.expectError(error.Busy, RootLock.acquire(A, root, 200));
    var t1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t1);
    const ms = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);
    try testing.expect(ms >= 150 and ms < 5000);
}

// ---- files planted at the lock names ---------------------------------------

/// A fresh state root under .zig-cache; `removeRoot` deletes and frees it.
fn scratchRoot(gpa: std.mem.Allocator) ![]u8 {
    state.lock_ops.* = .{};
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    counter += 1;
    const root = try gpa.print("{s}/.zig-cache/lock-test-{d}-{d}", .{ cwd, linux.getpid(), counter });
    errdefer gpa.free(root);
    try atomic.makedirs(root);
    return root;
}

fn removeRoot(gpa: std.mem.Allocator, root: []u8) void {
    state.lock_ops.* = .{};
    fsx.deleteTree(gpa, fsx.cwd, root) catch {};
    gpa.free(root);
}

fn createFile(dir: fsx.fd_t, name: []const u8, bytes: []const u8) !void {
    const fd = try sys.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    defer sys.close(fd);
    try sys.writeAll(fd, bytes);
}

fn expectContents(gpa: std.mem.Allocator, dir: fsx.fd_t, name: []const u8, want: []const u8) !void {
    const f = try fsx.openRegular(dir, name, false);
    defer sys.close(f.fd);
    const got = try fsx.readAll(gpa, f.fd, 4096);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The opens of one file from `init` on, as inotify reports them.
const OpenWatch = struct {
    fd: fsx.fd_t,

    fn init(gpa: std.mem.Allocator, root: []const u8, name: []const u8) !OpenWatch {
        const path = try gpa.print("{s}/{s}", .{ root, name });
        defer gpa.free(path);
        var zb: [sys.path_max:0]u8 = undefined;
        const fd: fsx.fd_t = @intCast(try sys.call(linux.inotify_init1, .{@as(u32, linux.IN.NONBLOCK | linux.IN.CLOEXEC)}));
        errdefer sys.close(fd);
        _ = try sys.call(linux.inotify_add_watch, .{ fd, (try sys.z(&zb, path)).ptr, @as(u32, linux.IN.OPEN) });
        return .{ .fd = fd };
    }

    fn deinit(w: OpenWatch) void {
        sys.close(w.fd);
    }

    fn opened(w: OpenWatch) bool {
        var buf: [256]u8 align(@alignOf(linux.inotify_event)) = undefined;
        return linux.errno(linux.read(w.fd, &buf, buf.len)) == .SUCCESS;
    }
};

/// The state root the flocks below plant in.
var plant_dir: fsx.fd_t = -1;

/// A flock that first gives the gate a second link, as can be done while the
/// gate is awaited.
fn linkThenFlock(fd: fsx.fd_t, op: i32) usize {
    _ = linux.linkat(plant_dir, ".lock", plant_dir, "alias", 0);
    return linux.flock(fd, op);
}

/// A flock that first moves the gate to another name, where its file keeps
/// one link: what a planted hard link leaves when it is unlinked during the
/// wait.
fn renameThenFlock(fd: fsx.fd_t, op: i32) usize {
    _ = linux.renameat(plant_dir, ".lock", plant_dir, "victim");
    return linux.flock(fd, op);
}

test "a gate hard-linked to another file is refused and the file keeps its bytes" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try createFile(dir, "victim", "secret");
    _ = try sys.call(linux.linkat, .{ dir, "victim", dir, ".lock", @as(u32, 0) });
    try testing.expectError(error.GateNotPrivate, RootLock.acquire(gpa, root, 0));
    try testing.expect(state.osFailure() == null);
    try expectContents(gpa, dir, "victim", "secret");
}

test "a hard link planted while the gate is awaited stops the truncate" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try createFile(dir, ".lock", "secret");
    plant_dir = dir;
    state.lock_ops.flock = linkThenFlock;
    const before = fdCount(gpa);
    try testing.expectError(error.GateNotPrivate, RootLock.acquire(gpa, root, 0));
    try testing.expectEqual(before, fdCount(gpa));
    try expectContents(gpa, dir, "alias", "secret");
    state.lock_ops.* = .{};
    try sys.unlinkat(dir, "alias", 0);
    const l = try RootLock.acquire(gpa, root, 0);
    l.release();
}

test "a gate moved to another name while it is awaited is not truncated" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try createFile(dir, ".lock", "secret");
    plant_dir = dir;
    state.lock_ops.flock = renameThenFlock;
    try testing.expectError(error.GateNotPrivate, RootLock.acquire(gpa, root, 0));
    try expectContents(gpa, dir, "victim", "secret");
}

fn expectFifoRefused(gpa: std.mem.Allocator, root: []const u8, dir: fsx.fd_t, name: [:0]const u8, want: RootLock.AcquireError) !void {
    _ = try sys.call(linux.mknodat, .{ dir, name.ptr, @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    defer sys.unlinkat(dir, name, 0) catch {};
    const watch = try OpenWatch.init(gpa, root, name);
    defer watch.deinit();
    try testing.expectError(want, RootLock.acquire(gpa, root, 0));
    try testing.expect(!watch.opened());
}

test "a FIFO at either lock name is refused without being opened" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try expectFifoRefused(gpa, root, dir, ".lock", error.GateNotPrivate);
    try expectFifoRefused(gpa, root, dir, ".lock.posix", error.NotPrivate);
}

test "a symbolic link at either lock name or as the state root is refused" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try createFile(dir, "victim", "secret");
    {
        const watch = try OpenWatch.init(gpa, root, "victim");
        defer watch.deinit();
        _ = try sys.call(linux.symlinkat, .{ "victim", dir, ".lock" });
        try testing.expectError(error.GateNotPrivate, RootLock.acquire(gpa, root, 0));
        try sys.unlinkat(dir, ".lock", 0);
        _ = try sys.call(linux.symlinkat, .{ "victim", dir, ".lock.posix" });
        try testing.expectError(error.NotPrivate, RootLock.acquire(gpa, root, 0));
        try sys.unlinkat(dir, ".lock.posix", 0);
        try testing.expect(!watch.opened());
    }
    try expectContents(gpa, dir, "victim", "secret");

    _ = try sys.call(linux.mkdirat, .{ dir, "real", @as(linux.mode_t, 0o700) });
    _ = try sys.call(linux.symlinkat, .{ "real", dir, "link" });
    for ([_][]const u8{ "link", "link/" }) |name| {
        const via = try gpa.print("{s}/{s}", .{ root, name });
        defer gpa.free(via);
        try testing.expectError(error.NotDir, RootLock.acquire(gpa, via, 0));
    }
    try testing.expectError(error.NotFound, fsx.statAt(dir, "real/.lock", false));
}

test "both lock files are created mode 0600" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const l = try RootLock.acquire(gpa, root, 0);
    defer l.release();
    try testing.expectEqual(@as(u32, 0o600), (try fsx.fstat(l.gate)).perm());
    try testing.expectEqual(@as(u32, 0o600), (try fsx.fstat(l.posix)).perm());
}

test "acquire tightens existing owned lock files to mode 0600" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);

    const gate = try sys.openat(dir, ".lock", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o644);
    sys.close(gate);
    const sidecar = try sys.openat(dir, ".lock.posix", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o644);
    sys.close(sidecar);
    try testing.expectEqual(@as(u32, 0o644), (try fsx.statAt(dir, ".lock", false)).perm());
    try testing.expectEqual(@as(u32, 0o644), (try fsx.statAt(dir, ".lock.posix", false)).perm());

    const l = try RootLock.acquire(gpa, root, 0);
    defer l.release();
    try testing.expectEqual(@as(u32, 0o600), (try fsx.fstat(l.gate)).perm());
    try testing.expectEqual(@as(u32, 0o600), (try fsx.fstat(l.posix)).perm());
}
