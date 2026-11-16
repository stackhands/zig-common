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
    const root = A.print("{s}/.zig-cache/proc-test-{d}-{d}", .{ cwd, linux.getpid(), counter }) catch unreachable;
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
    const full = A.print("cd '{s}' || exit 99\n{s}", .{ root, script }) catch unreachable;
    return proc.run(A, "/bin/sh", &.{ "sh", "-c", full }, no_env, opts);
}

fn readPid(root: []const u8, name: []const u8) ?linux.pid_t {
    const path = A.print("{s}/{s}", .{ root, name }) catch unreachable;
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
    const path = A.print("/proc/{d}/stat", .{pid}) catch unreachable;
    const fd = sys.openat(linux.AT.FDCWD, path, .{}, 0) catch return false;
    defer sys.close(fd);
    var buf: [512]u8 = undefined;
    const n = sys.read(fd, &buf) catch return false;
    const close_paren = std.mem.findScalarLast(u8, buf[0..n], ')') orelse return false;
    const state = std.mem.trimStart(u8, buf[close_paren + 1 .. n], " ");
    return state.len > 0 and state[0] != 'Z' and state[0] != 'X';
}

/// The process whose pid the script noted in `name`, if it did, is gone
/// within a second; one that is not is killed, so it cannot outlive the test.
fn expectGone(root: []const u8, name: []const u8) !void {
    const pid = readPid(root, name) orelse return;
    for (0..100) |_| {
        if (!alive(pid)) return;
        sleepMs(10);
    }
    _ = linux.kill(pid, .KILL);
    return error.TestUnexpectedResult;
}

/// Live processes whose process group is `pgid`.
fn groupMembers(pgid: linux.pid_t) usize {
    const dir = sys.openat(linux.AT.FDCWD, "/proc", .{ .DIRECTORY = true }, 0) catch return 0;
    defer sys.close(dir);
    var it = fsx.DirIter.init(A, dir) catch return 0;
    var n: usize = 0;
    while (it.next() catch null) |e| {
        if (e.name.len == 0 or !std.ascii.isDigit(e.name[0])) continue;
        const path = A.print("/proc/{s}/stat", .{e.name}) catch continue;
        const fd = sys.openat(linux.AT.FDCWD, path, .{}, 0) catch continue;
        var buf: [512]u8 = undefined;
        const got = sys.read(fd, &buf) catch 0;
        sys.close(fd);
        const close_paren = std.mem.findScalarLast(u8, buf[0..got], ')') orelse continue;
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
    try testing.expect(std.mem.find(u8, r.stdout, "done") != null);
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

// A flag set before the call cancels as soon as the child is forked, mostly
// before it has called setsid and made the group the kill is sent to.
test "a cancel before the child has made its group kills it and all it starts" {
    const root = begin();
    defer end(root);
    var flag = std.atomic.Value(bool).init(true);
    for (0..100) |i| {
        const name = A.print("background{d}", .{i}) catch unreachable;
        const script = A.print("sleep 30 >/dev/null &\necho $! > {s}\nsleep 2\n", .{name}) catch unreachable;
        const started = nowMs();
        const r = sh(root, script, .{ .cancel = &flag });
        const took = nowMs() - started;
        try expectGone(root, name);
        try testing.expectError(error.Canceled, r);
        try testing.expect(took < 1000);
    }
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

test "a failed exec is its errno's error with exec_error and exit 127 without" {
    const root = begin();
    defer end(root);
    var opts = bounded(30_000);
    opts.exec_error = true;
    const missing = A.print("{s}/missing", .{root}) catch unreachable;
    try testing.expectError(error.NotFound, proc.run(A, missing, &.{missing}, no_env, opts));
    const plain = A.print("{s}/plain", .{root}) catch unreachable;
    const fd = try sys.openat(linux.AT.FDCWD, plain, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys.close(fd);
    try testing.expectError(error.AccessDenied, proc.run(A, plain, &.{plain}, no_env, opts));
    const ok = try proc.run(A, "/bin/sh", &.{ "sh", "-c", "echo ran" }, no_env, opts);
    try testing.expectEqual(@as(u32, 0), ok.term.code());
    try testing.expectEqualStrings("ran\n", ok.stdout);
    opts.exec_error = false;
    const r = try proc.run(A, missing, &.{missing}, no_env, opts);
    try testing.expectEqual(@as(u32, 127), r.term.code());
}

var stop_pgid = std.atomic.Value(i32).init(0);
var stop_root: []const u8 = "";

fn stopWhenStarted() void {
    for (0..1000) |_| {
        if (readPid(stop_root, "worker") != null and stop_pgid.load(.seq_cst) > 0) break;
        sleepMs(10);
    }
    const g = stop_pgid.load(.seq_cst);
    proc.stopGroup(g);
}

test "stopGroup leaves no member of a published group alive" {
    const root = begin();
    defer end(root);
    stop_root = root;
    stop_pgid.store(0, .seq_cst);
    var opts = bounded(60_000);
    opts.pgid_out = &stop_pgid;
    const thread = try std.Thread.spawn(.{}, stopWhenStarted, .{});
    const r = sh(root,
        \\echo $$ > leader
        \\( trap '' TERM; while :; do printf x >> output; sleep 0.01; done ) &
        \\echo $! > worker
        \\sleep 3600
    , opts) catch null;
    thread.join();
    if (r) |res| try testing.expect(res.term.code() != 0);
    try testing.expectEqual(@as(usize, 0), groupMembers(try waitPid(root, "leader")));
    try testing.expect(!alive(try waitPid(root, "worker")));
}

fn stopWhenPublished() void {
    const until = nowMs() + 10_000;
    while (nowMs() < until) {
        const g = stop_pgid.load(.seq_cst);
        if (g > 0) return proc.stopGroup(g);
        std.atomic.spinLoopHint();
    }
}

// A handler that stops the group and exits leaves nothing to stop the
// child later, so stopGroup must reach it before it has made its group too.
test "stopGroup on a pgid as soon as it is published kills the child" {
    const root = begin();
    defer end(root);
    // On one CPU the child waits while this thread and the stopping one
    // run, so the stop comes before its setsid nearly every time. With more,
    // stopGroup's scan of the group mostly gives it time to make the group.
    var cpus: linux.cpu_set_t = undefined;
    const pinned = linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpus)) == .SUCCESS;
    if (pinned) {
        var one = std.mem.zeroes(linux.cpu_set_t);
        for (cpus, &one) |c, *o| if (c != 0) {
            o.* = c & -%c;
            break;
        };
        try linux.sched_setaffinity(0, &one);
    }
    defer if (pinned) linux.sched_setaffinity(0, &cpus) catch {};
    for (0..50) |i| {
        stop_pgid.store(0, .seq_cst);
        const name = A.print("background{d}", .{i}) catch unreachable;
        const script = A.print("sleep 30 >/dev/null &\necho $! > {s}\nsleep 2\n", .{name}) catch unreachable;
        const thread = try std.Thread.spawn(.{}, stopWhenPublished, .{});
        const started = nowMs();
        const r = sh(root, script, .{ .pgid_out = &stop_pgid });
        thread.join();
        const took = nowMs() - started;
        try expectGone(root, name);
        try testing.expectEqual(@as(u32, 128 + 9), (try r).term.code());
        try testing.expect(took < 1000);
    }
}

var kill_pgid = std.atomic.Value(i32).init(0);
var winches = std.atomic.Value(u32).init(0);

fn onUsr2KillGroup(_: linux.SIG) callconv(.c) void {
    proc.killGroup(kill_pgid.load(.seq_cst), .KILL);
}

fn onWinch(_: linux.SIG) callconv(.c) void {
    _ = winches.fetchAdd(1, .seq_cst);
}

fn signalWhenStarted(root: []const u8, tid: linux.pid_t) void {
    for (0..1000) |_| {
        if (readPid(root, "background") != null) break;
        sleepMs(10);
    }
    _ = linux.tgkill(linux.getpid(), tid, .USR2);
}

/// Child `pid`, forked by the test, ends by SIGKILL within a second; one
/// that does not is killed, so it cannot outlive the test.
fn expectKilled(pid: linux.pid_t) !void {
    var status: u32 = 0;
    for (0..100) |_| {
        if (linux.wait4(pid, @ptrCast(&status), linux.W.NOHANG, null) == @as(usize, @intCast(pid))) {
            return testing.expectEqual(@as(u32, 9), status & 0x7f);
        }
        sleepMs(10);
    }
    _ = linux.kill(pid, .KILL);
    _ = linux.wait4(pid, @ptrCast(&status), 0, null);
    return error.TestUnexpectedResult;
}

test "killGroup in a signal handler kills a child before and after it has made its group" {
    const root = begin();
    defer end(root);
    var prev_usr2: linux.Sigaction = undefined;
    const on_usr2: linux.Sigaction = .{ .handler = .{ .handler = &onUsr2KillGroup }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.USR2, &on_usr2, &prev_usr2);
    defer _ = linux.sigaction(.USR2, &prev_usr2, null);
    var prev_winch: linux.Sigaction = undefined;
    const on_winch: linux.Sigaction = .{ .handler = .{ .handler = &onWinch }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.WINCH, &on_winch, &prev_winch);
    defer _ = linux.sigaction(.WINCH, &prev_winch, null);
    const tid = linux.gettid();

    // pgid_out's 0, no child, is not this process's own group.
    proc.killGroup(0, .WINCH);
    try testing.expectEqual(@as(u32, 0), winches.load(.seq_cst));

    // Between fork and setsid the child is in this process's group and no
    // group has its pid for id, so only a kill of the child itself reaches it.
    const child: isize = @bitCast(linux.fork());
    if (child == 0) {
        sleepMs(30_000);
        linux.exit_group(0);
    }
    try testing.expect(child > 0);
    kill_pgid.store(@intCast(child), .seq_cst);
    _ = linux.tgkill(linux.getpid(), tid, .USR2);
    try expectKilled(@intCast(child));

    // Once it has made the group, all of it, here while run waits on it.
    kill_pgid.store(0, .seq_cst);
    const thread = try std.Thread.spawn(.{}, signalWhenStarted, .{ root, tid });
    const r = sh(root, "sleep 30 >/dev/null &\necho $! > background\nsleep 30\n", .{ .pgid_out = &kill_pgid });
    thread.join();
    try expectGone(root, "background");
    try testing.expectEqual(@as(u32, 128 + 9), (try r).term.code());
}

test "stdin to a child that does not read it fails with EPIPE, not SIGPIPE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try a.alloc(u8, 1 << 20);
    @memset(input, 'x');
    // The runner may start with SIGPIPE at its default; make sure it does,
    // so a write after `true` exits would end the test without the guard.
    var before: linux.Sigaction = undefined;
    const default: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &default, &before);
    defer _ = linux.sigaction(.PIPE, &before, null);
    const res = try proc.run(a, "/bin/true", &.{"true"}, no_env, .{ .stdin = input });
    try testing.expectEqual(@as(u8, 0), res.term.code());
    var after: linux.Sigaction = undefined;
    _ = linux.sigaction(.PIPE, null, &after);
    try testing.expect(after.handler.handler == linux.SIG.DFL);
}
