//! Declarative Python 3.14 argparse-compatible argument parser with a
//! lenient policy preset for Slurm TaskProlog tools.
const std = @import("std");
const cli = @import("cli.zig");
const pytext = @import("pytext.zig");

const Allocator = std.mem.Allocator;

/// Output sink callback used by `parseOrExit` and tests.
pub const WriteFn = *const fn (bytes: []const u8) void;

fn defaultStdout(bytes: []const u8) void {
    cli.put(1, bytes);
}

fn defaultStderr(bytes: []const u8) void {
    cli.put(2, bytes);
}

/// How unknown options and extra positionals are handled.
pub const UnknownMode = enum {
    /// Accumulate unknown tokens in argv order and reject them after parsing.
    collect,
    /// Ignore unknown options and extra tokens without error.
    ignore,
};

/// How a bare `--` token is treated while scanning options.
pub const DoubleDashMode = enum {
    /// Terminate option scanning and treat every remaining token as positional.
    terminate,
    /// Treat `--` as an ordinary unknown token.
    ignore,
};

/// Which leading-dash tokens count as negative-number values instead of options.
pub const NegativeNumberMode = enum {
    /// Match Python 3.14 `_parse_optional`: `-DIGIT...`, `-.DIGIT...`, and
    /// dash tokens containing an ASCII space are non-options.
    py314,
    /// Every token starting with `-` is option-like (never consumed as a
    /// space-separated value).
    never,
};

/// How `-h`/`--help` and `--version` actions behave during parsing.
pub const SpecialActionMode = enum {
    /// Stop parsing immediately and return `ParseOutcome.action_done`.
    immediate_exit,
    /// Record `help_requested` / `version_requested` on `Parsed` and keep scanning.
    record,
};

/// Parser behaviour policy controlling strict Python 3.14 parity vs. lenient
/// TaskProlog parsing.
pub const Policy = struct {
    allow_abbrev: bool = true,
    unknown: UnknownMode = .collect,
    double_dash: DoubleDashMode = .terminate,
    negative_numbers: NegativeNumberMode = .py314,
    short_clusters: bool = true,
    special_action: SpecialActionMode = .immediate_exit,
    write_stdout: WriteFn = defaultStdout,
    write_stderr: WriteFn = defaultStderr,

    /// Strict Python 3.14 `argparse.ArgumentParser` behaviour.
    pub const python314: Policy = .{
        .allow_abbrev = true,
        .unknown = .collect,
        .double_dash = .terminate,
        .negative_numbers = .py314,
        .short_clusters = true,
        .special_action = .immediate_exit,
    };

    /// Lenient Slurm TaskProlog policy matching `eessi-arch-guard`'s `parse_args`:
    /// exact flag names only, unknown tokens ignored, `--` ignored, negative
    /// tokens never consumed as space-separated values, no short clustering,
    /// and deferred `-h`/`--help`/`--version` recording without exit-2 errors.
    pub const prolog_lenient: Policy = .{
        .allow_abbrev = false,
        .unknown = .ignore,
        .double_dash = .ignore,
        .negative_numbers = .never,
        .short_clusters = false,
        .special_action = .record,
    };
};

/// Result returned by a typed option validator callback.
pub const ValidationResult = union(enum) {
    ok,
    /// Owned error detail appended after `argument --<name>: `.
    err: []u8,

    pub fn deinit(self: *ValidationResult, gpa: Allocator) void {
        switch (self.*) {
            .ok => {},
            .err => |msg| gpa.free(msg),
        }
    }
};

/// Eager validator invoked on each parsed value of an option.
pub const ValidatorFn = *const fn (gpa: Allocator, raw: []const u8) Allocator.Error!ValidationResult;

/// Arity and action of a declared option.
pub const OptionKind = enum {
    /// Boolean flag (`action="store_true"`).
    flag,
    /// Single value (`nargs=1`), keeping the last occurrence.
    value,
    /// Optional value (`nargs="?", const=""`), taking the next non-option token or `""`.
    optional_value,
    /// Multi-value option (`action="append"`), keeping every occurrence in order.
    append,
};

/// Declarative specification of one option belonging to a `CommandSpec`.
pub const OptionSpec = struct {
    /// Long option name without leading `--`.
    name: []const u8,
    /// Optional single-byte short option name without leading `-`.
    short: ?u8 = null,
    /// Option arity and storage mode.
    kind: OptionKind = .flag,
    /// Require this option unless `has_default` is true.
    required: bool = false,
    /// Suppress the missing-required error when an external default (such as an
    /// environment variable) satisfies the option.
    has_default: bool = false,
    /// Static set of allowed values; checked eagerly like `argparse(choices=...)`.
    choices: ?[]const []const u8 = null,
    /// Optional eager value validator; runs on every occurrence as it is parsed.
    validate: ?ValidatorFn = null,
};

/// Arity of a positional argument.
pub const PositionalArity = enum {
    /// Exactly one required positional argument.
    required_one,
    /// Zero or one optional positional argument (`nargs="?"`).
    optional_one,
    /// Capture `--` or the first non-option token and everything after (`argparse.REMAINDER`).
    remainder,
};

/// Declarative specification of one positional argument.
pub const PositionalSpec = struct {
    /// Display name used in `the following arguments are required: ...`.
    name: []const u8,
    /// Positional arity.
    arity: PositionalArity = .required_one,
};

/// Subcommand binding a command name to its own `CommandSpec`.
pub const SubcommandSpec = struct {
    /// Command token matched at the top-level subparser positional.
    name: []const u8,
    /// Specification for parsing tokens following `name`.
    command: *const CommandSpec,
};

/// Declarative specification for a parser (top-level or subcommand).
pub const CommandSpec = struct {
    /// Program or subcommand name printed before `: error: `.
    prog: []const u8,
    /// Pre-wrapped usage text printed to stderr on exit-2 errors.
    usage: []const u8,
    /// Help text printed on `-h` / `--help`.
    help: []const u8,
    /// Optional version line printed on `--version`.
    version: ?[]const u8 = null,
    /// Enable built-in `-h` / `--help` handling.
    add_help: bool = true,
    /// Parser behaviour policy.
    policy: Policy = .python314,
    /// Options in registration order (used for ambiguity listings and missing-argument errors).
    options: []const OptionSpec = &.{},
    /// Positional arguments in declaration order.
    positionals: []const PositionalSpec = &.{},
    /// Optional subcommand dispatch table.
    subcommands: []const SubcommandSpec = &.{},
    /// Dest name reported when a required subcommand is missing.
    subcommand_dest: []const u8 = "command",
};

/// One token retained in argv order during option scanning.
pub const Leftover = struct {
    token: []const u8,
    is_positional: bool,
    is_separator: bool = false,
};

/// Successfully parsed options, positionals, remainder, and optional subcommand result.
pub const Parsed = struct {
    spec: *const CommandSpec,
    opt_seen: []bool,
    opt_values: []?[]const u8,
    opt_lists: [][]const []const u8,
    positionals: []const []const u8,
    remainder: []const []const u8,
    leftovers: []const []const u8,
    help_requested: bool = false,
    version_requested: bool = false,
    subcommand_name: ?[]const u8 = null,
    subcommand_parsed: ?*Parsed = null,

    /// Free all slices owned by this `Parsed` (including any nested subcommand result).
    pub fn deinit(self: *Parsed, gpa: Allocator) void {
        if (self.subcommand_parsed) |sub| {
            sub.deinit(gpa);
            gpa.destroy(sub);
            self.subcommand_parsed = null;
        }
        gpa.free(self.opt_seen);
        gpa.free(self.opt_values);
        for (self.opt_lists) |lst| {
            if (lst.len > 0) gpa.free(lst);
        }
        gpa.free(self.opt_lists);
        if (self.positionals.len > 0) gpa.free(self.positionals);
        if (self.leftovers.len > 0) gpa.free(self.leftovers);
    }

    /// Look up the index of an option by its long name.
    pub fn optionIndex(self: *const Parsed, name: []const u8) ?usize {
        for (self.spec.options, 0..) |opt, idx| {
            if (std.mem.eql(u8, opt.name, name)) return idx;
        }
        return null;
    }

    /// Whether option `name` was supplied at least once.
    pub fn seen(self: *const Parsed, name: []const u8) bool {
        const idx = self.optionIndex(name) orelse return false;
        return self.opt_seen[idx];
    }

    /// The last value supplied for option `name`, or null if unseen.
    pub fn value(self: *const Parsed, name: []const u8) ?[]const u8 {
        const idx = self.optionIndex(name) orelse return null;
        return self.opt_values[idx];
    }

    /// All values supplied for an `.append` option `name` in argv order.
    pub fn values(self: *const Parsed, name: []const u8) []const []const u8 {
        const idx = self.optionIndex(name) orelse return &.{};
        return self.opt_lists[idx];
    }

    /// Positional argument at `index`, or null when absent.
    pub fn positional(self: *const Parsed, index: usize) ?[]const u8 {
        if (index >= self.positionals.len) return null;
        return self.positionals[index];
    }

    /// Subcommand parse result when `subcommands` were dispatched.
    pub fn subcommand(self: *const Parsed) ?*const Parsed {
        return self.subcommand_parsed;
    }
};

/// Result of an immediate `-h`/`--help` or `--version` action.
pub const ActionDone = struct {
    exit_code: u8 = 0,
    stdout_text: []const u8,
};

/// Formatted argparse usage error (exit code 2).
pub const UsageError = struct {
    usage: []const u8,
    prog: []const u8,
    message: []u8,
    exit_code: u8 = cli.usage_exit,

    pub fn deinit(self: *UsageError, gpa: Allocator) void {
        gpa.free(self.message);
    }

    /// Format the full stderr text (`usage` followed by `prog: error: message\n`).
    pub fn formatStderr(self: *const UsageError, gpa: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "{s}{s}: error: {s}\n", .{ self.usage, self.prog, self.message });
    }
};

/// Pure result returned by `parse` without terminating the process.
pub const ParseOutcome = union(enum) {
    ok: Parsed,
    action_done: ActionDone,
    usage_error: UsageError,

    pub fn deinit(self: *ParseOutcome, gpa: Allocator) void {
        switch (self.*) {
            .ok => |*p| p.deinit(gpa),
            .action_done => {},
            .usage_error => |*e| e.deinit(gpa),
        }
    }
};

/// Whether `arg` looks like an option under `mode`.
/// Under `.py314`, mirrors Python 3.14 `_parse_optional`: starts with `-`, has
/// length >= 2, contains no ASCII space, and is not a negative number (`-DIGIT`
/// or `-.DIGIT`). Under `.never`, any token starting with `-` is option-like.
pub fn optionLike(arg: []const u8, mode: NegativeNumberMode) bool {
    switch (mode) {
        .never => return arg.len >= 1 and arg[0] == '-',
        .py314 => {
            if (arg.len < 2 or arg[0] != '-') return false;
            if (std.mem.findScalar(u8, arg, ' ') != null) return false;
            const d = if (arg[1] == '.' and arg.len > 2) arg[2] else arg[1];
            return !std.ascii.isDigit(d);
        },
    }
}

/// Format `s` as a Python string literal using `pytext.reprStrAlloc`.
pub fn reprToken(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return pytext.reprStrAlloc(gpa, s);
}

// ---- pure parser implementation -------------------------------------------

fn makeError(gpa: Allocator, spec: *const CommandSpec, comptime fmt: []const u8, args: anytype) Allocator.Error!ParseOutcome {
    const msg = try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .usage_error = .{
        .usage = spec.usage,
        .prog = spec.prog,
        .message = msg,
    } };
}

fn formatOptionDisplay(gpa: Allocator, opt: OptionSpec) Allocator.Error![]u8 {
    if (opt.short) |s| {
        return std.fmt.allocPrint(gpa, "-{c}/--{s}", .{ s, opt.name });
    }
    return std.fmt.allocPrint(gpa, "--{s}", .{opt.name});
}

fn formatAmbiguous(gpa: Allocator, spec: *const CommandSpec, prefix: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (spec.add_help and std.mem.startsWith(u8, "help", prefix)) {
        try out.appendSlice(gpa, "--help");
    }
    if (spec.version != null and std.mem.startsWith(u8, "version", prefix)) {
        if (out.items.len > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, "--version");
    }
    for (spec.options) |o| {
        if (std.mem.startsWith(u8, o.name, prefix)) {
            if (out.items.len > 0) try out.appendSlice(gpa, ", ");
            try out.print(gpa, "--{s}", .{o.name});
        }
    }
    return out.toOwnedSlice(gpa);
}

const LongMatch = union(enum) {
    none,
    help,
    version,
    option: usize,
    ambiguous,
};

fn matchLong(spec: *const CommandSpec, name: []const u8) LongMatch {
    const abbrev = spec.policy.allow_abbrev;
    var match_help = false;
    var match_ver = false;
    var hit: ?usize = null;
    var count: usize = 0;

    if (spec.add_help and std.mem.eql(u8, "help", name)) return .help;
    if (spec.version != null and std.mem.eql(u8, "version", name)) return .version;
    for (spec.options, 0..) |o, idx| {
        if (std.mem.eql(u8, o.name, name)) return .{ .option = idx };
    }
    if (!abbrev) return .none;

    if (spec.add_help and std.mem.startsWith(u8, "help", name)) {
        match_help = true;
        count += 1;
    }
    if (spec.version != null and std.mem.startsWith(u8, "version", name)) {
        match_ver = true;
        count += 1;
    }
    for (spec.options, 0..) |o, idx| {
        if (std.mem.startsWith(u8, o.name, name)) {
            hit = idx;
            count += 1;
        }
    }
    if (count > 1) return .ambiguous;
    if (match_help) return .help;
    if (match_ver) return .version;
    if (hit) |k| return .{ .option = k };
    return .none;
}

const ShortTarget = union(enum) {
    help,
    option: usize,
};

fn matchShortChar(spec: *const CommandSpec, c: u8) ?ShortTarget {
    if (spec.add_help and c == 'h') return .help;
    for (spec.options, 0..) |o, idx| {
        if (o.short) |s| if (s == c) return .{ .option = idx };
    }
    return null;
}

const ClusterItem = struct {
    target: ShortTarget,
    explicit: ?[]const u8 = null,
};

fn hasRemainder(spec: *const CommandSpec) bool {
    for (spec.positionals) |p| if (p.arity == .remainder) return true;
    return false;
}

fn nonRemainderPositionals(spec: *const CommandSpec) usize {
    var n: usize = 0;
    for (spec.positionals) |p| if (p.arity != .remainder) {
        n += 1;
    };
    return n;
}

fn checkUnrecognized(
    gpa: Allocator,
    top_spec: *const CommandSpec,
    top_extra: []const []const u8,
    leftovers: []const Leftover,
    consumed_positionals: usize,
    keep_separator: bool,
) Allocator.Error!?ParseOutcome {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, top_extra);

    var consumed = consumed_positionals;
    var last_consumed: ?usize = null;
    var dropped = keep_separator;
    for (leftovers, 0..) |item, idx| {
        if (item.is_positional and consumed > 0) {
            consumed -= 1;
            last_consumed = idx;
            continue;
        }
        if (item.is_separator and !dropped) {
            const adjacent_after = last_consumed != null and idx == last_consumed.? + 1;
            const optional_empty = consumed_positionals == 0 and !keep_separator and last_consumed == null;
            if (consumed > 0 or adjacent_after or optional_empty) {
                dropped = true;
                continue;
            }
        }
        try all.append(gpa, item.token);
    }
    if (all.items.len == 0) return null;
    const joined = try std.mem.join(gpa, " ", all.items);
    defer gpa.free(joined);
    return try makeError(gpa, top_spec, "unrecognized arguments: {s}", .{joined});
}

fn buildParsedState(
    gpa: Allocator,
    spec: *const CommandSpec,
    opt_seen: []bool,
    opt_values: []?[]const u8,
    opt_lists: []std.ArrayList([]const u8),
    pos: *std.ArrayList([]const u8),
    remainder: []const []const u8,
    help_requested: bool,
    version_requested: bool,
) Allocator.Error!Parsed {
    const owned_lists = try gpa.alloc([]const []const u8, opt_lists.len);
    var built: usize = 0;
    errdefer {
        for (owned_lists[0..built]) |lst| {
            if (lst.len > 0) gpa.free(lst);
        }
        gpa.free(owned_lists);
    }
    for (opt_lists, 0..) |*lst, idx| {
        owned_lists[idx] = if (lst.items.len > 0) try lst.toOwnedSlice(gpa) else &.{};
        built += 1;
    }
    const owned_pos: []const []const u8 = if (pos.items.len > 0) try pos.toOwnedSlice(gpa) else &.{};
    return .{
        .spec = spec,
        .opt_seen = opt_seen,
        .opt_values = opt_values,
        .opt_lists = owned_lists,
        .positionals = owned_pos,
        .remainder = remainder,
        .leftovers = &.{},
        .help_requested = help_requested,
        .version_requested = version_requested,
    };
}

fn parseCommand(
    gpa: Allocator,
    spec: *const CommandSpec,
    top_spec: *const CommandSpec,
    argv: []const []const u8,
    top_extra: []const []const u8,
) Allocator.Error!ParseOutcome {
    const n_opts = spec.options.len;
    const opt_seen = try gpa.alloc(bool, n_opts);
    var own_state = true;
    errdefer if (own_state) gpa.free(opt_seen);
    @memset(opt_seen, false);

    const opt_values = try gpa.alloc(?[]const u8, n_opts);
    errdefer if (own_state) gpa.free(opt_values);
    @memset(opt_values, null);

    const opt_lists = try gpa.alloc(std.ArrayList([]const u8), n_opts);
    defer {
        for (opt_lists) |*lst| lst.deinit(gpa);
        gpa.free(opt_lists);
    }
    for (opt_lists) |*lst| lst.* = .empty;

    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(gpa);

    var leftovers: std.ArrayList(Leftover) = .empty;
    defer leftovers.deinit(gpa);

    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |s| gpa.free(s);
        scratch.deinit(gpa);
    }

    var remainder: []const []const u8 = &.{};
    var help_requested = false;
    var version_requested = false;

    const is_remainder = hasRemainder(spec);
    const has_subs = spec.subcommands.len > 0;
    var sub_index: ?usize = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        // 1. Handle "--" separator when policy terminates on "--".
        if (spec.policy.double_dash == .terminate and std.mem.eql(u8, arg, "--")) {
            if (has_subs) {
                sub_index = i + 1;
                break;
            }
            if (is_remainder) {
                remainder = argv[i..];
                break;
            }
            try leftovers.append(gpa, .{ .token = "--", .is_positional = false, .is_separator = true });
            for (argv[i + 1 ..]) |p| {
                try pos.append(gpa, p);
                try leftovers.append(gpa, .{ .token = p, .is_positional = true });
            }
            break;
        }

        // 2. Short options and short-option clusters ("-x", "-xy", "-h=1", "-ao=val").
        if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
            if (spec.policy.short_clusters) {
                var items: std.ArrayList(ClusterItem) = .empty;
                defer items.deinit(gpa);
                var unknown_tail: ?[]u8 = null;
                errdefer if (unknown_tail) |t| gpa.free(t);

                var cur_slice: []const u8 = arg;
                var cluster_err: ?ParseOutcome = null;
                while (cur_slice.len >= 2) {
                    const target = matchShortChar(spec, cur_slice[1]) orelse {
                        if (items.items.len > 0) {
                            const tail = try gpa.alloc(u8, cur_slice.len);
                            tail[0] = '-';
                            @memcpy(tail[1..], cur_slice[1..]);
                            unknown_tail = tail;
                        }
                        break;
                    };
                    const rest = cur_slice[2..];
                    const takes_value = switch (target) {
                        .help => false,
                        .option => |k| spec.options[k].kind != .flag,
                    };
                    if (takes_value) {
                        const explicit: ?[]const u8 = if (rest.len > 0)
                            (if (rest[0] == '=') rest[1..] else rest)
                        else
                            null;
                        try items.append(gpa, .{ .target = target, .explicit = explicit });
                        break;
                    }
                    if (rest.len == 0) {
                        try items.append(gpa, .{ .target = target });
                        break;
                    }
                    if (rest[0] == '=' or rest[0] == '-') {
                        const bad_val = if (rest[0] == '=') rest[1..] else rest;
                        const q = try reprToken(gpa, bad_val);
                        defer gpa.free(q);
                        const disp = switch (target) {
                            .help => try gpa.dupe(u8, "-h/--help"),
                            .option => |k| try formatOptionDisplay(gpa, spec.options[k]),
                        };
                        defer gpa.free(disp);
                        cluster_err = try makeError(gpa, spec, "argument {s}: ignored explicit argument {s}", .{ disp, q });
                        break;
                    }
                    try items.append(gpa, .{ .target = target });
                    // Advance to next short flag in cluster: slice starting 1 byte before `rest`
                    // has cur_slice[1] == rest[0] because `arg` is contiguous.
                    cur_slice = cur_slice[1..];
                }
                if (cluster_err) |err_out| {
                    if (unknown_tail) |t| gpa.free(t);
                    gpa.free(opt_seen);
                    gpa.free(opt_values);
                    own_state = false;
                    return err_out;
                }
                if (items.items.len > 0) {
                    for (items.items) |it| {
                        switch (it.target) {
                            .help => {
                                if (spec.policy.special_action == .immediate_exit) {
                                    if (unknown_tail) |t| gpa.free(t);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.help } };
                                }
                                help_requested = true;
                            },
                            .option => |k| {
                                const o = spec.options[k];
                                opt_seen[k] = true;
                                if (o.kind == .flag) continue;
                                var val: []const u8 = undefined;
                                if (it.explicit) |ev| {
                                    val = ev;
                                } else if (i + 1 < argv.len and !optionLike(argv[i + 1], spec.policy.negative_numbers)) {
                                    i += 1;
                                    val = argv[i];
                                } else if (o.kind == .optional_value) {
                                    val = "";
                                } else {
                                    if (unknown_tail) |t| gpa.free(t);
                                    const disp = try formatOptionDisplay(gpa, o);
                                    defer gpa.free(disp);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
                                }
                                if (o.kind == .append) {
                                    try opt_lists[k].append(gpa, val);
                                } else {
                                    opt_values[k] = val;
                                }
                            },
                        }
                    }
                    if (unknown_tail) |t| {
                        try scratch.append(gpa, t);
                        try leftovers.append(gpa, .{ .token = t, .is_positional = false });
                    }
                    continue;
                }
            } else if (arg.len == 2) {
                if (matchShortChar(spec, arg[1])) |target| {
                    switch (target) {
                        .help => {
                            if (spec.policy.special_action == .immediate_exit) {
                                gpa.free(opt_seen);
                                gpa.free(opt_values);
                                own_state = false;
                                return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.help } };
                            }
                            help_requested = true;
                        },
                        .option => |k| {
                            const o = spec.options[k];
                            opt_seen[k] = true;
                            if (o.kind != .flag) {
                                var val: []const u8 = "";
                                if (i + 1 < argv.len and !optionLike(argv[i + 1], spec.policy.negative_numbers)) {
                                    i += 1;
                                    val = argv[i];
                                } else if (o.kind != .optional_value) {
                                    const disp = try formatOptionDisplay(gpa, o);
                                    defer gpa.free(disp);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
                                }
                                if (o.kind == .append) {
                                    try opt_lists[k].append(gpa, val);
                                } else {
                                    opt_values[k] = val;
                                }
                            }
                        },
                    }
                    continue;
                }
            }
        }

        // 3. Long options ("--name", "--name=val", unique prefixes when allow_abbrev).
        if (std.mem.startsWith(u8, arg, "--") and (arg.len > 2)) {
            const eq = std.mem.findScalar(u8, arg, '=');
            const name = arg[2 .. eq orelse arg.len];
            switch (matchLong(spec, name)) {
                .ambiguous => {
                    const amb = try formatAmbiguous(gpa, spec, name);
                    defer gpa.free(amb);
                    gpa.free(opt_seen);
                    gpa.free(opt_values);
                    own_state = false;
                    return try makeError(gpa, spec, "ambiguous option: {s} could match {s}", .{ arg, amb });
                },
                .help => {
                    if (eq) |e| {
                        if (spec.policy.unknown == .ignore) continue;
                        const q = try reprToken(gpa, arg[e + 1 ..]);
                        defer gpa.free(q);
                        gpa.free(opt_seen);
                        gpa.free(opt_values);
                        own_state = false;
                        return try makeError(gpa, spec, "argument -h/--help: ignored explicit argument {s}", .{q});
                    }
                    if (spec.policy.special_action == .immediate_exit) {
                        gpa.free(opt_seen);
                        gpa.free(opt_values);
                        own_state = false;
                        return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.help } };
                    }
                    help_requested = true;
                    continue;
                },
                .version => {
                    if (eq) |e| {
                        if (spec.policy.unknown == .ignore) continue;
                        const q = try reprToken(gpa, arg[e + 1 ..]);
                        defer gpa.free(q);
                        gpa.free(opt_seen);
                        gpa.free(opt_values);
                        own_state = false;
                        return try makeError(gpa, spec, "argument --version: ignored explicit argument {s}", .{q});
                    }
                    if (spec.policy.special_action == .immediate_exit) {
                        gpa.free(opt_seen);
                        gpa.free(opt_values);
                        own_state = false;
                        return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.version.? } };
                    }
                    version_requested = true;
                    continue;
                },
                .option => |k| {
                    const o = spec.options[k];
                    if (o.kind == .flag) {
                        if (eq) |e| {
                            if (spec.policy.unknown == .ignore) continue;
                            const disp = try formatOptionDisplay(gpa, o);
                            defer gpa.free(disp);
                            const q = try reprToken(gpa, arg[e + 1 ..]);
                            defer gpa.free(q);
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return try makeError(gpa, spec, "argument {s}: ignored explicit argument {s}", .{ disp, q });
                        }
                        opt_seen[k] = true;
                        continue;
                    }
                    opt_seen[k] = true;
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = arg[e + 1 ..];
                    } else if (i + 1 < argv.len and !optionLike(argv[i + 1], spec.policy.negative_numbers)) {
                        i += 1;
                        val = argv[i];
                    } else if (o.kind == .optional_value) {
                        val = "";
                    } else {
                        const disp = try formatOptionDisplay(gpa, o);
                        defer gpa.free(disp);
                        gpa.free(opt_seen);
                        gpa.free(opt_values);
                        own_state = false;
                        return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
                    }
                    if (o.kind == .append) {
                        try opt_lists[k].append(gpa, val);
                    } else {
                        opt_values[k] = val;
                    }
                    continue;
                },
                .none => {},
            }
        }

        // 4. Non-option token: subcommand, remainder start, or positional.
        if (!optionLike(arg, spec.policy.negative_numbers)) {
            if (has_subs) {
                sub_index = i;
                break;
            }
            if (is_remainder) {
                remainder = argv[i..];
                break;
            }
            try pos.append(gpa, arg);
            try leftovers.append(gpa, .{ .token = arg, .is_positional = true });
            continue;
        }

        // 5. Unrecognized option-like token.
        try leftovers.append(gpa, .{ .token = arg, .is_positional = false });
    }

    // Subcommand dispatch when this parser defines subcommands.
    if (has_subs) {
        const idx = sub_index orelse argv.len;
        if (idx >= argv.len) {
            gpa.free(opt_seen);
            gpa.free(opt_values);
            own_state = false;
            return try makeError(gpa, spec, "the following arguments are required: {s}", .{spec.subcommand_dest});
        }
        const cmd_name = argv[idx];
        var matched_sub: ?SubcommandSpec = null;
        for (spec.subcommands) |sub| {
            if (std.mem.eql(u8, sub.name, cmd_name)) {
                matched_sub = sub;
                break;
            }
        }
        const sub = matched_sub orelse {
            var choices_buf: std.ArrayList(u8) = .empty;
            defer choices_buf.deinit(gpa);
            for (spec.subcommands, 0..) |s, si| {
                if (si > 0) try choices_buf.appendSlice(gpa, ", ");
                const q = try reprToken(gpa, s.name);
                defer gpa.free(q);
                try choices_buf.appendSlice(gpa, q);
            }
            const qcmd = try reprToken(gpa, cmd_name);
            defer gpa.free(qcmd);
            gpa.free(opt_seen);
            gpa.free(opt_values);
            own_state = false;
            return try makeError(gpa, spec, "argument {s}: invalid choice: {s} (choose from {s})", .{ spec.subcommand_dest, qcmd, choices_buf.items });
        };

        var top_unknowns: std.ArrayList([]const u8) = .empty;
        defer top_unknowns.deinit(gpa);
        for (leftovers.items) |l| try top_unknowns.append(gpa, l.token);

        const sub_outcome = try parseCommand(gpa, sub.command, top_spec, argv[idx + 1 ..], top_unknowns.items);
        switch (sub_outcome) {
            .ok => |sub_parsed| {
                const sub_ptr = try gpa.create(Parsed);
                errdefer {
                    var tmp = sub_parsed;
                    tmp.deinit(gpa);
                    gpa.destroy(sub_ptr);
                }
                sub_ptr.* = sub_parsed;
                var parsed = try buildParsedState(gpa, spec, opt_seen, opt_values, opt_lists, &pos, remainder, help_requested, version_requested);
                own_state = false;
                parsed.subcommand_name = sub.name;
                parsed.subcommand_parsed = sub_ptr;
                return .{ .ok = parsed };
            },
            .action_done, .usage_error => {
                gpa.free(opt_seen);
                gpa.free(opt_values);
                own_state = false;
                return sub_outcome;
            },
        }
    }

    // Check required options and required positionals (in registration order).
    var missing_names: std.ArrayList([]u8) = .empty;
    defer {
        for (missing_names.items) |m| gpa.free(m);
        missing_names.deinit(gpa);
    }
    for (spec.options, 0..) |o, idx| {
        if (o.required and !o.has_default and !opt_seen[idx]) {
            try missing_names.append(gpa, try formatOptionDisplay(gpa, o));
        }
    }
    var req_pos_count: usize = 0;
    for (spec.positionals) |p| {
        if (p.arity == .required_one) {
            if (pos.items.len <= req_pos_count) {
                try missing_names.append(gpa, try gpa.dupe(u8, p.name));
            }
            req_pos_count += 1;
        }
    }
    if (missing_names.items.len > 0) {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        for (missing_names.items, 0..) |m, mi| {
            if (mi > 0) try joined.appendSlice(gpa, ", ");
            try joined.appendSlice(gpa, m);
        }
        gpa.free(opt_seen);
        gpa.free(opt_values);
        own_state = false;
        return try makeError(gpa, spec, "the following arguments are required: {s}", .{joined.items});
    }

    // Check merged unrecognized arguments unless unknown tokens are ignored.
    if (spec.policy.unknown == .collect) {
        const pos_slots = nonRemainderPositionals(spec);
        const consumed_pos = @min(pos.items.len, pos_slots);
        const keep_sep = pos_slots == 0 and !is_remainder;
        if (try checkUnrecognized(gpa, top_spec, top_extra, leftovers.items, consumed_pos, keep_sep)) |err_out| {
            gpa.free(opt_seen);
            gpa.free(opt_values);
            own_state = false;
            return err_out;
        }
    }

    const parsed = try buildParsedState(gpa, spec, opt_seen, opt_values, opt_lists, &pos, remainder, help_requested, version_requested);
    own_state = false;
    return .{ .ok = parsed };
}

/// Pure, non-exiting argument parser. Caller owns the returned `ParseOutcome`
/// and should release it with `deinit(gpa)`.
pub fn parse(gpa: Allocator, spec: *const CommandSpec, argv: []const []const u8) Allocator.Error!ParseOutcome {
    return parseCommand(gpa, spec, spec, argv, &.{});
}

/// Parse `argv` according to `spec`, writing help/version text to stdout and
/// exiting 0, or writing usage + error to stderr and exiting 2 on failure.
pub fn parseOrExit(gpa: Allocator, spec: *const CommandSpec, argv: []const []const u8) Parsed {
    var outcome = parse(gpa, spec, argv) catch {
        spec.policy.write_stderr("out of memory\n");
        std.process.exit(cli.usage_exit);
    };
    switch (outcome) {
        .ok => |p| return p,
        .action_done => |done| {
            spec.policy.write_stdout(done.stdout_text);
            std.process.exit(done.exit_code);
        },
        .usage_error => |*uerr| {
            defer uerr.deinit(gpa);
            if (uerr.formatStderr(gpa)) |txt| {
                defer gpa.free(txt);
                spec.policy.write_stderr(txt);
            } else |_| {
                spec.policy.write_stderr(uerr.usage);
            }
            std.process.exit(uerr.exit_code);
        },
    }
}
