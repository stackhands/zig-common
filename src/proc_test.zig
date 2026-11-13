//! Tests of proc.run as the Python tool's bounded ledger call uses it
//! (test_ledger_bounded): the first 64 KiB of each stream kept and the rest
//! drained, the call ended with the child, its group killed and waited for.
//! Helpers are /bin/sh scripts that note their pids in a scratch directory.
const std = @import("std");
const linux = std.os.linux;
const proc = @import("proc.zig");
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");
const atomic = @import("atomic.zig");
const testing = std.testing;

const limit = 64 * 1024;
const no_env: proc.Envp = &[_:null]?[*:0]const u8{};

var arena_state: std.heap.ArenaAllocator = undefined;
var A: std.mem.Allocator = undefined;
var counter: usize = 0;

fn begin() []const u8 {
    arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    A = arena_state.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = fsx.realpath(fsx.cwd, ".", &cwd_buf) catch unreachable;
    counter += 1;
    const root = std.fmt.allocPrint(A, "{s}/.zig-cache/proc-test-{d}-{d}", .{ cwd, linux.getpid(), counter }) catch unreachable;
    atomic.makedirs(root) catch unreachable;
    return root;
}

fn end(root: []const u8) void {
    fsx.deleteTree(A, fsx.cwd, root) catch {};
    arena_state.deinit();
}

fn bounded(timeout_ms: u32) proc.Options {
    return .{
        .stdout_limit = limit,
        .stdout_overflow = .truncate,
        .stderr_limit = limit,
        .timeout_ms = timeout_ms,
        .grace_ms = 0,
        .end_with_leader = true,
        .wait_for_group = true,
    };
}

fn sh(root: []const u8, script: []const u8, opts: proc.Options) proc.Error!proc.Result {
    const full = std.fmt.allocPrint(A, "cd '{s}' || exit 99\n{s}", .{ root, script }) catch unreachable;
    return proc.run(A, "/bin/sh", &.{ "sh", "-c", full }, no_env, opts);
}

fn readPid(root: []const u8, name: []const u8) ?linux.pid_t {
    const path = std.fmt.allocPrint(A, "{s}/{s}", .{ root, name }) catch unreachable;
    const f = fsx.openRegular(fsx.cwd, path, false) catch return null;
    defer sys.close(f.fd);
    const text = fsx.readAll(A, f.fd, 64) catch return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn waitPid(root: []const u8, name: []const u8) !linux.pid_t {
    for (0..1000) |_| {
        if (readPid(root, name)) |p| return p;
        sleepMs(10);
    }
    return error.TestUnexpectedResult;
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

/// A live (not zombie) process.
fn alive(pid: linux.pid_t) bool {
    const path = std.fmt.allocPrint(A, "/proc/{d}/stat", .{pid}) catch unreachable;
    const fd = sys.openat(linux.AT.FDCWD, path, .{}, 0) catch return false;
    defer sys.close(fd);
    var buf: [512]u8 = undefined;
    const n = sys.read(fd, &buf) catch return false;
    const close_paren = std.mem.lastIndexOfScalar(u8, buf[0..n], ')') orelse return false;
    const state = std.mem.trimStart(u8, buf[close_paren + 1 .. n], " ");
    return state.len > 0 and state[0] != 'Z' and state[0] != 'X';
}

/// Live processes whose process group is `pgid`.
fn groupMembers(pgid: linux.pid_t) usize {
    const dir = sys.openat(linux.AT.FDCWD, "/proc", .{ .DIRECTORY = true }, 0) catch return 0;
    defer sys.close(dir);
    var it = fsx.DirIter.init(A, dir) catch return 0;
    var n: usize = 0;
    while (it.next() catch null) |e| {
        if (e.name.len == 0 or !std.ascii.isDigit(e.name[0])) continue;
        const path = std.fmt.allocPrint(A, "/proc/{s}/stat", .{e.name}) catch continue;
        const fd = sys.openat(linux.AT.FDCWD, path, .{}, 0) catch continue;
        var buf: [512]u8 = undefined;
        const got = sys.read(fd, &buf) catch 0;
        sys.close(fd);
        const close_paren = std.mem.lastIndexOfScalar(u8, buf[0..got], ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, buf[close_paren + 1 .. got], ' ');
        const state = fields.next() orelse continue;
        _ = fields.next();
        const pgrp = std.fmt.parseInt(linux.pid_t, fields.next() orelse continue, 10) catch continue;
        if (pgrp == pgid and state[0] != 'Z' and state[0] != 'X') n += 1;
    }
    return n;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "continuous output is never stored and the deadline still holds" {
    const root = begin();
    defer end(root);
    const r = sh(root, "echo $$ > leader\nyes n &\nyes w >&2 &\nwait\n", bounded(1000));
    try testing.expectError(error.TimedOut, r);
    try testing.expectEqual(@as(usize, 0), groupMembers(try waitPid(root, "leader")));
}

test "oversized streams keep the leading limit and the exit code" {
    const root = begin();
    defer end(root);
    const r = try sh(root,
        \\printf 'head\n'
        \\printf 'warn\n' >&2
        \\head -c 8388608 /dev/zero | tr '\0' n
        \\head -c 8388608 /dev/zero | tr '\0' n >&2
        \\exit 3
    , bounded(30_000));
    try testing.expectEqual(@as(u32, 3), r.term.code());
    try testing.expectEqual(@as(usize, limit), r.stdout.len);
    try testing.expectEqual(@as(usize, limit), r.stderr.len);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "head\nnnn"));
    try testing.expect(std.mem.startsWith(u8, r.stderr, "warn\nnnn"));
}

test "writing descendants are stopped when the leader exits" {
    const root = begin();
    defer end(root);
    const r = try sh(root,
        \\echo $$ > leader
        \\for n in 1 2 3 4; do
        \\  ( trap '' TERM; while :; do echo out; echo err >&2; echo file >> output; sleep 0.01; done ) &
        \\  echo $! > worker$n
        \\done
        \\sleep 0.2
        \\echo done
    , bounded(30_000));
    try testing.expectEqual(@as(u32, 0), r.term.code());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "done") != null);
    try testing.expectEqual(@as(usize, 0), groupMembers(try waitPid(root, "leader")));
    for ([_][]const u8{ "worker1", "worker2", "worker3", "worker4" }) |w| try testing.expect(!alive(try waitPid(root, w)));
}

test "a writer that left the group cannot hold the call or outlive its pipe" {
    const root = begin();
    defer end(root);
    const started = nowMs();
    const r = try sh(root,
        \\setsid sh -c 'echo $$ > escaped; while :; do echo x || exit 0; echo y >&2 || exit 0; sleep 0.002; done' &
        \\while [ ! -s escaped ]; do sleep 0.01; done
        \\echo done
    , bounded(30_000));
    try testing.expectEqual(@as(u32, 0), r.term.code());
    try testing.expect(nowMs() - started < 15_000);
    const escaped = try waitPid(root, "escaped");
    var gone = false;
    for (0..1000) |_| {
        if (!alive(escaped)) {
            gone = true;
            break;
        }
        sleepMs(10);
    }
    try testing.expect(gone);
}

test "a timeout returns after every group member has exited" {
    const root = begin();
    defer end(root);
    const r = sh(root,
        \\echo $$ > leader
        \\for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        \\  ( trap '' TERM; while :; do printf x >> output; sleep 0.01; done ) &
        \\done
        \\sleep 3600
    , bounded(1000));
    try testing.expectError(error.TimedOut, r);
    try testing.expectEqual(@as(usize, 0), groupMembers(try waitPid(root, "leader")));
}

var cancel_flag = std.atomic.Value(bool).init(false);
var cancel_root: []const u8 = "";

fn cancelWhenStarted() void {
    for (0..1000) |_| {
        var all = true;
        for ([_][]const u8{ "worker1", "worker2", "worker3", "worker4", "worker5", "worker6", "worker7", "worker8" }) |w| {
            if (readPid(cancel_root, w) == null) all = false;
        }
        if (all) break;
        sleepMs(10);
    }
    cancel_flag.store(true, .seq_cst);
}

test "an interrupted call returns after every group member has exited" {
    const root = begin();
    defer end(root);
    cancel_root = root;
    cancel_flag.store(false, .seq_cst);
    var opts = bounded(60_000);
    opts.cancel = &cancel_flag;
    const thread = try std.Thread.spawn(.{}, cancelWhenStarted, .{});
    const r = sh(root,
        \\echo $$ > leader
        \\for n in 1 2 3 4 5 6 7 8; do
        \\  ( trap '' TERM; while :; do echo out; printf x >> output; sleep 0.01; done ) &
        \\  echo $! > worker$n
        \\done
        \\sleep 3600
    , opts);
    thread.join();
    try testing.expectError(error.Canceled, r);
    try testing.expectEqual(@as(usize, 0), groupMembers(try waitPid(root, "leader")));
}

test "a noisy helper cannot outlive a killed caller" {
    const root = begin();
    defer end(root);
    const pid: isize = @bitCast(linux.fork());
    if (pid == 0) {
        _ = sh(root, "echo $$ > leader\nwhile :; do echo n || exit 0; echo w >&2 || exit 0; done\n", bounded(120_000)) catch {};
        linux.exit_group(0);
    }
    const leader = try waitPid(root, "leader");
    sleepMs(200);
    _ = linux.kill(@intCast(pid), .KILL);
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), @ptrCast(&status), 0, null);
    var gone = false;
    for (0..1000) |_| {
        if (!alive(leader)) {
            gone = true;
            break;
        }
        sleepMs(10);
    }
    try testing.expect(gone);
}
