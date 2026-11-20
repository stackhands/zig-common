const std = @import("std");
const argparse = @import("argparse.zig");

test "optionLike classifies negative numbers and spaced dash tokens under py314 and never" {
    try std.testing.expect(!argparse.optionLike("", .py314));
    try std.testing.expect(!argparse.optionLike("-", .py314));
    try std.testing.expect(!argparse.optionLike("-0", .py314));
    try std.testing.expect(!argparse.optionLike("-1", .py314));
    try std.testing.expect(!argparse.optionLike("-.5", .py314));
    try std.testing.expect(!argparse.optionLike("-1e3", .py314));
    try std.testing.expect(!argparse.optionLike("-foo bar", .py314));
    try std.testing.expect(!argparse.optionLike("--bogus=-a b", .py314));
    try std.testing.expect(argparse.optionLike("--", .py314));
    try std.testing.expect(argparse.optionLike("-a", .py314));
    try std.testing.expect(argparse.optionLike("-.a", .py314));
    try std.testing.expect(argparse.optionLike("--1", .py314));

    try std.testing.expect(!argparse.optionLike("", .never));
    try std.testing.expect(argparse.optionLike("-", .never));
    try std.testing.expect(argparse.optionLike("-5", .never));
    try std.testing.expect(argparse.optionLike("-.5", .never));
    try std.testing.expect(!argparse.optionLike("5", .never));
}

test "CommandSpec and Parsed accessors and UsageError format cleanly without leaks" {
    const gpa = std.testing.allocator;
    const spec: argparse.CommandSpec = .{
        .prog = "demo",
        .usage = "usage: demo [-h] [--json] [--path PATH]\n",
        .help = "usage: demo [-h] [--json] [--path PATH]\n",
        .options = &.{
            .{ .name = "json", .kind = .flag },
            .{ .name = "path", .kind = .value },
        },
    };
    const seen_buf = try gpa.alloc(bool, 2);
    seen_buf[0] = true;
    seen_buf[1] = true;
    const val_buf = try gpa.alloc(?[]const u8, 2);
    val_buf[0] = null;
    val_buf[1] = "/tmp/x";
    const list_buf = try gpa.alloc([]const []const u8, 2);
    list_buf[0] = &.{};
    list_buf[1] = &.{};
    const pos_buf = try gpa.alloc([]const u8, 1);
    pos_buf[0] = "item";

    var outcome: argparse.ParseOutcome = .{ .ok = .{
        .spec = &spec,
        .opt_seen = seen_buf,
        .opt_values = val_buf,
        .opt_lists = list_buf,
        .positionals = pos_buf,
        .remainder = &.{},
        .leftovers = &.{},
    } };
    defer outcome.deinit(gpa);

    try std.testing.expect(outcome.ok.seen("json"));
    try std.testing.expect(!outcome.ok.seen("missing"));
    try std.testing.expectEqualStrings("/tmp/x", outcome.ok.value("path").?);
    try std.testing.expectEqualStrings("item", outcome.ok.positional(0).?);
    try std.testing.expect(outcome.ok.positional(1) == null);

    var uerr: argparse.UsageError = .{
        .usage = spec.usage,
        .prog = spec.prog,
        .message = try gpa.dupe(u8, "unrecognized arguments: --x"),
    };
    defer uerr.deinit(gpa);
    const stderr_txt = try uerr.formatStderr(gpa);
    defer gpa.free(stderr_txt);
    try std.testing.expectEqualStrings(
        "usage: demo [-h] [--json] [--path PATH]\ndemo: error: unrecognized arguments: --x\n",
        stderr_txt,
    );
}
