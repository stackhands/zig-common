//! Command-line plumbing shared by the tools: messages, the exit code for
//! usage errors, and the version line.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

/// Exit code for a refused invocation.
pub const usage_exit: u8 = 2;

/// Write to a descriptor, ignoring errors: a closed stdout or stderr does
/// not change what the tool did.
pub fn put(fd: sys.fd_t, bytes: []const u8) void {
    sys.writeAll(fd, bytes) catch {};
}

/// Format `args` with `fmt` and `put` the text to `fd`. A text longer than
/// 8 KiB is formatted on the heap; when that allocation fails, nothing is
/// written.
pub fn print(fd: sys.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.mem.print(&buf, fmt, args) catch {
        var w: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer w.deinit();
        w.writer.print(fmt, args) catch return;
        put(fd, w.written());
        return;
    };
    put(fd, s);
}

/// `print` to stdout. No newline is added.
pub fn out(comptime fmt: []const u8, args: anytype) void {
    print(1, fmt, args);
}

const printFd = print;

/// Checked writer for standard output (`fd` 1 by default) that reports the
/// first write failure on `err_fd` as `"TOOL: cannot write output (ERRNO)"`
/// and remembers the error so later writes stop and exit status `0` becomes
/// `1`.
pub const Stdout = struct {
    tool: []const u8,
    fd: sys.fd_t = 1,
    err_fd: sys.fd_t = 2,
    failed: bool = false,

    /// Write `bytes` to `fd`. On the first failure, sets `failed`, writes
    /// `"TOOL: cannot write output (ERRNO)\n"` to `err_fd`, and returns
    /// `false`; later calls return `false` without repeating the message.
    pub fn write(self: *Stdout, bytes: []const u8) bool {
        if (self.failed) return false;
        sys.writeAll(self.fd, bytes) catch |e| {
            self.failed = true;
            printFd(self.err_fd, "{s}: cannot write output ({s})\n", .{ self.tool, sys.describe(e) });
            return false;
        };
        return true;
    }

    /// Format `args` with `fmt` and `write` the text. A message longer than
    /// 8 KiB is formatted on the heap; when that allocation fails, sets
    /// `failed` and reports out of memory on `err_fd`.
    pub fn print(self: *Stdout, comptime fmt: []const u8, args: anytype) bool {
        if (self.failed) return false;
        var buf: [8192]u8 = undefined;
        if (std.mem.print(&buf, fmt, args)) |s| {
            return self.write(s);
        } else |_| {}
        var w: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer w.deinit();
        w.writer.print(fmt, args) catch {
            self.failed = true;
            printFd(self.err_fd, "{s}: cannot write output (out of memory)\n", .{self.tool});
            return false;
        };
        return self.write(w.written());
    }

    /// Return `1` when `rc` is `0` and an earlier write failed; otherwise `rc`.
    pub fn finish(self: *const Stdout, rc: u8) u8 {
        return if (rc == 0 and self.failed) 1 else rc;
    }
};

/// Write `bytes` to stdout, reporting `"TOOL: cannot write output (ERRNO)"`
/// on stderr and returning `false` when the write fails.
pub fn writeOut(tool: []const u8, bytes: []const u8) bool {
    var s: Stdout = .{ .tool = tool };
    return s.write(bytes);
}

/// `print` to stderr. No newline is added.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    print(2, fmt, args);
}

/// "TOOL: message" on stderr, then exit 2.
pub fn die(comptime tool: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    err(tool ++ ": " ++ fmt ++ "\n", args);
    std.process.exit(usage_exit);
}

/// "TOOL VERSION (target, optimize mode, zig VERSION, COMMIT)". The first two
/// words are what a script parsing the old version line reads.
pub fn versionLine(comptime tool: []const u8, comptime version: []const u8, comptime commit: []const u8) []const u8 {
    return tool ++ " " ++ version ++ " (" ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++
        @tagName(builtin.abi) ++ ", " ++ @tagName(builtin.mode) ++ ", zig " ++ builtin.zig_version_string ++ ", " ++ commit ++ ")\n";
}

test "put and print ignore write errors and versionLine formats tool and version" {
    put(-1, "ignored\n");
    print(-1, "ignored {d}\n", .{42});

    var big: [9000]u8 = undefined;
    @memset(&big, 'x');
    print(-1, "{s}", .{big[0..]});

    const line = versionLine("demo", "1.2.3", "abc1234");
    try std.testing.expect(std.mem.startsWith(u8, line, "demo 1.2.3 ("));
    try std.testing.expect(std.mem.endsWith(u8, line, ", abc1234)\n"));
}

test "Stdout and writeOut deliver output and report first write failure once" {
    const linux = std.os.linux;
    const fsx = @import("fsx.zig");
    const a = std.testing.allocator;

    {
        var out_fds: [2]i32 = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&out_fds, .{ .CLOEXEC = true })));
        defer sys.close(out_fds[0]);
        var err_fds: [2]i32 = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&err_fds, .{ .CLOEXEC = true })));
        defer sys.close(err_fds[0]);

        var s: Stdout = .{ .tool = "demo", .fd = out_fds[1], .err_fd = err_fds[1] };
        try std.testing.expect(s.write("hello "));
        try std.testing.expect(s.print("world {d}\n", .{7}));
        var big: [9000]u8 = undefined;
        @memset(&big, 'a');
        try std.testing.expect(s.print("{s}\n", .{big[0..]}));
        sys.close(out_fds[1]);
        sys.close(err_fds[1]);

        const got_out = try fsx.readAll(a, out_fds[0], 32 * 1024);
        defer a.free(got_out);
        const got_err = try fsx.readAll(a, err_fds[0], 4096);
        defer a.free(got_err);
        try std.testing.expectEqual(@as(usize, 14 + 9001), got_out.len);
        try std.testing.expect(std.mem.startsWith(u8, got_out, "hello world 7\naaa"));
        try std.testing.expectEqualStrings("", got_err);
        try std.testing.expect(!s.failed);
        try std.testing.expectEqual(@as(u8, 0), s.finish(0));
        try std.testing.expectEqual(@as(u8, 2), s.finish(2));
    }

    {
        var err_fds: [2]i32 = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&err_fds, .{ .CLOEXEC = true })));
        defer sys.close(err_fds[0]);

        var s: Stdout = .{ .tool = "eb-local", .fd = -1, .err_fd = err_fds[1] };
        const runNested = struct {
            fn call(out_writer: *Stdout) u8 {
                _ = out_writer.print("first {d}\n", .{1});
                return 0;
            }
        }.call;
        try std.testing.expectEqual(@as(u8, 1), s.finish(runNested(&s)));
        try std.testing.expect(s.failed);
        try std.testing.expect(!s.write("second\n"));
        try std.testing.expect(!s.print("third {d}\n", .{3}));
        sys.close(err_fds[1]);

        const got_err = try fsx.readAll(a, err_fds[0], 4096);
        defer a.free(got_err);
        try std.testing.expectEqualStrings("eb-local: cannot write output ([Errno 9] Bad file descriptor)\n", got_err);
        try std.testing.expectEqual(@as(u8, 1), s.finish(0));
        try std.testing.expectEqual(@as(u8, 2), s.finish(2));
    }

    if (sys.openat(linux.AT.FDCWD, "/dev/full", .{ .ACCMODE = .WRONLY }, 0)) |full_fd| {
        defer sys.close(full_fd);
        var err_fds: [2]i32 = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&err_fds, .{ .CLOEXEC = true })));
        defer sys.close(err_fds[0]);

        var big: [9000]u8 = undefined;
        @memset(&big, 'z');
        var s: Stdout = .{ .tool = "eb-local", .fd = full_fd, .err_fd = err_fds[1] };
        try std.testing.expect(!s.print("{s}\n", .{big[0..]}));
        try std.testing.expect(!s.write("after\n"));
        sys.close(err_fds[1]);

        const got_err = try fsx.readAll(a, err_fds[0], 4096);
        defer a.free(got_err);
        try std.testing.expectEqualStrings("eb-local: cannot write output ([Errno 28] No space left on device)\n", got_err);

        var child_err: [2]i32 = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&child_err, .{ .CLOEXEC = true })));
        defer sys.close(child_err[0]);
        const pid: isize = @bitCast(linux.fork());
        if (pid < 0) return error.TestUnexpectedResult;
        if (pid == 0) {
            _ = linux.dup2(full_fd, 1);
            _ = linux.dup2(child_err[1], 2);
            const ok = writeOut("demo", "payload\n");
            linux.exit_group(if (ok) 0 else 1);
        }
        sys.close(child_err[1]);
        var raw: i32 = 0;
        while (linux.errno(linux.wait4(@intCast(pid), &raw, 0, null)) == .INTR) {}
        const st: u32 = @bitCast(raw);
        try std.testing.expect(linux.W.IFEXITED(st));
        try std.testing.expectEqual(@as(u8, 1), linux.W.EXITSTATUS(st));
        const child_msg = try fsx.readAll(a, child_err[0], 4096);
        defer a.free(child_msg);
        try std.testing.expectEqualStrings("demo: cannot write output ([Errno 28] No space left on device)\n", child_msg);
    } else |_| {}
}
