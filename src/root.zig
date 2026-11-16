//! zig-common: the pieces the stackhands Zig tools share. Linux only.
/// Linux system calls with errno mapped to a Zig error set.
pub const sys = @import("sys.zig");
/// File handling with the checks done on the open file descriptor.
pub const fsx = @import("fsx.zig");
/// Running a child program.
pub const proc = @import("proc.zig");
/// Log files: gzip in place, and the `.licensed-logs` list.
pub const logs = @import("logs.zig");
/// Messages, the exit code for usage errors, and the version line.
pub const cli = @import("cli.zig");
/// The environment as the C library sees it.
pub const env = @import("env.zig");
/// Private state files in a directory other users may write.
pub const state = @import("state.zig");
/// JSON as the Python tools these programs replace read and wrote it.
pub const json = @import("json.zig");
/// Python's view of byte strings.
pub const pytext = @import("pytext.zig");
/// Replacing a file whose owner, mode and ACLs must survive.
pub const atomic = @import("atomic.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("atomic_test.zig");
    _ = @import("state_test.zig");
    _ = @import("proc_test.zig");
}
