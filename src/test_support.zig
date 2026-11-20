//! Helpers the unit tests share. The library test root imports this file
//! the same way it imports the other test files. A release build does not.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");

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
