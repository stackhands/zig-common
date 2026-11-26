//! Argparse differential parity probe.
//!
//! Invoked by `tests/test_argparse_parity.py` in two modes:
//! 1. Stdin batch mode (no arguments): reads lines `<mode>\t<hex_tok0> <hex_tok1> ...`
//!    where `<mode>` is `py314` or `prolog`, runs `argparse.parse`, and emits one
//!    JSON object per line describing the exact `ParseOutcome`.
//! 2. `--exec <argv...>`: runs `argparse.parseOrExit` directly on `<argv...>`
//!    against the `py314` command spec so the harness can verify real OS exit
//!    codes (0 and 2) as well as stdout and stderr bytes.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const argparse = common.argparse;
const cli = common.cli;

const probe_cmd: argparse.CommandSpec = .{
    .prog = "tool probe",
    .usage =
    \\usage: tool probe [-h] [-a] [-b] [-o OUT] [-f FLOAT]
    \\                  [--backend {auto,squashfs,none}] [--tag TAG]
    \\
    ,
    .help =
    \\usage: tool probe [-h] [-a] [-b] [-o OUT] [-f FLOAT]
    \\                  [--backend {auto,squashfs,none}] [--tag TAG]
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  -a, --alpha
    \\  -b, --beta
    \\  -o, --out OUT
    \\  -f, --float FLOAT
    \\  --backend {auto,squashfs,none}
    \\  --tag TAG
    \\
    ,
    .options = &.{
        .{ .name = "alpha", .short = 'a', .kind = .flag },
        .{ .name = "beta", .short = 'b', .kind = .flag },
        .{ .name = "out", .short = 'o', .kind = .value },
        .{ .name = "float", .short = 'f', .kind = .value, .validate = argparse.types.pyFloat },
        .{ .name = "backend", .kind = .value, .choices = &.{ "auto", "squashfs", "none" } },
        .{ .name = "tag", .kind = .append },
    },
};

const status_cmd: argparse.CommandSpec = .{
    .prog = "tool status",
    .usage = "usage: tool status [-h] [--json] --state-root STATE_ROOT [target]\n",
    .help =
    \\usage: tool status [-h] [--json] --state-root STATE_ROOT [target]
    \\
    \\positional arguments:
    \\  target
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --json
    \\  --state-root STATE_ROOT
    \\
    ,
    .options = &.{
        .{ .name = "json", .kind = .flag },
        .{ .name = "state-root", .kind = .value, .required = true },
    },
    .positionals = &.{
        .{ .name = "target", .arity = .optional_one },
    },
};

const resolve_cmd: argparse.CommandSpec = .{
    .prog = "tool resolve",
    .usage = "usage: tool resolve [-h] [--json] [--mode {fast,safe}] spec\n",
    .help =
    \\usage: tool resolve [-h] [--json] [--mode {fast,safe}] spec
    \\
    \\positional arguments:
    \\  spec
    \\
    \\options:
    \\  -h, --help          show this help message and exit
    \\  --json
    \\  --mode {fast,safe}
    \\
    ,
    .options = &.{
        .{ .name = "json", .kind = .flag },
        .{ .name = "mode", .kind = .value, .choices = &.{ "fast", "safe" } },
    },
    .positionals = &.{
        .{ .name = "spec", .arity = .required_one },
    },
};

const run_cmd: argparse.CommandSpec = .{
    .prog = "tool run",
    .usage =
    \\usage: tool run [-h] --state-root STATE_ROOT [--lock-timeout LOCK_TIMEOUT]
    \\                [--dry-run] [--eb-keep-logs] [--eb EB]
    \\                ...
    \\
    ,
    .help =
    \\usage: tool run [-h] --state-root STATE_ROOT [--lock-timeout LOCK_TIMEOUT]
    \\                [--dry-run] [--eb-keep-logs] [--eb EB]
    \\                ...
    \\
    \\positional arguments:
    \\  eb_args
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --state-root STATE_ROOT
    \\  --lock-timeout LOCK_TIMEOUT
    \\  --dry-run
    \\  --eb-keep-logs
    \\  --eb EB
    \\
    ,
    .options = &.{
        .{ .name = "state-root", .kind = .value, .required = true },
        .{ .name = "lock-timeout", .kind = .value, .validate = argparse.types.pyFloat },
        .{ .name = "dry-run", .kind = .flag },
        .{ .name = "eb-keep-logs", .kind = .flag },
        .{ .name = "eb", .kind = .value },
    },
    .positionals = &.{
        .{ .name = "eb_args", .arity = .remainder },
    },
};

const py314_spec: argparse.CommandSpec = .{
    .prog = "tool",
    .usage =
    \\usage: tool [-h] [--version] [-v] [--state-root STATE_ROOT] [--config CONFIG]
    \\            {probe,status,resolve,run} ...
    \\
    ,
    .help =
    \\usage: tool [-h] [--version] [-v] [--state-root STATE_ROOT] [--config CONFIG]
    \\            {probe,status,resolve,run} ...
    \\
    \\positional arguments:
    \\  {probe,status,resolve,run}
    \\
    \\options:
    \\  -h, --help            show this help message and exit
    \\  --version             show program's version number and exit
    \\  -v, --verbose
    \\  --state-root STATE_ROOT
    \\  --config CONFIG
    \\
    ,
    .version = "tool 1.0\n",
    .options = &.{
        .{ .name = "verbose", .short = 'v', .kind = .flag },
        .{ .name = "state-root", .kind = .value },
        .{ .name = "config", .kind = .value },
    },
    .subcommands = &.{
        .{ .name = "probe", .command = &probe_cmd },
        .{ .name = "status", .command = &status_cmd },
        .{ .name = "resolve", .command = &resolve_cmd },
        .{ .name = "run", .command = &run_cmd },
    },
};

const prolog_spec: argparse.CommandSpec = .{
    .prog = "prolog-tool",
    .usage = "usage: prolog-tool\n",
    .help = "prolog help\n",
    .version = "0.2.0\n",
    .policy = .prolog_lenient,
    .options = &.{
        .{ .name = "shell", .kind = .flag },
        .{ .name = "strict", .kind = .flag },
        .{ .name = "timeout", .kind = .optional_value },
        .{ .name = "chain", .kind = .optional_value },
    },
};

const intermixed_spec: argparse.CommandSpec = .{
    .prog = "imix",
    .usage = "usage: imix [-h] [--json] [--prefix PREFIX] first files [files ...]\n",
    .help =
    \\usage: imix [-h] [--json] [--prefix PREFIX] first files [files ...]
    \\
    \\positional arguments:
    \\  first
    \\  files
    \\
    \\options:
    \\  -h, --help       show this help message and exit
    \\  --json
    \\  --prefix PREFIX
    \\
    ,
    .options = &.{
        .{ .name = "json", .kind = .flag },
        .{ .name = "prefix", .kind = .value },
    },
    .positionals = &.{
        .{ .name = "first", .arity = .required_one },
        .{ .name = "files", .arity = .one_or_more },
    },
};

const native_rotate_spec: argparse.CommandSpec = .{
    .prog = "native rotate",
    .usage = "usage: native rotate\n",
    .help = "usage: native rotate\n",
    .add_help = false,
    .policy = .native_exact,
    .options = &.{
        .{ .name = "dry-run", .kind = .flag },
        .{ .name = "compress-after", .kind = .value },
        .{ .name = "target", .kind = .value, .allow_empty = false },
        .{ .name = "module", .kind = .value, .allow_empty = false, .allow_dash_value = false },
    },
    .positionals = &.{
        .{ .name = "ROOT", .arity = .required_one },
    },
};

const native_failed_spec: argparse.CommandSpec = .{
    .prog = "native failed",
    .usage = "usage: native failed\n",
    .help = "usage: native failed\n",
    .add_help = false,
    .policy = .{
        .allow_abbrev = false,
        .unknown = .positional,
        .double_dash = .ignore,
        .negative_numbers = .any,
        .short_clusters = false,
        .special_action = .immediate_exit,
        .flag_explicit_as_unknown = true,
        .unknown_before_required = true,
        .fail_fast = true,
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

const native_used_spec: argparse.CommandSpec = .{
    .prog = "native used",
    .usage = "usage: native used\n",
    .help = "usage: native used\n",
    .add_help = false,
    .policy = .native_exact,
    .options = &.{
        .{ .name = "json", .kind = .flag },
        .{ .name = "prefix", .kind = .value, .required = true, .allow_empty = false, .allow_dash_value = false },
    },
    .positionals = &.{
        .{ .name = "FILE", .arity = .one_or_more },
    },
};

const native_prescan_spec: argparse.CommandSpec = .{
    .prog = "native prescan",
    .usage = "usage: native prescan\n",
    .help = "prescan help\n",
    .version = "prescan 1.0\n",
    .add_help = true,
    .policy = .{
        .allow_abbrev = false,
        .unknown = .collect,
        .double_dash = .ignore,
        .negative_numbers = .any,
        .short_clusters = false,
        .special_action = .prescan,
        .flag_explicit_as_unknown = true,
        .unknown_before_required = true,
        .fail_fast = true,
    },
    .options = &.{
        .{ .name = "format", .kind = .value, .allow_empty = false },
    },
    .positionals = &.{
        .{ .name = "RUN", .arity = .required_one, .ignore_empty = true },
    },
};

const native_mutex_spec: argparse.CommandSpec = .{
    .prog = "native mutex",
    .usage = "usage: native mutex\n",
    .help = "usage: native mutex\n",
    .add_help = false,
    .policy = .native_exact,
    .options = &.{
        .{ .name = "unused", .kind = .flag },
        .{ .name = "active", .kind = .flag },
        .{ .name = "json", .kind = .flag },
    },
    .mutually_exclusive = &.{.{ .options = &.{ "unused", "active" } }},
    .positionals = &.{
        .{ .name = "FILE", .arity = .one_or_more },
    },
};

const native_spec: argparse.CommandSpec = .{
    .prog = "native",
    .usage = "usage: native\n",
    .help = "native help\n",
    .version = "native 1.0\n",
    .policy = .native_exact,
    .subcommands = &.{
        .{ .name = "rotate", .command = &native_rotate_spec },
        .{ .name = "failed", .command = &native_failed_spec },
        .{ .name = "used", .command = &native_used_spec },
        .{ .name = "prescan", .command = &native_prescan_spec },
        .{ .name = "mutex", .command = &native_mutex_spec },
    },
};

fn appendHex(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    const digits = "0123456789abcdef";
    try out.append(gpa, '"');
    for (bytes) |b| {
        try out.append(gpa, digits[b >> 4]);
        try out.append(gpa, digits[b & 15]);
    }
    try out.append(gpa, '"');
}

fn appendOptHex(out: *std.ArrayList(u8), gpa: std.mem.Allocator, val: ?[]const u8) !void {
    if (val) |v| {
        try appendHex(out, gpa, v);
    } else {
        try out.appendSlice(gpa, "null");
    }
}

fn appendHexList(out: *std.ArrayList(u8), gpa: std.mem.Allocator, items: []const []const u8) !void {
    try out.append(gpa, '[');
    for (items, 0..) |it, idx| {
        if (idx > 0) try out.append(gpa, ',');
        try appendHex(out, gpa, it);
    }
    try out.append(gpa, ']');
}

fn decodeHex(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const buf = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(buf);
    for (0..buf.len) |i| {
        buf[i] = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return buf;
}

fn formatParsedPy314(out: *std.ArrayList(u8), gpa: std.mem.Allocator, p: *const argparse.Parsed) !void {
    const sub_name = p.subcommand_name orelse "";
    const sub = p.subcommand().?;
    try out.print(gpa, "{{\"kind\":\"ok\",\"command\":\"{s}\",\"verbose\":{s},\"top_state_root\":", .{
        sub_name,
        if (p.seen("verbose")) "true" else "false",
    });
    try appendOptHex(out, gpa, p.value("state-root"));
    try out.appendSlice(gpa, ",\"config\":");
    try appendOptHex(out, gpa, p.value("config"));

    if (std.mem.eql(u8, sub_name, "probe")) {
        try out.print(gpa, ",\"alpha\":{s},\"beta\":{s},\"out\":", .{
            if (sub.seen("alpha")) "true" else "false",
            if (sub.seen("beta")) "true" else "false",
        });
        try appendOptHex(out, gpa, sub.value("out"));
        try out.appendSlice(gpa, ",\"float\":");
        try appendOptHex(out, gpa, sub.value("float"));
        try out.appendSlice(gpa, ",\"backend\":");
        try appendOptHex(out, gpa, sub.value("backend"));
        try out.appendSlice(gpa, ",\"tag\":");
        try appendHexList(out, gpa, sub.values("tag"));
    } else if (std.mem.eql(u8, sub_name, "status")) {
        try out.print(gpa, ",\"json\":{s},\"state_root\":", .{if (sub.seen("json")) "true" else "false"});
        try appendOptHex(out, gpa, sub.value("state-root"));
        try out.appendSlice(gpa, ",\"target\":");
        try appendOptHex(out, gpa, sub.positional(0));
    } else if (std.mem.eql(u8, sub_name, "resolve")) {
        try out.print(gpa, ",\"json\":{s},\"mode\":", .{if (sub.seen("json")) "true" else "false"});
        try appendOptHex(out, gpa, sub.value("mode"));
        try out.appendSlice(gpa, ",\"spec\":");
        try appendOptHex(out, gpa, sub.positional(0));
    } else if (std.mem.eql(u8, sub_name, "run")) {
        try out.appendSlice(gpa, ",\"state_root\":");
        try appendOptHex(out, gpa, sub.value("state-root"));
        try out.appendSlice(gpa, ",\"lock_timeout\":");
        try appendOptHex(out, gpa, sub.value("lock-timeout"));
        try out.print(gpa, ",\"dry_run\":{s},\"eb_keep_logs\":{s},\"eb\":", .{
            if (sub.seen("dry-run")) "true" else "false",
            if (sub.seen("eb-keep-logs")) "true" else "false",
        });
        try appendOptHex(out, gpa, sub.value("eb"));
        try out.appendSlice(gpa, ",\"eb_args\":");
        try appendHexList(out, gpa, sub.remainder);
    }
    try out.appendSlice(gpa, "}\n");
}

fn formatParsedProlog(out: *std.ArrayList(u8), gpa: std.mem.Allocator, p: *const argparse.Parsed) !void {
    try out.print(gpa, "{{\"kind\":\"ok\",\"shell\":{s},\"strict\":{s},\"help\":{s},\"version\":{s},\"timeout\":", .{
        if (p.seen("shell")) "true" else "false",
        if (p.seen("strict")) "true" else "false",
        if (p.help_requested) "true" else "false",
        if (p.version_requested) "true" else "false",
    });
    try appendOptHex(out, gpa, p.value("timeout"));
    try out.appendSlice(gpa, ",\"chain\":");
    try appendOptHex(out, gpa, p.value("chain"));
    try out.appendSlice(gpa, "}\n");
}

fn formatParsedIntermixed(out: *std.ArrayList(u8), gpa: std.mem.Allocator, p: *const argparse.Parsed) !void {
    try out.print(gpa, "{{\"kind\":\"ok\",\"json\":{s},\"prefix\":", .{if (p.seen("json")) "true" else "false"});
    try appendOptHex(out, gpa, p.value("prefix"));
    try out.appendSlice(gpa, ",\"first\":");
    try appendOptHex(out, gpa, p.positional(0));
    try out.appendSlice(gpa, ",\"files\":");
    const rest: []const []const u8 = if (p.positionals.len > 1) p.positionals[1..] else &.{};
    try appendHexList(out, gpa, rest);
    try out.appendSlice(gpa, "}\n");
}

fn formatParsedNative(out: *std.ArrayList(u8), gpa: std.mem.Allocator, p: *const argparse.Parsed) !void {
    const sub_name = p.subcommand_name orelse "";
    const sub = p.subcommand().?;
    try out.print(gpa, "{{\"kind\":\"ok\",\"command\":\"{s}\"", .{sub_name});
    if (std.mem.eql(u8, sub_name, "rotate")) {
        try out.print(gpa, ",\"dry_run\":{s},\"compress_after\":", .{if (sub.seen("dry-run")) "true" else "false"});
        try appendOptHex(out, gpa, sub.value("compress-after"));
        try out.appendSlice(gpa, ",\"target\":");
        try appendOptHex(out, gpa, sub.value("target"));
        try out.appendSlice(gpa, ",\"module\":");
        try appendOptHex(out, gpa, sub.value("module"));
        try out.appendSlice(gpa, ",\"root\":");
        try appendOptHex(out, gpa, sub.positional(0));
    } else if (std.mem.eql(u8, sub_name, "failed")) {
        try out.appendSlice(gpa, ",\"syslog\":");
        try appendOptHex(out, gpa, sub.value("syslog"));
        try out.appendSlice(gpa, ",\"pos\":");
        try appendHexList(out, gpa, sub.positionals);
    } else if (std.mem.eql(u8, sub_name, "used")) {
        try out.print(gpa, ",\"json\":{s},\"prefix\":", .{if (sub.seen("json")) "true" else "false"});
        try appendOptHex(out, gpa, sub.value("prefix"));
        try out.appendSlice(gpa, ",\"files\":");
        try appendHexList(out, gpa, sub.positionals);
    } else if (std.mem.eql(u8, sub_name, "prescan")) {
        try out.appendSlice(gpa, ",\"format\":");
        try appendOptHex(out, gpa, sub.value("format"));
        try out.appendSlice(gpa, ",\"run\":");
        try appendOptHex(out, gpa, sub.positional(0));
    } else if (std.mem.eql(u8, sub_name, "mutex")) {
        try out.print(gpa, ",\"unused\":{s},\"active\":{s},\"json\":{s},\"files\":", .{
            if (sub.seen("unused")) "true" else "false",
            if (sub.seen("active")) "true" else "false",
            if (sub.seen("json")) "true" else "false",
        });
        try appendHexList(out, gpa, sub.positionals);
    }
    try out.appendSlice(gpa, "}\n");
}

fn formatNativeError(out: *std.ArrayList(u8), gpa: std.mem.Allocator, uerr: *const argparse.UsageError) !void {
    try out.print(gpa, "{{\"kind\":\"usage_error\",\"exit_code\":{d},\"err_kind\":\"{s}\"", .{
        uerr.exit_code,
        @tagName(uerr.kind),
    });
    switch (uerr.kind) {
        .missing_subcommand => {},
        .unknown_subcommand,
        .unknown_option,
        .extra_positional,
        .missing_value,
        .ambiguous_option,
        .missing_required,
        => |tok| {
            try out.appendSlice(gpa, ",\"token\":");
            try appendHex(out, gpa, tok);
        },
        .unexpected_value => |uv| {
            try out.appendSlice(gpa, ",\"option\":");
            try appendHex(out, gpa, uv.option);
            try out.appendSlice(gpa, ",\"value\":");
            try appendHex(out, gpa, uv.value);
        },
        .invalid_value => |iv| {
            try out.appendSlice(gpa, ",\"name\":");
            try appendHex(out, gpa, iv.name);
            try out.appendSlice(gpa, ",\"value\":");
            try appendHex(out, gpa, iv.value);
        },
        .mutually_exclusive => |me| {
            try out.appendSlice(gpa, ",\"option\":");
            try appendHex(out, gpa, me.option);
            try out.appendSlice(gpa, ",\"conflict\":");
            try appendHex(out, gpa, me.conflict);
        },
    }
    try out.appendSlice(gpa, "}\n");
}

fn readAllStdin(gpa: std.mem.Allocator) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);
    var buf: [16384]u8 = undefined;
    while (true) {
        const rc = linux.read(0, &buf, buf.len);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            if (linux.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) break;
        try data.appendSlice(gpa, buf[0..rc]);
    }
    return data.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    if (raw_args.len >= 2 and std.mem.eql(u8, raw_args[1], "--exec")) {
        var parsed = argparse.parseOrExit(gpa, &py314_spec, raw_args[2..]);
        defer parsed.deinit(gpa);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try formatParsedPy314(&out, gpa, &parsed);
        cli.put(1, out.items);
        return;
    }

    const input = try readAllStdin(gpa);
    defer gpa.free(input);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab1 = std.mem.findScalar(u8, line, '\t') orelse return error.InvalidLine;
        const mode = line[0..tab1];
        const after1 = line[tab1 + 1 ..];
        const tab2 = std.mem.findScalar(u8, after1, '\t') orelse return error.InvalidLine;
        const count = try std.fmt.parseInt(usize, after1[0..tab2], 10);
        const rest = after1[tab2 + 1 ..];

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        var argv: std.ArrayList([]const u8) = .empty;
        if (count > 0) {
            var toks = std.mem.splitScalar(u8, rest, ' ');
            var seen: usize = 0;
            while (toks.next()) |tok| : (seen += 1) {
                const decoded = try decodeHex(aa, tok);
                try argv.append(aa, decoded);
            }
            if (seen != count) return error.InvalidLine;
        }

        const is_prolog = std.mem.eql(u8, mode, "prolog");
        const is_intermixed = std.mem.eql(u8, mode, "intermixed");
        const is_native = std.mem.eql(u8, mode, "native");
        const spec = if (is_prolog)
            &prolog_spec
        else if (is_intermixed)
            &intermixed_spec
        else if (is_native)
            &native_spec
        else
            &py314_spec;
        var outcome = try argparse.parse(gpa, spec, argv.items);
        defer outcome.deinit(gpa);

        switch (outcome) {
            .ok => |*p| {
                if (is_prolog) {
                    try formatParsedProlog(&out, gpa, p);
                } else if (is_intermixed) {
                    try formatParsedIntermixed(&out, gpa, p);
                } else if (is_native) {
                    try formatParsedNative(&out, gpa, p);
                } else {
                    try formatParsedPy314(&out, gpa, p);
                }
            },
            .action_done => |done| {
                try out.print(gpa, "{{\"kind\":\"action_done\",\"exit_code\":{d},\"stdout\":", .{done.exit_code});
                try appendHex(&out, gpa, done.stdout_text);
                try out.appendSlice(gpa, "}\n");
            },
            .usage_error => |*uerr| {
                if (is_native) {
                    try formatNativeError(&out, gpa, uerr);
                } else {
                    const stderr_txt = try uerr.formatStderr(gpa);
                    defer gpa.free(stderr_txt);
                    try out.print(gpa, "{{\"kind\":\"usage_error\",\"exit_code\":{d},\"stderr\":", .{uerr.exit_code});
                    try appendHex(&out, gpa, stderr_txt);
                    try out.appendSlice(gpa, "}\n");
                }
            },
        }
    }
    cli.put(1, out.items);
}
