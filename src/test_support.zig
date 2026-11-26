//! Helpers the unit tests share. The library test root imports this file
//! the same way it imports the other test files. A release build does not.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");

/// An empty directory `.zig-cache/zig-common-TAG-PID` for one test. A
/// directory a killed run of the same pid left behind is removed first, so
/// the test starts from nothing. `path` is absolute; `fd` is open on it.
pub const ScratchDir = struct {
    gpa: std.mem.Allocator,
    path: []u8,
    fd: fsx.fd_t,

    pub fn init(gpa: std.mem.Allocator, tag: []const u8) !ScratchDir {
        var cwd_buf: [sys.path_max]u8 = undefined;
        const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
        const path = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/zig-common-{s}-{d}", .{ here, tag, linux.getpid() });
        errdefer gpa.free(path);
        fsx.deleteTree(gpa, fsx.cwd, path) catch {};
        var zb: [sys.path_max:0]u8 = undefined;
        _ = try sys.call(linux.mkdirat, .{ fsx.cwd, (try sys.z(&zb, path)).ptr, @as(linux.mode_t, 0o700) });
        errdefer sys.unlinkat(fsx.cwd, path, linux.AT.REMOVEDIR) catch {};
        const fd = try fsx.openDir(fsx.cwd, path, false);
        return .{ .gpa = gpa, .path = path, .fd = fd };
    }

    pub fn deinit(self: ScratchDir) void {
        fsx.deleteTree(self.gpa, fsx.cwd, self.path) catch {};
        sys.close(self.fd);
        self.gpa.free(self.path);
    }
};

/// Open descriptors of this process, not counting the directory descriptor
/// used to read `/proc/self/fd`. Opening that directory or reading an entry
/// returns the error, so a failed read cannot look like a smaller count.
pub fn fdCount(gpa: std.mem.Allocator) (fsx.Error || std.mem.Allocator.Error)!usize {
    const fd = try fsx.openDir(fsx.cwd, "/proc/self/fd", true);
    defer sys.close(fd);
    var it = try fsx.DirIter.init(gpa, fd);
    defer it.deinit(gpa);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n - 1; // the directory's own descriptor
}

fn childTerm(status: u32) proc.Term {
    if (status & 0x7f == 0) return .{ .exited = linux.W.EXITSTATUS(status) };
    return .{ .signaled = status & 0x7f };
}

/// Run `body` in a forked child, which may close the descriptors the test
/// runner talks over, and expect it to exit 0. `wait4` is retried when the
/// call is interrupted.
pub fn expectChildPasses(comptime body: fn () u8) !void {
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) return error.Unexpected;
    if (pid == 0) linux.exit_group(body());
    var status: i32 = 0;
    while (linux.errno(linux.wait4(@intCast(pid), &status, 0, null)) == .INTR) {}
    try std.testing.expectEqual(proc.Term{ .exited = 0 }, childTerm(@bitCast(status)));
}

test "ScratchDir starts empty when a directory of the same name was left behind" {
    const gpa = std.testing.allocator;
    {
        const stale = try ScratchDir.init(gpa, "scratch-stale");
        errdefer stale.deinit();
        const file = try sys.openat(stale.fd, "a.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
        sys.close(file);
        var zb: [sys.path_max:0]u8 = undefined;
        _ = try sys.call(linux.mkdirat, .{ stale.fd, (try sys.z(&zb, "sub")).ptr, @as(linux.mode_t, 0o700) });
        sys.close(stale.fd);
        gpa.free(stale.path);
    }

    const fresh = try ScratchDir.init(gpa, "scratch-stale");
    defer fresh.deinit();
    const again = try sys.openat(fresh.fd, "a.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
    sys.close(again);
    try std.testing.expectError(error.NotFound, fsx.statAt(fresh.fd, "sub", false));
}
