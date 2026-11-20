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
    /// Treat unrecognized option-like tokens as positional arguments while
    /// still rejecting positionals past the declared slots.
    positional,
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
    /// Consume any token following a value option (including dash-prefixed
    /// tokens such as `-5` or `--foo`) while keeping standalone dash tokens
    /// option-like.
    any,
};

/// How `-h`/`--help` and `--version` actions behave during parsing.
pub const SpecialActionMode = enum {
    /// Stop parsing immediately and return `ParseOutcome.action_done`.
    immediate_exit,
    /// Record `help_requested` / `version_requested` on `Parsed` and keep scanning.
    record,
    /// Scan the full argument vector for `-h`/`--help` or `--version` before
    /// parsing options and return `ParseOutcome.action_done` immediately if found.
    prescan,
};

/// Parser behaviour policy controlling strict Python 3.14 parity, lenient
/// TaskProlog parsing, and exact-match native Zig CLIs.
pub const Policy = struct {
    allow_abbrev: bool = true,
    unknown: UnknownMode = .collect,
    double_dash: DoubleDashMode = .terminate,
    negative_numbers: NegativeNumberMode = .py314,
    short_clusters: bool = true,
    special_action: SpecialActionMode = .immediate_exit,
    /// Treat `--flag=val` on a boolean flag (and `--help=val` / `--version=val`)
    /// as an unrecognized option-like token instead of an `ignored explicit argument` error.
    flag_explicit_as_unknown: bool = false,
    /// Report unrecognized options and excess positionals before missing required
    /// options, positionals, or subcommands.
    unknown_before_required: bool = false,
    /// Return immediately on the first unrecognized option, excess positional,
    /// or mutually exclusive conflict encountered during left-to-right scanning.
    fail_fast: bool = false,
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

    /// Exact-match policy for native Zig CLIs: no abbreviations, no short
    /// clustering, `--` is not a special separator, any token following a value
    /// option is consumed as its value, `--flag=val` is treated as an unknown
    /// option, unknown tokens are reported before missing required arguments,
    /// and scan-time errors fail fast left-to-right.
    pub const native_exact: Policy = .{
        .allow_abbrev = false,
        .unknown = .collect,
        .double_dash = .ignore,
        .negative_numbers = .any,
        .short_clusters = false,
        .special_action = .immediate_exit,
        .flag_explicit_as_unknown = true,
        .unknown_before_required = true,
        .fail_fast = true,
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
    /// Allow an empty string value (`--opt=` or `--opt ""`). When `false`,
    /// an empty value is rejected as a missing option argument.
    allow_empty: bool = true,
    /// Allow a value starting with `-` (including `--opt=-val`). When `false`,
    /// a leading-dash value is rejected as a missing option argument.
    allow_dash_value: bool = true,
};

/// Arity of a positional argument.
pub const PositionalArity = enum {
    /// Exactly one required positional argument.
    required_one,
    /// Zero or one optional positional argument (`nargs="?"`).
    optional_one,
    /// Zero or more positional arguments, intermixed with options (`nargs="*"`).
    zero_or_more,
    /// One or more positional arguments, intermixed with options (`nargs="+"`).
    one_or_more,
    /// Capture `--` or the first non-option token and everything after (`argparse.REMAINDER`).
    remainder,
};

/// Declarative specification of one positional argument.
pub const PositionalSpec = struct {
    /// Display name used in `the following arguments are required: ...`.
    name: []const u8,
    /// Positional arity.
    arity: PositionalArity = .required_one,
    /// Optional static set of allowed values, validated eagerly on parse.
    choices: ?[]const []const u8 = null,
    /// Skip empty (`""`) positional tokens instead of filling this slot.
    ignore_empty: bool = false,
};

/// Subcommand binding a command name to its own `CommandSpec`.
pub const SubcommandSpec = struct {
    /// Command token matched at the top-level subparser positional.
    name: []const u8,
    /// Specification for parsing tokens following `name`.
    command: *const CommandSpec,
};

/// Group of option long names that cannot appear together on the same invocation.
pub const MutexGroup = struct {
    /// Long option names (without leading `--`) belonging to this group.
    options: []const []const u8,
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
    /// Mutually exclusive option groups for this parser.
    mutually_exclusive: []const MutexGroup = &.{},
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
    argv_index: usize = 0,
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
/// or `-.DIGIT`). Under `.never` and `.any`, any token starting with `-` is
/// option-like when standing alone.
pub fn optionLike(arg: []const u8, mode: NegativeNumberMode) bool {
    switch (mode) {
        .never, .any => return arg.len >= 1 and arg[0] == '-',
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

/// Reusable eager typed validators matching Python 3.14 `argparse` conventions.
pub const types = struct {
    fn formatChoicesDetail(gpa: Allocator, raw: []const u8, allowed: []const []const u8) Allocator.Error![]u8 {
        var choices_buf: std.ArrayList(u8) = .empty;
        defer choices_buf.deinit(gpa);
        for (allowed, 0..) |c, ci| {
            if (ci > 0) try choices_buf.appendSlice(gpa, ", ");
            const qc = try reprToken(gpa, c);
            defer gpa.free(qc);
            try choices_buf.appendSlice(gpa, qc);
        }
        const qraw = try reprToken(gpa, raw);
        defer gpa.free(qraw);
        return std.fmt.allocPrint(gpa, "invalid choice: {s} (choose from {s})", .{ qraw, choices_buf.items });
    }

    fn scanDigitsWithUnderscores(s: []const u8, idx: *usize) struct { digits: usize, ok: bool } {
        var digits: usize = 0;
        var prev_underscore = false;
        while (idx.* < s.len) {
            const c = s[idx.*];
            if (std.ascii.isDigit(c)) {
                digits += 1;
                prev_underscore = false;
                idx.* += 1;
            } else if (c == '_') {
                if (digits == 0 or prev_underscore) return .{ .digits = digits, .ok = false };
                prev_underscore = true;
                idx.* += 1;
            } else {
                break;
            }
        }
        if (prev_underscore) return .{ .digits = digits, .ok = false };
        return .{ .digits = digits, .ok = true };
    }

    /// Parse a Python-syntax float (surrounding Python whitespace, optional sign,
    /// case-insensitive `inf`/`infinity`/`nan`, or decimal digits with Python
    /// single-underscore rules). Returns `null` on invalid syntax.
    pub fn parsePyFloat(raw: []const u8) ?f64 {
        const s = pytext.pyStrip(raw);
        if (s.len == 0) return null;
        var i: usize = 0;
        var neg = false;
        if (s[i] == '+' or s[i] == '-') {
            neg = s[i] == '-';
            i += 1;
            if (i >= s.len) return null;
        }
        const body = s[i..];
        if (std.ascii.eqlIgnoreCase(body, "inf") or std.ascii.eqlIgnoreCase(body, "infinity")) {
            return if (neg) -std.math.inf(f64) else std.math.inf(f64);
        }
        if (std.ascii.eqlIgnoreCase(body, "nan")) {
            return std.math.nan(f64);
        }

        // Validate decimal float grammar with single underscores only between digits.
        var p = i;
        const int_part = scanDigitsWithUnderscores(s, &p);
        if (!int_part.ok) return null;
        var frac_digits: usize = 0;
        if (p < s.len and s[p] == '.') {
            p += 1;
            const frac_part = scanDigitsWithUnderscores(s, &p);
            if (!frac_part.ok) return null;
            frac_digits = frac_part.digits;
        }
        if (int_part.digits == 0 and frac_digits == 0) return null;

        if (p < s.len and (s[p] == 'e' or s[p] == 'E')) {
            p += 1;
            if (p < s.len and (s[p] == '+' or s[p] == '-')) p += 1;
            const exp_part = scanDigitsWithUnderscores(s, &p);
            if (!exp_part.ok or exp_part.digits == 0) return null;
        }
        if (p != s.len) return null;

        if (std.mem.findScalar(u8, s, '_') == null) {
            return std.fmt.parseFloat(f64, s) catch null;
        }
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        for (s) |c| {
            if (c == '_') continue;
            if (len >= buf.len) return null;
            buf[len] = c;
            len += 1;
        }
        return std.fmt.parseFloat(f64, buf[0..len]) catch null;
    }

    /// Eager validator matching Python `argparse(..., type=float)`.
    pub fn pyFloat(gpa: Allocator, raw: []const u8) Allocator.Error!ValidationResult {
        if (parsePyFloat(raw) != null) return .ok;
        const q = try reprToken(gpa, raw);
        defer gpa.free(q);
        return .{ .err = try std.fmt.allocPrint(gpa, "invalid float value: {s}", .{q}) };
    }

    /// Eager validator requiring a finite float `>= 0` (for duration/grace flags).
    pub fn nonNegativeFiniteFloat(gpa: Allocator, raw: []const u8) Allocator.Error!ValidationResult {
        const v = parsePyFloat(raw) orelse {
            const q = try reprToken(gpa, raw);
            defer gpa.free(q);
            return .{ .err = try std.fmt.allocPrint(gpa, "invalid float value: {s}", .{q}) };
        };
        if (!std.math.isFinite(v) or v < 0) {
            const q = try reprToken(gpa, raw);
            defer gpa.free(q);
            return .{ .err = try std.fmt.allocPrint(gpa, "must be a finite number >= 0: {s}", .{q}) };
        }
        return .ok;
    }

    /// Error set returned by `parseNonNegativeU128`.
    pub const IntError = error{ NotAnInteger, BelowZero, Overflow };

    /// Parse a Python-syntax decimal integer `>= 0` (including `-0` as `0`,
    /// surrounding Python whitespace, optional `+`, and single underscores
    /// between digits).
    pub fn parseNonNegativeU128(raw: []const u8) IntError!u128 {
        const s = pytext.pyStrip(raw);
        if (s.len == 0) return error.NotAnInteger;
        var i: usize = 0;
        var neg = false;
        if (s[i] == '+' or s[i] == '-') {
            neg = s[i] == '-';
            i += 1;
            if (i >= s.len) return error.NotAnInteger;
        }
        var p = i;
        const part = scanDigitsWithUnderscores(s, &p);
        if (!part.ok or part.digits == 0 or p != s.len) return error.NotAnInteger;

        if (neg) {
            for (s[i..]) |c| {
                if (c != '_' and c != '0') return error.BelowZero;
            }
            return 0;
        }

        var acc: u128 = 0;
        for (s[i..]) |c| {
            if (c == '_') continue;
            const d: u128 = c - '0';
            acc = std.math.mul(u128, acc, 10) catch return error.Overflow;
            acc = std.math.add(u128, acc, d) catch return error.Overflow;
        }
        return acc;
    }

    /// Eager validator requiring a non-negative `u128` decimal integer.
    pub fn nonNegativeU128(gpa: Allocator, raw: []const u8) Allocator.Error!ValidationResult {
        _ = parseNonNegativeU128(raw) catch |err| {
            const q = try reprToken(gpa, raw);
            defer gpa.free(q);
            return switch (err) {
                error.NotAnInteger => .{ .err = try std.fmt.allocPrint(gpa, "invalid integer value: {s}", .{q}) },
                error.BelowZero => .{ .err = try std.fmt.allocPrint(gpa, "must be >= 0: {s}", .{q}) },
                error.Overflow => .{ .err = try std.fmt.allocPrint(gpa, "integer out of range: {s}", .{q}) },
            };
        };
        return .ok;
    }

    /// Eager validator requiring a decimal integer within `0..std.math.maxInt(u64)`.
    pub fn boundedU64(gpa: Allocator, raw: []const u8) Allocator.Error!ValidationResult {
        const v = parseNonNegativeU128(raw) catch |err| {
            const q = try reprToken(gpa, raw);
            defer gpa.free(q);
            return switch (err) {
                error.NotAnInteger => .{ .err = try std.fmt.allocPrint(gpa, "invalid integer value: {s}", .{q}) },
                error.BelowZero => .{ .err = try std.fmt.allocPrint(gpa, "must be >= 0: {s}", .{q}) },
                error.Overflow => .{ .err = try std.fmt.allocPrint(gpa, "integer out of range: {s}", .{q}) },
            };
        };
        if (v > std.math.maxInt(u64)) {
            const q = try reprToken(gpa, raw);
            defer gpa.free(q);
            return .{ .err = try std.fmt.allocPrint(gpa, "integer out of range: {s}", .{q}) };
        }
        return .ok;
    }

    /// Construct a `ValidatorFn` validating membership in a static `allowed` list.
    pub fn choice(comptime allowed: []const []const u8) ValidatorFn {
        return struct {
            fn validate(gpa: Allocator, raw: []const u8) Allocator.Error!ValidationResult {
                for (allowed) |item| {
                    if (std.mem.eql(u8, item, raw)) return .ok;
                }
                return .{ .err = try formatChoicesDetail(gpa, raw, allowed) };
            }
        }.validate;
    }
};

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

fn checkOptionValueAllowed(
    gpa: Allocator,
    spec: *const CommandSpec,
    opt: OptionSpec,
    val: []const u8,
) Allocator.Error!?ParseOutcome {
    if ((!opt.allow_empty and val.len == 0) or (!opt.allow_dash_value and val.len > 0 and val[0] == '-')) {
        const disp = try formatOptionDisplay(gpa, opt);
        defer gpa.free(disp);
        return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
    }
    return null;
}

fn validateOptionValue(
    gpa: Allocator,
    spec: *const CommandSpec,
    opt: OptionSpec,
    val: []const u8,
) Allocator.Error!?ParseOutcome {
    if (opt.validate) |vf| {
        const res = try vf(gpa, val);
        switch (res) {
            .ok => {},
            .err => |detail| {
                defer gpa.free(detail);
                const disp = try formatOptionDisplay(gpa, opt);
                defer gpa.free(disp);
                return try makeError(gpa, spec, "argument {s}: {s}", .{ disp, detail });
            },
        }
    }
    if (opt.choices) |allowed| {
        for (allowed) |c| {
            if (std.mem.eql(u8, c, val)) return null;
        }
        const disp = try formatOptionDisplay(gpa, opt);
        defer gpa.free(disp);
        const detail = try types.formatChoicesDetail(gpa, val, allowed);
        defer gpa.free(detail);
        return try makeError(gpa, spec, "argument {s}: {s}", .{ disp, detail });
    }
    return null;
}

fn positionalSpecAt(spec: *const CommandSpec, pos_index: usize) ?PositionalSpec {
    var slot: usize = 0;
    for (spec.positionals) |p| {
        switch (p.arity) {
            .remainder => continue,
            .zero_or_more, .one_or_more => {
                if (pos_index >= slot) return p;
            },
            .required_one, .optional_one => {
                if (pos_index == slot) return p;
                slot += 1;
            },
        }
    }
    return null;
}

fn validatePositionalChoice(
    gpa: Allocator,
    spec: *const CommandSpec,
    pos_index: usize,
    val: []const u8,
) Allocator.Error!?ParseOutcome {
    const p = positionalSpecAt(spec, pos_index) orelse return null;
    const allowed = p.choices orelse return null;
    for (allowed) |c| {
        if (std.mem.eql(u8, c, val)) return null;
    }
    const detail = try types.formatChoicesDetail(gpa, val, allowed);
    defer gpa.free(detail);
    return try makeError(gpa, spec, "argument {s}: {s}", .{ p.name, detail });
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

fn isOptionToken(spec: *const CommandSpec, arg: []const u8) bool {
    if (spec.policy.negative_numbers == .never or spec.policy.negative_numbers == .any) {
        return arg.len >= 1 and arg[0] == '-';
    }
    if (arg.len < 2 or arg[0] != '-') return false;
    if (spec.policy.double_dash == .terminate and std.mem.eql(u8, arg, "--")) return true;
    if (arg[1] == '-') {
        if (arg.len > 2) {
            const eq = std.mem.findScalar(u8, arg, '=');
            const name = arg[2 .. eq orelse arg.len];
            if (matchLong(spec, name) != .none) return true;
        }
    } else if (spec.policy.short_clusters) {
        if (matchShortChar(spec, arg[1]) != null) return true;
    } else if (arg.len == 2) {
        if (matchShortChar(spec, arg[1]) != null) return true;
    }
    return optionLike(arg, spec.policy.negative_numbers);
}

fn canConsumeNextValue(spec: *const CommandSpec, next_arg: []const u8) bool {
    if (spec.policy.negative_numbers == .any) return true;
    return !isOptionToken(spec, next_arg);
}

const ClusterItem = struct {
    target: ShortTarget,
    explicit: ?[]const u8 = null,
};

fn hasRemainder(spec: *const CommandSpec) bool {
    for (spec.positionals) |p| if (p.arity == .remainder) return true;
    return false;
}

fn hasVariadicPositional(spec: *const CommandSpec) bool {
    for (spec.positionals) |p| {
        if (p.arity == .zero_or_more or p.arity == .one_or_more) return true;
    }
    return false;
}

fn ignoresEmptyAt(spec: *const CommandSpec, pos_index: usize) bool {
    var slot: usize = 0;
    for (spec.positionals) |p| {
        if (p.arity == .remainder) return false;
        if (p.arity == .zero_or_more or p.arity == .one_or_more) return p.ignore_empty;
        if (slot == pos_index) return p.ignore_empty;
        slot += 1;
    }
    return false;
}

fn nonRemainderPositionals(spec: *const CommandSpec) usize {
    var n: usize = 0;
    for (spec.positionals) |p| if (p.arity != .remainder) {
        n += 1;
    };
    return n;
}

fn findMutexConflict(spec: *const CommandSpec, opt_seen: []const bool, opt_idx: usize) ?usize {
    const name = spec.options[opt_idx].name;
    for (spec.mutually_exclusive) |group| {
        var in_group = false;
        for (group.options) |member| {
            if (std.mem.eql(u8, member, name)) {
                in_group = true;
                break;
            }
        }
        if (!in_group) continue;
        for (group.options) |member| {
            if (std.mem.eql(u8, member, name)) continue;
            for (spec.options, 0..) |o, oi| {
                if (std.mem.eql(u8, o.name, member) and opt_seen[oi]) return oi;
            }
        }
    }
    return null;
}

fn makeMutexError(
    gpa: Allocator,
    spec: *const CommandSpec,
    opt_idx: usize,
    conflict_idx: usize,
) Allocator.Error!ParseOutcome {
    const disp_opt = try formatOptionDisplay(gpa, spec.options[opt_idx]);
    defer gpa.free(disp_opt);
    const disp_conflict = try formatOptionDisplay(gpa, spec.options[conflict_idx]);
    defer gpa.free(disp_conflict);
    return try makeError(gpa, spec, "argument {s}: not allowed with argument {s}", .{ disp_opt, disp_conflict });
}

fn checkUnrecognized(
    gpa: Allocator,
    top_spec: *const CommandSpec,
    top_extra: []const []const u8,
    leftovers: []const Leftover,
    consumed_positionals: usize,
    keep_separator: bool,
    variadic: bool,
) Allocator.Error!?ParseOutcome {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, top_extra);

    var consumed = consumed_positionals;
    var last_consumed_argv: ?usize = null;
    var dropped = keep_separator;
    for (leftovers) |item| {
        if (item.is_positional and consumed > 0) {
            consumed -= 1;
            last_consumed_argv = item.argv_index;
            continue;
        }
        if (item.is_separator and !dropped) {
            const adjacent_after = last_consumed_argv != null and item.argv_index == last_consumed_argv.? + 1;
            const optional_empty = consumed_positionals == 0 and !keep_separator and last_consumed_argv == null;
            if (variadic or consumed > 0 or adjacent_after or optional_empty) {
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
    const max_fixed_pos: ?usize = if (is_remainder or hasVariadicPositional(spec)) null else nonRemainderPositionals(spec);
    var sub_index: ?usize = null;

    if (spec.policy.special_action == .prescan) {
        for (argv) |a| {
            if (spec.add_help and (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help"))) {
                gpa.free(opt_seen);
                gpa.free(opt_values);
                own_state = false;
                return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.help } };
            }
            if (spec.version != null and std.mem.eql(u8, a, "--version")) {
                gpa.free(opt_seen);
                gpa.free(opt_values);
                own_state = false;
                return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.version.? } };
            }
        }
    }

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
            try leftovers.append(gpa, .{ .token = "--", .is_positional = false, .is_separator = true, .argv_index = i });
            for (argv[i + 1 ..], 0..) |p, pi| {
                if (p.len == 0 and ignoresEmptyAt(spec, pos.items.len)) continue;
                if (spec.policy.fail_fast and spec.policy.unknown != .ignore) {
                    if (max_fixed_pos) |max_p| if (pos.items.len >= max_p) {
                        gpa.free(opt_seen);
                        gpa.free(opt_values);
                        own_state = false;
                        return try makeError(gpa, top_spec, "unrecognized arguments: {s}", .{p});
                    };
                }
                if (try validatePositionalChoice(gpa, spec, pos.items.len, p)) |err_out| {
                    gpa.free(opt_seen);
                    gpa.free(opt_values);
                    own_state = false;
                    return err_out;
                }
                try pos.append(gpa, p);
                try leftovers.append(gpa, .{ .token = p, .is_positional = true, .argv_index = i + 1 + pi });
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
                                if (o.kind == .flag) {
                                    if (findMutexConflict(spec, opt_seen, k)) |conflict_idx| {
                                        if (unknown_tail) |t| gpa.free(t);
                                        gpa.free(opt_seen);
                                        gpa.free(opt_values);
                                        own_state = false;
                                        return try makeMutexError(gpa, spec, k, conflict_idx);
                                    }
                                    opt_seen[k] = true;
                                    continue;
                                }
                                var val: []const u8 = undefined;
                                var supplied_val = true;
                                if (it.explicit) |ev| {
                                    val = ev;
                                } else if (i + 1 < argv.len and canConsumeNextValue(spec, argv[i + 1])) {
                                    i += 1;
                                    val = argv[i];
                                } else if (o.kind == .optional_value) {
                                    val = "";
                                    supplied_val = false;
                                } else {
                                    if (unknown_tail) |t| gpa.free(t);
                                    const disp = try formatOptionDisplay(gpa, o);
                                    defer gpa.free(disp);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
                                }
                                if (supplied_val) {
                                    if (try checkOptionValueAllowed(gpa, spec, o, val)) |err_out| {
                                        if (unknown_tail) |t| gpa.free(t);
                                        gpa.free(opt_seen);
                                        gpa.free(opt_values);
                                        own_state = false;
                                        return err_out;
                                    }
                                }
                                if (try validateOptionValue(gpa, spec, o, val)) |err_out| {
                                    if (unknown_tail) |t| gpa.free(t);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return err_out;
                                }
                                if (findMutexConflict(spec, opt_seen, k)) |conflict_idx| {
                                    if (unknown_tail) |t| gpa.free(t);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeMutexError(gpa, spec, k, conflict_idx);
                                }
                                opt_seen[k] = true;
                                if (o.kind == .append) {
                                    try opt_lists[k].append(gpa, val);
                                } else {
                                    opt_values[k] = val;
                                }
                            },
                        }
                    }
                    if (unknown_tail) |t| {
                        if (spec.policy.fail_fast and spec.policy.unknown == .collect) {
                            defer gpa.free(t);
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return try makeError(gpa, top_spec, "unrecognized arguments: {s}", .{t});
                        }
                        try scratch.append(gpa, t);
                        try leftovers.append(gpa, .{ .token = t, .is_positional = false, .argv_index = i });
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
                            if (o.kind == .flag) {
                                if (findMutexConflict(spec, opt_seen, k)) |conflict_idx| {
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeMutexError(gpa, spec, k, conflict_idx);
                                }
                                opt_seen[k] = true;
                            } else {
                                var val: []const u8 = "";
                                var supplied_val = false;
                                if (i + 1 < argv.len and canConsumeNextValue(spec, argv[i + 1])) {
                                    i += 1;
                                    val = argv[i];
                                    supplied_val = true;
                                } else if (o.kind != .optional_value) {
                                    const disp = try formatOptionDisplay(gpa, o);
                                    defer gpa.free(disp);
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
                                }
                                if (supplied_val) {
                                    if (try checkOptionValueAllowed(gpa, spec, o, val)) |err_out| {
                                        gpa.free(opt_seen);
                                        gpa.free(opt_values);
                                        own_state = false;
                                        return err_out;
                                    }
                                }
                                if (try validateOptionValue(gpa, spec, o, val)) |err_out| {
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return err_out;
                                }
                                if (findMutexConflict(spec, opt_seen, k)) |conflict_idx| {
                                    gpa.free(opt_seen);
                                    gpa.free(opt_values);
                                    own_state = false;
                                    return try makeMutexError(gpa, spec, k, conflict_idx);
                                }
                                opt_seen[k] = true;
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
        var force_unknown = false;
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
                        if (spec.policy.flag_explicit_as_unknown) {
                            force_unknown = true;
                        } else {
                            if (spec.policy.unknown == .ignore) continue;
                            const q = try reprToken(gpa, arg[e + 1 ..]);
                            defer gpa.free(q);
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return try makeError(gpa, spec, "argument -h/--help: ignored explicit argument {s}", .{q});
                        }
                    } else {
                        if (spec.policy.special_action == .immediate_exit) {
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.help } };
                        }
                        help_requested = true;
                        continue;
                    }
                },
                .version => {
                    if (eq) |e| {
                        if (spec.policy.flag_explicit_as_unknown) {
                            force_unknown = true;
                        } else {
                            if (spec.policy.unknown == .ignore) continue;
                            const q = try reprToken(gpa, arg[e + 1 ..]);
                            defer gpa.free(q);
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return try makeError(gpa, spec, "argument --version: ignored explicit argument {s}", .{q});
                        }
                    } else {
                        if (spec.policy.special_action == .immediate_exit) {
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return .{ .action_done = .{ .exit_code = 0, .stdout_text = spec.version.? } };
                        }
                        version_requested = true;
                        continue;
                    }
                },
                .option => |k| {
                    const o = spec.options[k];
                    if (o.kind == .flag) {
                        if (eq) |e| {
                            if (spec.policy.flag_explicit_as_unknown) {
                                force_unknown = true;
                            } else {
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
                        } else {
                            if (findMutexConflict(spec, opt_seen, k)) |conflict_idx| {
                                gpa.free(opt_seen);
                                gpa.free(opt_values);
                                own_state = false;
                                return try makeMutexError(gpa, spec, k, conflict_idx);
                            }
                            opt_seen[k] = true;
                            continue;
                        }
                    } else {
                        var val: []const u8 = undefined;
                        var supplied_val = true;
                        if (eq) |e| {
                            val = arg[e + 1 ..];
                        } else if (i + 1 < argv.len and canConsumeNextValue(spec, argv[i + 1])) {
                            i += 1;
                            val = argv[i];
                        } else if (o.kind == .optional_value) {
                            val = "";
                            supplied_val = false;
                        } else {
                            const disp = try formatOptionDisplay(gpa, o);
                            defer gpa.free(disp);
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return try makeError(gpa, spec, "argument {s}: expected one argument", .{disp});
                        }
                        if (supplied_val) {
                            if (try checkOptionValueAllowed(gpa, spec, o, val)) |err_out| {
                                gpa.free(opt_seen);
                                gpa.free(opt_values);
                                own_state = false;
                                return err_out;
                            }
                        }
                        if (try validateOptionValue(gpa, spec, o, val)) |err_out| {
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return err_out;
                        }
                        if (findMutexConflict(spec, opt_seen, k)) |conflict_idx| {
                            gpa.free(opt_seen);
                            gpa.free(opt_values);
                            own_state = false;
                            return try makeMutexError(gpa, spec, k, conflict_idx);
                        }
                        opt_seen[k] = true;
                        if (o.kind == .append) {
                            try opt_lists[k].append(gpa, val);
                        } else {
                            opt_values[k] = val;
                        }
                        continue;
                    }
                },
                .none => {},
            }
        }

        // 4. Non-option token: subcommand, remainder start, or positional.
        if (!force_unknown and !optionLike(arg, spec.policy.negative_numbers)) {
            if (has_subs) {
                sub_index = i;
                break;
            }
            if (is_remainder) {
                remainder = argv[i..];
                break;
            }
            if (arg.len == 0 and ignoresEmptyAt(spec, pos.items.len)) continue;
            if (spec.policy.fail_fast and spec.policy.unknown != .ignore) {
                if (max_fixed_pos) |max_p| if (pos.items.len >= max_p) {
                    gpa.free(opt_seen);
                    gpa.free(opt_values);
                    own_state = false;
                    return try makeError(gpa, top_spec, "unrecognized arguments: {s}", .{arg});
                };
            }
            if (try validatePositionalChoice(gpa, spec, pos.items.len, arg)) |err_out| {
                gpa.free(opt_seen);
                gpa.free(opt_values);
                own_state = false;
                return err_out;
            }
            try pos.append(gpa, arg);
            try leftovers.append(gpa, .{ .token = arg, .is_positional = true, .argv_index = i });
            continue;
        }

        // 5. Unrecognized option-like token.
        if (spec.policy.unknown == .positional) {
            if (spec.policy.fail_fast) {
                if (max_fixed_pos) |max_p| if (pos.items.len >= max_p) {
                    gpa.free(opt_seen);
                    gpa.free(opt_values);
                    own_state = false;
                    return try makeError(gpa, top_spec, "unrecognized arguments: {s}", .{arg});
                };
            }
            if (try validatePositionalChoice(gpa, spec, pos.items.len, arg)) |err_out| {
                gpa.free(opt_seen);
                gpa.free(opt_values);
                own_state = false;
                return err_out;
            }
            try pos.append(gpa, arg);
            try leftovers.append(gpa, .{ .token = arg, .is_positional = true, .argv_index = i });
            continue;
        }
        if (spec.policy.fail_fast and spec.policy.unknown == .collect) {
            gpa.free(opt_seen);
            gpa.free(opt_values);
            own_state = false;
            return try makeError(gpa, top_spec, "unrecognized arguments: {s}", .{arg});
        }
        try leftovers.append(gpa, .{ .token = arg, .is_positional = false, .argv_index = i });
    }

    // Subcommand dispatch when this parser defines subcommands.
    if (has_subs) {
        const idx = sub_index orelse argv.len;
        if (idx >= argv.len) {
            if (spec.policy.unknown_before_required and spec.policy.unknown != .ignore and leftovers.items.len > 0) {
                if (try checkUnrecognized(gpa, top_spec, top_extra, leftovers.items, 0, true, false)) |err_out| {
                    gpa.free(opt_seen);
                    gpa.free(opt_values);
                    own_state = false;
                    return err_out;
                }
            }
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

    // When unknown_before_required is enabled, report unknown options and excess
    // positionals before missing required arguments.
    if (spec.policy.unknown_before_required and spec.policy.unknown != .ignore) {
        const variadic = hasVariadicPositional(spec);
        const pos_slots = nonRemainderPositionals(spec);
        const consumed_pos = if (variadic) pos.items.len else @min(pos.items.len, pos_slots);
        const keep_sep = !variadic and pos_slots == 0 and !is_remainder;
        if (try checkUnrecognized(gpa, top_spec, top_extra, leftovers.items, consumed_pos, keep_sep, variadic)) |err_out| {
            gpa.free(opt_seen);
            gpa.free(opt_values);
            own_state = false;
            return err_out;
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
        if (p.arity == .required_one or p.arity == .one_or_more) {
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

    // Check merged unrecognized arguments unless unknown tokens are ignored
    // (or already checked above).
    if (!spec.policy.unknown_before_required and spec.policy.unknown != .ignore) {
        const variadic = hasVariadicPositional(spec);
        const pos_slots = nonRemainderPositionals(spec);
        const consumed_pos = if (variadic) pos.items.len else @min(pos.items.len, pos_slots);
        const keep_sep = !variadic and pos_slots == 0 and !is_remainder;
        if (try checkUnrecognized(gpa, top_spec, top_extra, leftovers.items, consumed_pos, keep_sep, variadic)) |err_out| {
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
