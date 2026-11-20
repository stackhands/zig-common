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
