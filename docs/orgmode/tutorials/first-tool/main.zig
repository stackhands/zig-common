const std = @import("std");
const common = @import("zig_common");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const path = init.environ_map.get("PATH") orelse "/usr/bin:/bin";
    const uname = try common.proc.which(gpa, "uname", path) orelse
        common.cli.die("kernel", "uname is not on PATH", .{});
    defer gpa.free(uname);

    const no_env = [_:null]?[*:0]const u8{};
    const result = try common.proc.run(gpa, uname, &.{ "uname", "-r" }, &no_env, .{
        .timeout_ms = 5_000,
    });
    defer result.deinit(gpa);

    common.cli.out("kernel {s}", .{result.stdout});
    return @intCast(result.term.code());
}
