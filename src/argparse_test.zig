const std = @import("std");
const argparse = @import("argparse.zig");

const probe_spec: argparse.CommandSpec = .{
    .prog = "demo probe",
    .usage = "usage: demo probe [-h] [--path PATH] [--json]\n",
    .help = "usage: demo probe [-h] [--path PATH] [--json]\n\noptions:\n  -h, --help\n",
    .options = &.{
        .{ .name = "path", .kind = .value },
        .{ .name = "json", .kind = .flag },
    },
};

const resolve_spec: argparse.CommandSpec = .{
    .prog = "demo resolve",
    .usage = "usage: demo resolve [-h] module\n",
    .help = "usage: demo resolve [-h] module\n",
    .positionals = &.{.{ .name = "module", .arity = .required_one }},
};

const status_spec: argparse.CommandSpec = .{
    .prog = "demo status",
    .usage = "usage: demo status [-h] --state-root STATE_ROOT [--json] [run_id]\n",
    .help = "usage: demo status [-h] --state-root STATE_ROOT [--json] [run_id]\n",
    .options = &.{
        .{ .name = "state-root", .kind = .value, .required = true },
        .{ .name = "json", .kind = .flag },
    },
    .positionals = &.{.{ .name = "run_id", .arity = .optional_one }},
};

const run_spec: argparse.CommandSpec = .{
    .prog = "demo run",
    .usage = "usage: demo run [-h] [--module MODULE] [--dry-run] ...\n",
    .help = "usage: demo run [-h] [--module MODULE] [--dry-run] ...\n",
    .options = &.{
        .{ .name = "module", .kind = .append },
        .{ .name = "dry-run", .kind = .flag },
    },
    .positionals = &.{.{ .name = "eb_args", .arity = .remainder }},
};

const top_spec: argparse.CommandSpec = .{
    .prog = "demo",
    .usage = "usage: demo [-h] [--version] {probe,resolve,status,run} ...\n",
    .help = "usage: demo [-h] [--version] {probe,resolve,status,run} ...\n",
    .version = "demo 1.0.0\n",
    .subcommands = &.{
        .{ .name = "probe", .command = &probe_spec },
        .{ .name = "resolve", .command = &resolve_spec },
        .{ .name = "status", .command = &status_spec },
        .{ .name = "run", .command = &run_spec },
    },
};

const short_spec: argparse.CommandSpec = .{
    .prog = "short",
    .usage = "usage: short [-h] [-a] [-b] [-o OUT] [pos]\n",
    .help = "usage: short [-h] [-a] [-b] [-o OUT] [pos]\n",
    .options = &.{
        .{ .name = "alpha", .short = 'a', .kind = .flag },
        .{ .name = "beta", .short = 'b', .kind = .flag },
        .{ .name = "out", .short = 'o', .kind = .value },
    },
    .positionals = &.{.{ .name = "pos", .arity = .optional_one }},
};

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

test "contract 1: abbreviations, prefix matching, and ambiguity order" {
    const gpa = std.testing.allocator;

    // Unique prefixes of --help and --version
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"--he"});
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), out.action_done.exit_code);
        try std.testing.expectEqualStrings(top_spec.help, out.action_done.stdout_text);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"--ver"});
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), out.action_done.exit_code);
        try std.testing.expectEqualStrings("demo 1.0.0\n", out.action_done.stdout_text);
    }
    // Ambiguous --= lists full raw token and --help first
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"--=foo"});
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 2), out.usage_error.exit_code);
        try std.testing.expectEqualStrings("ambiguous option: --=foo could match --help, --version", out.usage_error.message);
    }
    // Subcommand unique abbreviation
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--p", "/tmp", "--j" });
        defer out.deinit(gpa);
        const sub = out.ok.subcommand().?;
        try std.testing.expectEqualStrings("/tmp", sub.value("path").?);
        try std.testing.expect(sub.seen("json"));
    }
}

test "contract 2: --opt=value vs --opt value, ignored explicit arg, expected one argument" {
    const gpa = std.testing.allocator;

    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--path=-a b" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("-a b", out.ok.subcommand().?.value("path").?);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--json=1" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --json: ignored explicit argument '1'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--help=1" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument -h/--help: ignored explicit argument '1'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"--version=1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --version: ignored explicit argument '1'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--path" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --path: expected one argument", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--path", "--json" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --path: expected one argument", out.usage_error.message);
    }
}

test "contract 3: short option clustering and -h clusters" {
    const gpa = std.testing.allocator;

    {
        var out = try argparse.parse(gpa, &short_spec, &.{ "-ab", "-o=val" });
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("alpha"));
        try std.testing.expect(out.ok.seen("beta"));
        try std.testing.expectEqualStrings("val", out.ok.value("out").?);
    }
    {
        var out = try argparse.parse(gpa, &short_spec, &.{"-ao=val"});
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("alpha"));
        try std.testing.expectEqualStrings("val", out.ok.value("out").?);
    }
    {
        var out = try argparse.parse(gpa, &short_spec, &.{"-aoval"});
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("alpha"));
        try std.testing.expectEqualStrings("val", out.ok.value("out").?);
    }
    {
        var out = try argparse.parse(gpa, &short_spec, &.{"-ab=1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument -b/--beta: ignored explicit argument '1'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &short_spec, &.{"-azb"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: -zb", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"-hh"});
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), out.action_done.exit_code);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"-hx"});
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), out.action_done.exit_code);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{"-hh=1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument -h/--help: ignored explicit argument '1'", out.usage_error.message);
    }
}

test "contract 4: double-dash termination at top level and subcommands" {
    const gpa = std.testing.allocator;

    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "--", "probe" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("probe", out.ok.subcommand_name.?);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "--", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings(
            "argument command: invalid choice: '-h' (choose from 'probe', 'resolve', 'status', 'run')",
            out.usage_error.message,
        );
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "resolve", "--", "--" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("--", out.ok.subcommand().?.positional(0).?);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "status", "--state-root", "/sr", "--", "--" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("--", out.ok.subcommand().?.positional(0).?);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "resolve", "a", "b", "--" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: b --", out.usage_error.message);
    }
}

test "contract 5: negative numbers as values and space-containing unknown dash tokens" {
    const gpa = std.testing.allocator;

    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "--path", "-1.5" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("-1.5", out.ok.subcommand().?.value("path").?);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "resolve", "--bogus=-a b" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("--bogus=-a b", out.ok.subcommand().?.positional(0).?);
    }
}

test "contract 7 and 8: argv-ordered leftovers, remainder unknowns, and exit-2 usage stderr" {
    const gpa = std.testing.allocator;

    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "probe", "pos1", "--bogus", "pos2" });
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 2), out.usage_error.exit_code);
        try std.testing.expectEqualStrings("unrecognized arguments: pos1 --bogus pos2", out.usage_error.message);
        const full = try out.usage_error.formatStderr(gpa);
        defer gpa.free(full);
        try std.testing.expect(std.mem.startsWith(u8, full, top_spec.usage));
        try std.testing.expect(std.mem.endsWith(u8, full, "demo: error: unrecognized arguments: pos1 --bogus pos2\n"));
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "run", "--foo", "--bar", "--", "a.eb" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --foo --bar", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "--bogus", "run", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), out.action_done.exit_code);
        try std.testing.expectEqualStrings(run_spec.help, out.action_done.stdout_text);
    }
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "run", "--module", "m1", "--module=m2", "--", "a.eb", "--force" });
        defer out.deinit(gpa);
        const sub = out.ok.subcommand().?;
        try std.testing.expectEqual(@as(usize, 2), sub.values("module").len);
        try std.testing.expectEqualStrings("m1", sub.values("module")[0]);
        try std.testing.expectEqualStrings("m2", sub.values("module")[1]);
        try std.testing.expectEqual(@as(usize, 3), sub.remainder.len);
        try std.testing.expectEqualStrings("--", sub.remainder[0]);
        try std.testing.expectEqualStrings("a.eb", sub.remainder[1]);
    }
}

const prolog_spec: argparse.CommandSpec = .{
    .prog = "eessi-arch-guard",
    .usage = "usage: eessi-arch-guard [--shell] [--timeout SEC]\n",
    .help = "usage: eessi-arch-guard [--shell] [--timeout SEC]\n",
    .version = "0.2.0\n",
    .policy = .prolog_lenient,
    .options = &.{
        .{ .name = "shell", .kind = .flag },
        .{ .name = "strict", .kind = .flag },
        .{ .name = "timeout", .kind = .optional_value },
        .{ .name = "chain", .kind = .optional_value },
    },
};

test "contract 8 (prolog_lenient): exact names, optional_value, -- ignored, deferred help/version, never exit-2" {
    const gpa = std.testing.allocator;

    // Abbreviations and unknown flags are silently ignored; -- does not terminate scanning
    {
        var out = try argparse.parse(gpa, &prolog_spec, &.{ "--sh", "--bogus", "--", "--shell", "--shell=1", "-hh", "-h", "--version" });
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("shell"));
        try std.testing.expect(!out.ok.seen("strict"));
        try std.testing.expect(out.ok.help_requested);
        try std.testing.expect(out.ok.version_requested);
    }
    // optional_value yields "" when absent or followed by any '-' token (even -5), while --timeout=-5 binds "-5"
    {
        var out = try argparse.parse(gpa, &prolog_spec, &.{ "--timeout", "-5", "--chain" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("", out.ok.value("timeout").?);
        try std.testing.expectEqualStrings("", out.ok.value("chain").?);
    }
    {
        var out = try argparse.parse(gpa, &prolog_spec, &.{ "--timeout=-5", "--chain", "/etc/prolog" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("-5", out.ok.value("timeout").?);
        try std.testing.expectEqualStrings("/etc/prolog", out.ok.value("chain").?);
    }
    // Malformed / non-UTF-8 / ambiguous tokens never trigger usage_error under prolog_lenient
    {
        const nasty = [_][]const u8{ "--=", "--=foo", "--help=1", "--version=bad", "-h=1", "\xff\xfe", "--timeout", "--strict" };
        var out = try argparse.parse(gpa, &prolog_spec, &nasty);
        defer out.deinit(gpa);
        try std.testing.expect(out == .ok);
        try std.testing.expect(out.ok.seen("strict"));
        try std.testing.expectEqualStrings("", out.ok.value("timeout").?);
    }
}
