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
    const root = std.fmt.allocPrint(A, "{s}/.zig-cache/lock-test-{d}-{d}", .{ cwd, linux.getpid(), counter }) catch unreachable;
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

fn fdCount() usize {
    const fd = fsx.openDir(fsx.cwd, "/proc/self/fd", true) catch unreachable;
    defer sys.close(fd);
    var it = fsx.DirIter.init(A, fd) catch unreachable;
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
    const fd = try sys.openat(fsx.cwd, try std.fmt.allocPrint(A, "{s}/.lock", .{root}), .{ .ACCMODE = .RDWR }, 0);
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
    for (0..4) |_| try testing.expectError(error.Busy, RootLock.acquire(A, root, 0));
    try assertRemoteExcluded(root);
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
fn eioOpen(_: [*:0]const u8) usize {
    return err(.IO);
}

test "acquisition errors release the descriptors and the gate" {
    const root = begin();
    defer end(root);
    inline for (.{ "flock", "fcntl", "ftruncate", "write" }) |target| {
        const before = fdCount();
        if (comptime std.mem.eql(u8, target, "flock")) state.lock_ops.flock = eioFlock;
        if (comptime std.mem.eql(u8, target, "fcntl")) state.lock_ops.fcntl = eioFcntl;
        if (comptime std.mem.eql(u8, target, "ftruncate")) state.lock_ops.ftruncate = eioFtruncate;
        if (comptime std.mem.eql(u8, target, "write")) state.lock_ops.write = eioWrite;
        if (RootLock.acquire(A, root, null)) |l| {
            l.release();
            return error.TestUnexpectedResult;
        } else |_| {}
        state.lock_ops.* = .{};
        try testing.expectEqual(before, fdCount());
        try acquireAndRelease(root);
    }
}

test "a sidecar open failure releases the local gate" {
    const root = begin();
    defer end(root);
    state.lock_ops.open_sidecar = eioOpen;
    try testing.expectError(error.Unexpected, RootLock.acquire(A, root, 0));
    state.lock_ops.* = .{};
    try acquireAndRelease(root);
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
    const before = fdCount();
    state.lock_ops.fcntl = eioFcntl;
    holder.release();
    state.lock_ops.* = .{};
    try testing.expectEqual(before - 2, fdCount());
    try acquireAndRelease(root);
}

test "a hard-linked sidecar is refused" {
    const root = begin();
    defer end(root);
    const sidecar = try std.fmt.allocPrint(A, "{s}/.lock.posix", .{root});
    const fd = try sys.openat(fsx.cwd, sidecar, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys.close(fd);
    var za: [sys.path_max:0]u8 = undefined;
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.linkat(linux.AT.FDCWD, (try sys.z(&za, sidecar)).ptr, linux.AT.FDCWD, (try sys.z(&zb, try std.fmt.allocPrint(A, "{s}/sidecar-alias", .{root}))).ptr, 0);
    try testing.expectError(error.NotPrivate, RootLock.acquire(A, root, 0));
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
