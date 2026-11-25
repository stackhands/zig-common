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
const test_support = @import("test_support.zig");
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
            l.release() catch unreachable;
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
    l.release() catch unreachable;
}

test "the record lock excludes an independent kernel gate" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    assertRemoteExcluded(root) catch |e| {
        holder.release() catch unreachable;
        return e;
    };
    holder.release() catch unreachable;
    try acquireAndRelease(root);
}

test "failed local contenders keep the record lock" {
    const root = begin();
    defer end(root);
    const holder = try RootLock.acquire(A, root, 0);
    defer holder.release() catch unreachable;
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
    held.release() catch unreachable;
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
    defer holder.release() catch unreachable;
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
fn shortWrite(_: fsx.fd_t, bytes: []const u8) usize {
    return bytes.len - 1;
}
fn eioOpen(_: fsx.fd_t, _: [*:0]const u8) usize {
    return err(.IO);
}

test "acquisition errors release the descriptors and the gate" {
    const root = begin();
    defer end(root);
    inline for (.{ "flock", "fcntl", "ftruncate", "write" }) |target| {
        const before = try test_support.fdCount(A);
        if (comptime std.mem.eql(u8, target, "flock")) state.lock_ops.flock = eioFlock;
        if (comptime std.mem.eql(u8, target, "fcntl")) state.lock_ops.fcntl = eioFcntl;
        if (comptime std.mem.eql(u8, target, "ftruncate")) state.lock_ops.ftruncate = eioFtruncate;
        if (comptime std.mem.eql(u8, target, "write")) state.lock_ops.write = eioWrite;
        if (RootLock.acquire(A, root, null)) |l| {
            l.release() catch unreachable;
            return error.TestUnexpectedResult;
        } else |_| {}
        const failure = state.osFailure() orelse unreachable;
        try testing.expectEqualStrings("", failure.path);
        try testing.expectEqualStrings("[Errno 5] Input/output error", failure.text);
        state.lock_ops.* = .{};
        try testing.expectEqual(before, try test_support.fdCount(A));
        try acquireAndRelease(root);
    }
}

test "a blocking record lock records EAGAIN and EACCES" {
    const root = begin();
    defer end(root);
    const Hooks = struct {
        var code: linux.E = .AGAIN;
        fn fail(_: fsx.fd_t, _: i32, _: usize) usize {
            return err(code);
        }
    };
    defer state.lock_ops.* = .{};
    state.lock_ops.fcntl = Hooks.fail;
    for ([_]linux.E{ .AGAIN, .ACCES }) |code| {
        Hooks.code = code;
        sys.last_errno = .SUCCESS;
        if (RootLock.acquire(A, root, null)) |_| {
            return error.TestUnexpectedResult;
        } else |failed| {
            const failure = state.osFailure() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("", failure.path);
            try testing.expectEqualStrings(sys.describeErrno(code), failure.text);
            try testing.expectEqual(code, sys.last_errno);
            // describe of the returned error must name this errno. Returning
            // Unexpected for EACCES makes it print an I/O error instead.
            const sys_err = sys.asError(failed) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(failure.text, sys.describe(sys_err));
            switch (code) {
                .AGAIN => try testing.expectEqual(error.Unexpected, sys_err),
                .ACCES => try testing.expectEqual(error.AccessDenied, sys_err),
                else => unreachable,
            }
        }
    }
}

test "a short pid write does not reuse a stale errno" {
    const root = begin();
    defer end(root);
    const initialized = try RootLock.acquire(A, root, 0);
    initialized.release() catch unreachable;
    sys.last_errno = .DQUOT;
    state.lock_ops.write = shortWrite;
    try testing.expectError(error.NoSpace, RootLock.acquire(A, root, 0));
    const failure = state.osFailure() orelse unreachable;
    try testing.expectEqualStrings("", failure.path);
    try testing.expectEqualStrings("[Errno 28] No space left on device", failure.text);
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
    defer holder.release() catch unreachable;
    const pid: isize = @bitCast(linux.fork());
    if (pid == 0) {
        holder.release() catch unreachable;
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
    const before = try test_support.fdCount(A);
    state.lock_ops.fcntl = eioFcntl;
    try testing.expectError(error.Unexpected, holder.release());
    state.lock_ops.* = .{};
    try testing.expectEqual(before - 2, try test_support.fdCount(A));
    try acquireAndRelease(root);
}

fn einvalFlock(_: fsx.fd_t, _: i32) usize {
    return err(.INVAL);
}

fn isOpen(fd: fsx.fd_t) bool {
    return linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) != .BADF;
}

test "a failed unlock is returned with both descriptors closed" {
    const root = begin();
    defer end(root);
    const Case = struct { fcntl: bool, flock: bool, want: sys.Error, errno: linux.E, text: []const u8 };
    // with both unlocks failing, the record lock's error and errno are the
    // ones returned and kept, not the gate's
    for ([_]Case{
        .{ .fcntl = true, .flock = false, .want = error.Unexpected, .errno = .IO, .text = "[Errno 5] Input/output error" },
        .{ .fcntl = false, .flock = true, .want = error.InvalidArgument, .errno = .INVAL, .text = "[Errno 22] Invalid argument" },
        .{ .fcntl = true, .flock = true, .want = error.Unexpected, .errno = .IO, .text = "[Errno 5] Input/output error" },
    }) |c| {
        const holder = try RootLock.acquire(A, root, 0);
        const before = try test_support.fdCount(A);
        if (c.fcntl) state.lock_ops.fcntl = eioFcntl;
        if (c.flock) state.lock_ops.flock = einvalFlock;
        sys.last_errno = .SUCCESS;
        const released = holder.release();
        state.lock_ops.* = .{};
        try testing.expectError(c.want, released);
        try testing.expectEqual(c.errno, sys.last_errno);
        try testing.expectEqualStrings(c.text, sys.describe(c.want));
        try testing.expect(!isOpen(holder.posix));
        try testing.expect(!isOpen(holder.gate));
        try testing.expectEqual(before - 2, try test_support.fdCount(A));
        try acquireAndRelease(root);
    }
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
    defer holder.release() catch unreachable;
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
    const before = try test_support.fdCount(gpa);
    try testing.expectError(error.GateNotPrivate, RootLock.acquire(gpa, root, 0));
    try testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectContents(gpa, dir, "alias", "secret");
    state.lock_ops.* = .{};
    try sys.unlinkat(dir, "alias", 0);
    const l = try RootLock.acquire(gpa, root, 0);
    l.release() catch unreachable;
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
    defer l.release() catch unreachable;
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
    defer l.release() catch unreachable;
    try testing.expectEqual(@as(u32, 0o600), (try fsx.fstat(l.gate)).perm());
    try testing.expectEqual(@as(u32, 0o600), (try fsx.fstat(l.posix)).perm());
}

// ---- writePrivate: the sync and the close come before the rename ----------

const WriteHooks = struct {
    var closes: usize = 0;
    var close_errno: linux.E = .SUCCESS;
    var fsync_errno: linux.E = .SUCCESS;

    fn set(fsync_e: linux.E, close_e: linux.E) void {
        closes = 0;
        fsync_errno = fsync_e;
        close_errno = close_e;
        state.write_ops.* = .{ .fsync = fsync, .close = close };
    }
    fn fsync(fd: fsx.fd_t) usize {
        if (fsync_errno != .SUCCESS) return err(fsync_errno);
        return linux.fsync(fd);
    }
    /// Linux frees the descriptor whatever close returns, so the hook
    /// closes it for real and then reports the errno it was given, on the
    /// first call only: a second close of the descriptor is EBADF.
    fn close(fd: fsx.fd_t) usize {
        closes += 1;
        const rc = linux.close(fd);
        if (close_errno == .SUCCESS or closes > 1) return rc;
        return err(close_errno);
    }
};

fn expectNoTemporary(gpa: std.mem.Allocator, dir: fsx.fd_t) !void {
    var it = try fsx.DirIter.init(gpa, dir);
    defer it.deinit(gpa);
    while (try it.next()) |e| try testing.expect(!std.mem.endsWith(u8, e.name, ".tmp"));
}

const WriteCase = struct { fsync: linux.E = .SUCCESS, close: linux.E = .SUCCESS, want: sys.Error };

fn expectWriteRefused(gpa: std.mem.Allocator, cases: []const WriteCase) !void {
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    defer state.write_ops.* = .{};
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try state.writePrivate(gpa, dir, "c.json", "old\n");
    for (cases) |c| {
        const code = if (c.close != .SUCCESS) c.close else c.fsync;
        for ([_][]const u8{ "c.json", "fresh.json" }) |name| {
            const before = try test_support.fdCount(gpa);
            WriteHooks.set(c.fsync, c.close);
            sys.last_errno = .SUCCESS;
            const wrote = state.writePrivate(gpa, dir, name, "new\n");
            state.write_ops.* = .{};
            try testing.expectError(c.want, wrote);
            try testing.expectEqual(code, sys.last_errno);
            try testing.expectEqualStrings(sys.describeErrno(code), sys.describe(c.want));
            try testing.expectEqual(@as(usize, 1), WriteHooks.closes);
            try testing.expectEqual(before, try test_support.fdCount(gpa));
            try expectNoTemporary(gpa, dir);
        }
        try expectContents(gpa, dir, "c.json", "old\n");
        try testing.expectError(error.NotFound, fsx.statAt(dir, "fresh.json", false));
    }
}

test "a failed close of the written file is returned and the name is not replaced" {
    try expectWriteRefused(testing.allocator, &.{
        .{ .close = .IO, .want = error.Unexpected },
        .{ .close = .NOSPC, .want = error.NoSpace },
        .{ .close = .DQUOT, .want = error.NoSpace },
    });
}

test "a failed fsync of the written file is returned and the file is closed once" {
    try expectWriteRefused(testing.allocator, &.{
        .{ .fsync = .IO, .want = error.Unexpected },
        .{ .fsync = .NOSPC, .want = error.NoSpace },
    });
}

test "a close that EINTR interrupts is not retried and is not an error" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    defer state.write_ops.* = .{};
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    try state.writePrivate(gpa, dir, "c.json", "old\n");
    const before = try test_support.fdCount(gpa);
    WriteHooks.set(.SUCCESS, .INTR);
    try state.writePrivate(gpa, dir, "c.json", "new\n");
    state.write_ops.* = .{};
    try testing.expectEqual(@as(usize, 1), WriteHooks.closes);
    try testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectContents(gpa, dir, "c.json", "new\n");
    try expectNoTemporary(gpa, dir);
}

test "a sync that EINTR interrupts is retried" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    defer state.write_ops.* = .{};
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    const Intr = struct {
        var syncs: usize = 0;
        fn fsync(fd: fsx.fd_t) usize {
            syncs += 1;
            if (syncs == 1) return err(.INTR);
            return linux.fsync(fd);
        }
    };
    const before = try test_support.fdCount(gpa);
    WriteHooks.set(.SUCCESS, .SUCCESS);
    Intr.syncs = 0;
    state.write_ops.fsync = Intr.fsync;
    try state.writePrivate(gpa, dir, "c.json", "new\n");
    state.write_ops.* = .{};
    try testing.expectEqual(@as(usize, 2), Intr.syncs);
    try testing.expectEqual(@as(usize, 1), WriteHooks.closes);
    try testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectContents(gpa, dir, "c.json", "new\n");
    try expectNoTemporary(gpa, dir);
}

test "writePrivate closes the written file once when it succeeds" {
    const gpa = testing.allocator;
    const root = try scratchRoot(gpa);
    defer removeRoot(gpa, root);
    defer state.write_ops.* = .{};
    const dir = try fsx.openDir(fsx.cwd, root, false);
    defer sys.close(dir);
    const before = try test_support.fdCount(gpa);
    WriteHooks.set(.SUCCESS, .SUCCESS);
    try state.writePrivate(gpa, dir, "c.json", "new\n");
    state.write_ops.* = .{};
    try testing.expectEqual(@as(usize, 1), WriteHooks.closes);
    try testing.expectEqual(before, try test_support.fdCount(gpa));
    try expectContents(gpa, dir, "c.json", "new\n");
    try expectNoTemporary(gpa, dir);
}
