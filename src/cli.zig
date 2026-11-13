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

pub fn print(fd: sys.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        var w: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer w.deinit();
        w.writer.print(fmt, args) catch return;
        put(fd, w.written());
        return;
    };
    put(fd, s);
}

pub fn out(comptime fmt: []const u8, args: anytype) void {
    print(1, fmt, args);
}

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
