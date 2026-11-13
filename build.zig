const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A test artifact of a tool may replace atomic.ops; a released binary
    // never can. Off unless a tool's build asks for it.
    const test_ops = b.option(bool, "test-ops", "Let atomic.ops be replaced (test artifacts only)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "test_ops", test_ops);

    const mod = b.addModule("zig_common", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("zig_common_options", options);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the library tests").dependOn(&run_tests.step);
}
