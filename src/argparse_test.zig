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

const validated_spec: argparse.CommandSpec = .{
    .prog = "tool",
    .usage = "usage: tool [-h] [--state-root DIR] [-f FLOAT] [--grace-hours H] [--min-free-bytes N] [--backend {auto,squashfs,none}] [--tag TAG] [mode]\n",
    .help = "usage: tool\n",
    .options = &.{
        .{ .name = "state-root", .kind = .value, .required = true },
        .{ .name = "lock-timeout", .short = 'f', .kind = .value, .validate = argparse.types.pyFloat },
        .{ .name = "grace-hours", .kind = .value, .validate = argparse.types.nonNegativeFiniteFloat },
        .{ .name = "min-free-bytes", .kind = .value, .validate = argparse.types.boundedU64 },
        .{ .name = "backend", .kind = .value, .choices = &.{ "auto", "squashfs", "none" } },
        .{ .name = "color", .kind = .value, .validate = argparse.types.choice(&.{ "red", "blue" }) },
        .{ .name = "tag", .kind = .append, .validate = argparse.types.nonNegativeU128 },
    },
    .positionals = &.{
        .{ .name = "mode", .arity = .optional_one, .choices = &.{ "fast", "safe" } },
    },
};

test "contract 6: repeated flags, append order, and eager typed/choice validation" {
    const gpa = std.testing.allocator;

    // Repeated single-value keeps last; append keeps all in order.
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{
            "--state-root",     "/a",
            "--state-root",     "/b",
            "--lock-timeout",   "1_0.5",
            "-f",               " 2.5 ",
            "--grace-hours",    "0",
            "--min-free-bytes", "-0",
            "--backend",        "auto",
            "--color",          "red",
            "--tag",            "10",
            "--tag",            "20",
            "fast",
        });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("/b", out.ok.value("state-root").?);
        try std.testing.expectEqualStrings(" 2.5 ", out.ok.value("lock-timeout").?);
        try std.testing.expectEqual(@as(usize, 2), out.ok.values("tag").len);
        try std.testing.expectEqualStrings("10", out.ok.values("tag")[0]);
        try std.testing.expectEqualStrings("20", out.ok.values("tag")[1]);
        try std.testing.expectEqualStrings("fast", out.ok.positional(0).?);
    }

    // Eager validation fires on the first bad occurrence even when a later valid
    // occurrence, a missing required option, or a trailing -h follows.
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "--lock-timeout", "bad", "--lock-timeout", "2.0" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument -f/--lock-timeout: invalid float value: 'bad'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "-fbad", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument -f/--lock-timeout: invalid float value: 'bad'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "--backend", "bogus", "--backend", "auto" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --backend: invalid choice: 'bogus' (choose from 'auto', 'squashfs', 'none')", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "--color", "green", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --color: invalid choice: 'green' (choose from 'red', 'blue')", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "--grace-hours", "-1", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --grace-hours: must be a finite number >= 0: '-1'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{"--grace-hours=nan"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --grace-hours: must be a finite number >= 0: 'nan'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{"--min-free-bytes=-1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --min-free-bytes: must be >= 0: '-1'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{"--min-free-bytes=18446744073709551616"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --min-free-bytes: integer out of range: '18446744073709551616'", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "badmode", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument mode: invalid choice: 'badmode' (choose from 'fast', 'safe')", out.usage_error.message);
    }
    // Short -h before bad option in same cluster triggers help first (matching Python 3.14).
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{"-hfbad"});
        defer out.deinit(gpa);
        try std.testing.expect(out == .action_done);
        try std.testing.expectEqual(@as(u8, 0), out.action_done.exit_code);
    }
}

test "types.parsePyFloat and types.parseNonNegativeU128 edge cases" {
    try std.testing.expectEqual(@as(?f64, 10.5), argparse.types.parsePyFloat("1_0.5"));
    try std.testing.expectEqual(@as(?f64, 0.5), argparse.types.parsePyFloat(" .5\u{00a0}"));
    try std.testing.expectEqual(@as(?f64, 5.0), argparse.types.parsePyFloat("5."));
    try std.testing.expect(std.math.isPositiveInf(argparse.types.parsePyFloat("+Infinity").?));
    try std.testing.expect(std.math.isNegativeInf(argparse.types.parsePyFloat("-inf").?));
    try std.testing.expect(std.math.isNan(argparse.types.parsePyFloat("-NaN").?));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("0x1"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("1__0"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("_1"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("1_"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("1_.2"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("1._2"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("1e_2"));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat("."));
    try std.testing.expectEqual(@as(?f64, null), argparse.types.parsePyFloat(""));

    try std.testing.expectEqual(@as(u128, 0), try argparse.types.parseNonNegativeU128("-0"));
    try std.testing.expectEqual(@as(u128, 1000), try argparse.types.parseNonNegativeU128(" +1_000 "));
    try std.testing.expectError(error.BelowZero, argparse.types.parseNonNegativeU128("-1"));
    try std.testing.expectError(error.NotAnInteger, argparse.types.parseNonNegativeU128("1__0"));
    try std.testing.expectError(error.NotAnInteger, argparse.types.parseNonNegativeU128("abc"));
}

test "differential regressions: registered short option with spaces and non-adjacent -- separator" {
    const gpa = std.testing.allocator;

    // When -f is registered, "-foo bar" is classified as an option token (matching -f),
    // so a preceding value option rejects it with "expected one argument", while
    // "-zoo bar" (unregistered -z, contains space) is accepted as a value.
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "--state-root", "-foo bar" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --state-root: expected one argument", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &validated_spec, &.{ "--state-root", "-zoo bar" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("-zoo bar", out.ok.value("state-root").?);
    }

    // When an option intervenes between a consumed positional and "--", the separator
    // is not adjacent to the positional action and remains in unrecognized arguments.
    {
        var out = try argparse.parse(gpa, &top_spec, &.{ "status", "--state-root", "/s", "run1", "--json", "--", "--" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: -- --", out.usage_error.message);
    }
}

test "variadic positional arities zero_or_more and one_or_more" {
    const gpa = std.testing.allocator;

    const star_spec: argparse.CommandSpec = .{
        .prog = "star",
        .usage = "usage: star [--json] [files ...]\n",
        .help = "usage: star\n",
        .options = &.{.{ .name = "json", .kind = .flag }},
        .positionals = &.{.{ .name = "files", .arity = .zero_or_more }},
    };
    const plus_spec: argparse.CommandSpec = .{
        .prog = "plus",
        .usage = "usage: plus [--json] first rest...\n",
        .help = "usage: plus\n",
        .options = &.{.{ .name = "json", .kind = .flag }},
        .positionals = &.{
            .{ .name = "first", .arity = .required_one },
            .{ .name = "rest", .arity = .one_or_more, .choices = &.{ "a", "b", "c" } },
        },
    };

    // zero_or_more accepts zero, one, or many intermixed with flags and --
    {
        var out = try argparse.parse(gpa, &star_spec, &.{});
        defer out.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), out.ok.positionals.len);
    }
    {
        var out = try argparse.parse(gpa, &star_spec, &.{ "f1", "--json", "f2", "--", "--flag" });
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("json"));
        try std.testing.expectEqual(@as(usize, 3), out.ok.positionals.len);
        try std.testing.expectEqualStrings("f1", out.ok.positionals[0]);
        try std.testing.expectEqualStrings("f2", out.ok.positionals[1]);
        try std.testing.expectEqualStrings("--flag", out.ok.positionals[2]);
    }
    {
        var out = try argparse.parse(gpa, &star_spec, &.{ "f1", "--json", "--" });
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("json"));
        try std.testing.expectEqual(@as(usize, 1), out.ok.positionals.len);
        try std.testing.expectEqualStrings("f1", out.ok.positionals[0]);
    }

    // required_one + one_or_more requires at least two positionals and validates choices on all variadic slots
    {
        var out = try argparse.parse(gpa, &plus_spec, &.{});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("the following arguments are required: first, rest", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &plus_spec, &.{"x"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("the following arguments are required: rest", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &plus_spec, &.{ "x", "a", "--json", "c" });
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("json"));
        try std.testing.expectEqual(@as(usize, 3), out.ok.positionals.len);
        try std.testing.expectEqualStrings("x", out.ok.positionals[0]);
        try std.testing.expectEqualStrings("a", out.ok.positionals[1]);
        try std.testing.expectEqualStrings("c", out.ok.positionals[2]);
    }
    {
        var out = try argparse.parse(gpa, &plus_spec, &.{ "x", "a", "bad" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument rest: invalid choice: 'bad' (choose from 'a', 'b', 'c')", out.usage_error.message);
    }
}

test "UnknownMode.positional routes unknown dash tokens to positionals and rejects overflow" {
    const gpa = std.testing.allocator;

    const failed_spec: argparse.CommandSpec = .{
        .prog = "tool failed",
        .usage = "usage: tool failed [--syslog TARGET] STATUS NAME LOGDIR [TMP]\n",
        .help = "usage: tool failed\n",
        .add_help = false,
        .policy = .{
            .allow_abbrev = false,
            .unknown = .positional,
            .double_dash = .ignore,
            .negative_numbers = .never,
            .short_clusters = false,
        },
        .options = &.{
            .{ .name = "syslog", .kind = .value },
        },
        .positionals = &.{
            .{ .name = "STATUS", .arity = .required_one },
            .{ .name = "NAME", .arity = .required_one },
            .{ .name = "LOGDIR", .arity = .required_one },
            .{ .name = "TMP", .arity = .optional_one },
        },
    };

    // Unknown dash tokens like -1 and --bogus become positionals.
    {
        var out = try argparse.parse(gpa, &failed_spec, &.{ "-1", "Foo", "--bogus", "--syslog", "udp://127.0.0.1:514" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("udp://127.0.0.1:514", out.ok.value("syslog").?);
        try std.testing.expectEqual(@as(usize, 3), out.ok.positionals.len);
        try std.testing.expectEqualStrings("-1", out.ok.positionals[0]);
        try std.testing.expectEqualStrings("Foo", out.ok.positionals[1]);
        try std.testing.expectEqualStrings("--bogus", out.ok.positionals[2]);
    }
    // Positionals beyond the four declared slots are still rejected.
    {
        var out = try argparse.parse(gpa, &failed_spec, &.{ "1", "Foo", "dir", "tmp", "--extra" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --extra", out.usage_error.message);
    }
}

test "argparse: PositionalSpec.ignore_empty skips empty tokens only while slot is unfilled" {
    const gpa = std.testing.allocator;
    const spec: argparse.CommandSpec = .{
        .prog = "tool",
        .usage = "usage: tool FILE\n",
        .help = "usage: tool FILE\n",
        .add_help = false,
        .positionals = &.{
            .{ .name = "FILE", .arity = .required_one, .ignore_empty = true },
        },
    };
    {
        var out = try argparse.parse(gpa, &spec, &.{ "", "a.log" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("a.log", out.ok.positional(0).?);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{""});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("the following arguments are required: FILE", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{ "a.log", "" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: ", out.usage_error.message);
    }
}

test "Policy.native_exact, NegativeNumberMode.any, and allow_empty/allow_dash_value" {
    const gpa = std.testing.allocator;

    try std.testing.expect(argparse.optionLike("-", .any));
    try std.testing.expect(argparse.optionLike("-5", .any));
    try std.testing.expect(!argparse.optionLike("5", .any));

    const rotate_spec: argparse.CommandSpec = .{
        .prog = "tool rotate",
        .usage = "usage: tool rotate\n",
        .help = "usage: tool rotate\n",
        .add_help = false,
        .policy = .native_exact,
        .options = &.{
            .{ .name = "dry-run", .kind = .flag },
            .{ .name = "compress-after", .kind = .value },
            .{ .name = "target", .kind = .value, .allow_empty = false },
            .{ .name = "module", .kind = .value, .allow_empty = false, .allow_dash_value = false },
        },
        .positionals = &.{.{ .name = "ROOT", .arity = .required_one }},
    };

    // NegativeNumberMode.any consumes any next token for value options (even -5 or --foo)
    // and allow_empty=true allows empty --compress-after=.
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--compress-after", "-5", "--target", "-x", "logs" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("-5", out.ok.value("compress-after").?);
        try std.testing.expectEqualStrings("-x", out.ok.value("target").?);
        try std.testing.expectEqualStrings("logs", out.ok.positional(0).?);
    }
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--compress-after=", "logs" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("", out.ok.value("compress-after").?);
    }

    // allow_empty=false rejects --target= and --target "" as missing value.
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--target=", "logs" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --target: expected one argument", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--target", "", "logs" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --target: expected one argument", out.usage_error.message);
    }

    // allow_dash_value=false rejects both --module -x and --module=-x as missing value.
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--module", "-x", "logs" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --module: expected one argument", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--module=-x", "logs" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --module: expected one argument", out.usage_error.message);
    }

    // flag_explicit_as_unknown treats --dry-run=1 (even with spaces) as unknown option,
    // and fail_fast / unknown_before_required report it before later errors or missing ROOT.
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{"--dry-run=1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --dry-run=1", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{"--dry-run=a b"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --dry-run=a b", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "--bogus", "--target" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --bogus", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{ "logs", "extra", "--target" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: extra", out.usage_error.message);
    }
    // Missing required ROOT is reported when no unknown tokens are present.
    {
        var out = try argparse.parse(gpa, &rotate_spec, &.{"--dry-run"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("the following arguments are required: ROOT", out.usage_error.message);
    }
    // With fail_fast and immediate_exit, --bogus fails before --help; with prescan, --help wins.
    const help_native: argparse.CommandSpec = .{
        .prog = "tool why",
        .usage = "usage: tool why\n",
        .help = "why help\n",
        .version = "1.0\n",
        .policy = .native_exact,
        .positionals = &.{.{ .name = "RUN", .arity = .required_one }},
    };
    {
        var out = try argparse.parse(gpa, &help_native, &.{ "--bogus", "--help" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --bogus", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &help_native, &.{"--help=1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --help=1", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &help_native, &.{"--version=1"});
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --version=1", out.usage_error.message);
    }
}

test "argparse: SpecialActionMode.prescan handles help and version before option errors" {
    const gpa = std.testing.allocator;
    var prescan_pol = argparse.Policy.native_exact;
    prescan_pol.special_action = .prescan;
    const spec: argparse.CommandSpec = .{
        .prog = "tool why",
        .usage = "usage: tool why\n",
        .help = "why help\n",
        .version = "1.2.3\n",
        .policy = prescan_pol,
        .options = &.{.{ .name = "target", .kind = .value }},
        .positionals = &.{.{ .name = "RUN", .arity = .required_one }},
    };
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--bogus", "-h" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("why help\n", out.action_done.stdout_text);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--target", "--help" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("why help\n", out.action_done.stdout_text);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--bogus", "--version" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("1.2.3\n", out.action_done.stdout_text);
    }
}

test "argparse: mutually_exclusive rejects conflicting options in scan order" {
    const gpa = std.testing.allocator;
    const spec: argparse.CommandSpec = .{
        .prog = "tool usage",
        .usage = "usage: tool usage\n",
        .help = "usage help\n",
        .add_help = false,
        .policy = .native_exact,
        .options = &.{
            .{ .name = "unused", .kind = .flag },
            .{ .name = "active", .kind = .flag },
            .{ .name = "json", .kind = .flag },
        },
        .mutually_exclusive = &.{.{ .options = &.{ "unused", "active" } }},
        .positionals = &.{.{ .name = "FILE", .arity = .one_or_more }},
    };
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--unused", "--active", "--bogus" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --active: not allowed with argument --unused", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--active", "--unused", "a.log" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("argument --unused: not allowed with argument --active", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--bogus", "--unused", "--active" });
        defer out.deinit(gpa);
        try std.testing.expectEqualStrings("unrecognized arguments: --bogus", out.usage_error.message);
    }
    {
        var out = try argparse.parse(gpa, &spec, &.{ "--unused", "--json", "a.log" });
        defer out.deinit(gpa);
        try std.testing.expect(out.ok.seen("unused"));
        try std.testing.expect(!out.ok.seen("active"));
        try std.testing.expect(out.ok.seen("json"));
    }
}
