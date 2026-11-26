//! Install-location names a child command clears before it runs.
//!
//! `env-scrub.json` is the list. The names are the ones `eb-local env`
//! prints, in that order: the European Environment for Scientific Software
//! Installations (EESSI) install locations, the overrides that move a stack,
//! and EasyBuild's install paths. eb-staged-rebuild also clears
//! `EASYBUILD_REMOVE_GHOST_INSTALL_DIRS`, and `EASYBUILD_BUILDPATH` when the
//! build path is private. Those two stay with that tool.
const std = @import("std");
const env = @import("env.zig");

const source = @embedFile("env-scrub.json");

fn countQuoted(comptime text: []const u8) usize {
    @setEvalBranchQuota(100_000);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '"') continue;
        n += 1;
        i += 1;
        while (i < text.len and text[i] != '"') : (i += 1) {}
    }
    return n;
}

fn quoted(comptime text: []const u8) [countQuoted(text)][]const u8 {
    @setEvalBranchQuota(100_000);
    var out: [countQuoted(text)][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '"') continue;
        const start = i + 1;
        i += 1;
        while (i < text.len and text[i] != '"') : (i += 1) {}
        out[n] = text[start..i];
        n += 1;
    }
    return out;
}

const names = quoted(source);

comptime {
    @setEvalBranchQuota(100_000);
    if (names.len == 0) @compileError("env-scrub.json has no names");
    for (names, 0..) |name, i| {
        if (std.mem.indexOfScalar(u8, name, '\\') != null) @compileError("env-scrub.json: " ++ name);
        if (!env.validName(name)) @compileError("env-scrub.json: " ++ name);
        for (names[i + 1 ..]) |later| {
            if (std.mem.eql(u8, name, later)) @compileError("env-scrub.json repeats " ++ name);
        }
    }
}

/// The names in `env-scrub.json`, in file order.
pub const child_clear: []const []const u8 = &names;

/// The names in `env-scrub.json`, in file order.
pub fn childClearNames() []const []const u8 {
    return child_clear;
}

test "childClearNames is the install-location list, in env's print order" {
    const expect = [_][]const u8{
        "EESSI_CVMFS_INSTALL",
        "EESSI_SITE_INSTALL",
        "EESSI_USER_INSTALL",
        "EESSI_PROJECT_INSTALL",
        "EESSI_SITE_SOFTWARE_PREFIX",
        "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
        "EESSI_ACCELERATOR_TARGET_OVERRIDE",
        "EESSI_OVERRIDE_GPU_CHECK",
        "EASYBUILD_INSTALLPATH",
        "EASYBUILD_INSTALLPATH_SOFTWARE",
        "EASYBUILD_INSTALLPATH_MODULES",
        "EASYBUILD_PREFIX",
    };
    const got = childClearNames();
    try std.testing.expectEqual(expect.len, got.len);
    for (expect, got) |want, have| try std.testing.expectEqualStrings(want, have);
}
