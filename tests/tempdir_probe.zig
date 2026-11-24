//! The temporary directory probe: prints what `fsx.TempDir` makes of this
//! process's environment and working directory, as one line. The Python
//! test beside it runs the probe and `tempfile.gettempdir` under the same
//! environment, working directory and limits and compares the lines.
//!
//! The line is `ok`, a tab and the directory, or `err`, a tab, the Python
//! class name and the `str()` of the error, tab separated. Like Python, the
//! probe ignores SIGXFSZ, so a write past a file size limit fails with
//! EFBIG instead of ending the process.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");

const fsx = common.fsx;
const sys = common.sys;

const Env = struct {
    blob: []const u8,

    pub fn get(e: Env, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, e.blob, 0);
        while (it.next()) |entry| {
            const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
        }
        return null;
    }
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const ignore: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.XFSZ, &ignore, null);

    const fd = try sys.openat(fsx.cwd, "/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const env: Env = .{ .blob = try fsx.readAll(a, fd, 1 << 24) };
    var td: fsx.TempDir = .{};
    const line = if (td.get(a, env)) |dir|
        try std.fmt.allocPrint(a, "ok\t{s}\n", .{dir})
    else |err| switch (err) {
        error.NoTempDir => try std.fmt.allocPrint(a, "err\tFileNotFoundError\t{s}\n", .{td.message}),
        error.OutOfMemory => return err,
    };
    _ = linux.write(1, line.ptr, line.len);
}
