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

    // The parity probe, whose output tests/test_json_pytext_parity.py
    // compares byte for byte with Python's json and text calls.
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/parity_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_mod.addImport("zig_common", mod);
    const probe = b.addExecutable(.{ .name = "parity_probe", .root_module = probe_mod });
    const install_probe = b.addInstallArtifact(probe, .{});
    b.step("parity-probe", "Build the Python parity probe").dependOn(&install_probe.step);

    // The filesystem parity probe, whose output tests/test_fs_lock_parity.py
    // compares byte for byte with Python's path, filesystem and lock calls.
    const fs_probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/fs_lock_parity_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_probe_mod.addImport("zig_common", mod);
    const fs_probe = b.addExecutable(.{ .name = "fs_lock_parity_probe", .root_module = fs_probe_mod });
    const install_fs_probe = b.addInstallArtifact(fs_probe, .{});
    b.step("fs-lock-parity-probe", "Build the filesystem parity probe").dependOn(&install_fs_probe.step);

    // The API reference from the doc comments, into <prefix>/docs.
    const lib = b.addLibrary(.{ .name = "zig_common", .root_module = mod });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate the API reference").dependOn(&docs.step);
}
