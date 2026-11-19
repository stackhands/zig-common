//! The environment as the C library sees it: raw bytes, no encoding assumed,
//! and when a name appears twice the first entry wins, as getenv(3) returns
//! it. A child's environment is built from it with the later duplicates
//! dropped, so the child cannot see a different value than this process did.
const std = @import("std");

const Allocator = std.mem.Allocator;
/// An environment block as execve(2) takes it: NUL-terminated
/// `NAME=value` strings, ended by a null pointer.
pub const Envp = [*:null]const ?[*:0]const u8;

/// True for a name the shell accepts: [A-Za-z_][A-Za-z0-9_]*.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn split(entry: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    const eq = std.mem.findScalar(u8, entry, '=') orelse return .{ .name = entry, .value = null };
    return .{ .name = entry[0..eq], .value = entry[eq + 1 ..] };
}

/// A read-only view of an environment block.
pub const Env = struct {
    /// The block's strings in order. An entry with no `=` is kept here and
    /// is not a variable.
    entries: []const [*:0]const u8,

    /// A view of `envp` up to its null pointer. Nothing is copied: the view
    /// is valid while the block is.
    pub fn fromEnvp(envp: Envp) Env {
        var n: usize = 0;
        while (envp[n] != null) n += 1;
        return .{ .entries = @ptrCast(envp[0..n]) };
    }

    /// The first entry for `name`, as getenv(3) returns it. An entry with
    /// no '=' is not a variable.
    pub fn get(e: Env, name: []const u8) ?[]const u8 {
        for (e.entries) |p| {
            const s = split(std.mem.span(p));
            if (s.value != null and std.mem.eql(u8, s.name, name)) return s.value;
        }
        return null;
    }

    /// Names that appear more than once, each once, in first-seen order.
    pub fn duplicates(e: Env, gpa: Allocator) Allocator.Error![]const []const u8 {
        var seen: std.StringHashMapUnmanaged(u8) = .empty;
        defer seen.deinit(gpa);
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (e.entries) |p| {
            const s = split(std.mem.span(p));
            if (s.value == null) continue;
            const r = try seen.getOrPut(gpa, s.name);
            if (!r.found_existing) {
                r.value_ptr.* = 1;
            } else if (r.value_ptr.* == 1) {
                r.value_ptr.* = 2;
                try out.append(gpa, s.name);
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// A child environment: the parent's first entries in their order, then
/// changes. Every name appears once.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    names: std.ArrayList([]const u8) = .empty,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// An empty environment. What it stores comes from an arena over
    /// `gpa`, which `deinit` frees.
    pub fn init(gpa: Allocator) Builder {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Free every name, value and block the builder made, the blocks
    /// `envp` returned included.
    pub fn deinit(b: *Builder) void {
        b.arena.deinit();
    }

    /// Start from `e`, keeping the first entry of each name.
    pub fn fromEnv(gpa: Allocator, e: Env) Allocator.Error!Builder {
        var b = init(gpa);
        errdefer b.deinit();
        for (e.entries) |p| {
            const s = split(std.mem.span(p));
            const v = s.value orelse continue;
            if (b.values.contains(s.name)) continue;
            try b.set(s.name, v);
        }
        return b;
    }

    /// Set `name` to `value`, both copied. A name already set keeps its
    /// place in the order; a new name goes last. The name is checked only
    /// when `envp` builds the block.
    pub fn set(b: *Builder, name: []const u8, value: []const u8) Allocator.Error!void {
        const a = b.arena.allocator();
        const v = try a.dupe(u8, value);
        if (b.values.getPtr(name)) |slot| {
            slot.* = v;
            return;
        }
        const n = try a.dupe(u8, name);
        try b.names.append(a, n);
        try b.values.put(a, n, v);
    }

    /// Remove `name`. A name that is not set is no error.
    pub fn unset(b: *Builder, name: []const u8) void {
        if (!b.values.remove(name)) return;
        for (b.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            _ = b.names.orderedRemove(i);
            return;
        };
    }

    /// The value `name` has in the builder, or null when it is not set.
    pub fn get(b: *const Builder, name: []const u8) ?[]const u8 {
        return b.values.get(name);
    }

    /// A NULL-terminated block for execve, valid until `deinit`. An empty
    /// name, a name with "=", or a NUL byte anywhere cannot be passed and is
    /// an error.
    pub fn envp(b: *Builder) (Allocator.Error || error{InvalidArgument})!Envp {
        const a = b.arena.allocator();
        const block = try a.allocSentinel(?[*:0]const u8, b.names.items.len, null);
        for (b.names.items, 0..) |n, i| {
            const v = b.values.get(n).?;
            // A NUL ends the entry early and an "=" in the name moves the
            // split, so either would pass another variable than asked.
            if (n.len == 0 or std.mem.findScalar(u8, n, '=') != null or std.mem.findScalar(u8, n, 0) != null or std.mem.findScalar(u8, v, 0) != null) return error.InvalidArgument;
            const entry = try a.allocSentinel(u8, n.len + 1 + v.len, 0);
            @memcpy(entry[0..n.len], n);
            entry[n.len] = '=';
            @memcpy(entry[n.len + 1 ..], v);
            block[i] = entry.ptr;
        }
        return block.ptr;
    }

    /// The difference from this builder to `to`.
    /// `Diff.patch` of the result onto this builder sets the names and
    /// values `to` has. `Diff.reverse` of the result, patched onto `to`,
    /// restores the names and values here.
    pub fn diff(from: *const Builder, gpa: Allocator, to: *const Builder) Allocator.Error!Diff {
        var d = Diff{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .prev = &.{},
            .next = &.{},
        };
        errdefer d.deinit();
        const a = d.arena.allocator();
        var prev: std.ArrayList(Change) = .empty;
        var next: std.ArrayList(Change) = .empty;
        for (from.names.items) |name| {
            const old = from.values.get(name).?;
            const fresh = to.get(name);
            if (fresh == null or !std.mem.eql(u8, old, fresh.?)) {
                try prev.append(a, .{
                    .name = try a.dupe(u8, name),
                    .value = try a.dupe(u8, old),
                });
            }
        }
        for (to.names.items) |name| {
            const fresh = to.values.get(name).?;
            const old = from.get(name);
            if (old == null or !std.mem.eql(u8, old.?, fresh)) {
                try next.append(a, .{
                    .name = try a.dupe(u8, name),
                    .value = try a.dupe(u8, fresh),
                });
            }
        }
        d.prev = try prev.toOwnedSlice(a);
        d.next = try next.toOwnedSlice(a);
        return d;
    }
};

/// One name and the bytes it held on one side of a diff.
pub const Change = struct {
    name: []const u8,
    value: []const u8,
};

/// The names whose values differ between two builders.
/// `prev` holds the starting value. `next` holds the resulting value.
/// A name only the start had is in `prev` alone. A name only the result
/// had is in `next` alone. A name both set to the same bytes is in neither.
pub const Diff = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    prev: []const Change,
    next: []const Change,

    /// Free the copies this diff made.
    pub fn deinit(d: *Diff) void {
        d.arena.deinit();
    }

    /// The same change read the other way: `prev` and `next` exchange places.
    pub fn reverse(d: *const Diff) Allocator.Error!Diff {
        var out = Diff{
            .gpa = d.gpa,
            .arena = std.heap.ArenaAllocator.init(d.gpa),
            .prev = &.{},
            .next = &.{},
        };
        errdefer out.deinit();
        const a = out.arena.allocator();
        var prev: std.ArrayList(Change) = .empty;
        var next: std.ArrayList(Change) = .empty;
        for (d.next) |c| try prev.append(a, .{ .name = try a.dupe(u8, c.name), .value = try a.dupe(u8, c.value) });
        for (d.prev) |c| try next.append(a, .{ .name = try a.dupe(u8, c.name), .value = try a.dupe(u8, c.value) });
        out.prev = try prev.toOwnedSlice(a);
        out.next = try next.toOwnedSlice(a);
        return out;
    }

    /// Apply this diff to `b`. A name in `prev` that `next` omits is
    /// removed. Every name in `next` is set, and one already present keeps
    /// its place.
    pub fn patch(d: *const Diff, b: *Builder) Allocator.Error!void {
        for (d.prev) |c| {
            var kept = false;
            for (d.next) |n| if (std.mem.eql(u8, n.name, c.name)) {
                kept = true;
                break;
            };
            if (!kept) b.unset(c.name);
        }
        for (d.next) |c| try b.set(c.name, c.value);
    }
};

fn sameValues(a: *const Builder, b: *const Builder) !void {
    try std.testing.expectEqual(a.names.items.len, b.names.items.len);
    for (a.names.items) |n| {
        try std.testing.expect(b.get(n) != null);
        try std.testing.expectEqualSlices(u8, a.get(n).?, b.get(n).?);
    }
}

test "first entry wins and later duplicates are dropped" {
    const gpa = std.testing.allocator;
    const raw = [_:null]?[*:0]const u8{ "A=1", "NOEQ", "B=x\xff", "A=2", "B=y", "A=3" };
    const e = Env.fromEnvp(&raw);
    try std.testing.expectEqualStrings("1", e.get("A").?);
    try std.testing.expectEqualStrings("x\xff", e.get("B").?);
    try std.testing.expect(e.get("NOEQ") == null);
    const d = try e.duplicates(gpa);
    defer gpa.free(d);
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expectEqualStrings("A", d[0]);

    var b = try Builder.fromEnv(gpa, e);
    defer b.deinit();
    try b.set("C", "new");
    b.unset("B");
    try b.set("A", "set");
    const block = try b.envp();
    const child = Env.fromEnvp(block);
    try std.testing.expectEqual(@as(usize, 2), child.entries.len);
    try std.testing.expectEqualStrings("A=set", std.mem.span(child.entries[0]));
    try std.testing.expectEqualStrings("C=new", std.mem.span(child.entries[1]));
}

test "validName" {
    try std.testing.expect(validName("_A1"));
    try std.testing.expect(!validName("1A"));
    try std.testing.expect(!validName("A-B"));
    try std.testing.expect(!validName(""));
}

test "patch applies a diff and reverse restores the other side" {
    const gpa = std.testing.allocator;
    var from = Builder.init(gpa);
    defer from.deinit();
    try from.set("A", "1");
    try from.set("B", "x\xff");
    var to = Builder.init(gpa);
    defer to.deinit();
    try to.set("B", "3");
    try to.set("C", "4");

    var forward = try from.diff(gpa, &to);
    defer forward.deinit();
    try std.testing.expectEqual(@as(usize, 2), forward.prev.len);
    try std.testing.expectEqualStrings("A", forward.prev[0].name);
    try std.testing.expectEqualStrings("1", forward.prev[0].value);
    try std.testing.expectEqualStrings("B", forward.prev[1].name);
    try std.testing.expectEqualSlices(u8, "x\xff", forward.prev[1].value);
    try std.testing.expectEqual(@as(usize, 2), forward.next.len);
    try std.testing.expectEqualStrings("B", forward.next[0].name);
    try std.testing.expectEqualStrings("3", forward.next[0].value);
    try std.testing.expectEqualStrings("C", forward.next[1].name);

    var applied = Builder.init(gpa);
    defer applied.deinit();
    try applied.set("A", "1");
    try applied.set("B", "x\xff");
    try forward.patch(&applied);
    try sameValues(&to, &applied);
    try std.testing.expectEqualStrings("B", applied.names.items[0]);
    try std.testing.expectEqualStrings("C", applied.names.items[1]);

    var backward = try forward.reverse();
    defer backward.deinit();
    var restored = Builder.init(gpa);
    defer restored.deinit();
    try restored.set("B", "3");
    try restored.set("C", "4");
    try backward.patch(&restored);
    try sameValues(&from, &restored);
    try std.testing.expectEqualStrings("B", restored.names.items[0]);
    try std.testing.expectEqualStrings("A", restored.names.items[1]);
}

test "a diff of two equal builders is empty and an update keeps its place" {
    const gpa = std.testing.allocator;
    var from = Builder.init(gpa);
    defer from.deinit();
    try from.set("A", "");
    try from.set("B", "2");
    var same = try from.diff(gpa, &from);
    defer same.deinit();
    try std.testing.expectEqual(@as(usize, 0), same.prev.len);
    try std.testing.expectEqual(@as(usize, 0), same.next.len);
    try same.patch(&from);
    try std.testing.expectEqualStrings("", from.get("A").?);

    var to = Builder.init(gpa);
    defer to.deinit();
    try to.set("A", "9");
    try to.set("B", "2");
    var forward = try from.diff(gpa, &to);
    defer forward.deinit();
    try forward.patch(&from);
    try std.testing.expectEqualStrings("A", from.names.items[0]);
    try std.testing.expectEqualStrings("9", from.get("A").?);
    try std.testing.expectEqualStrings("2", from.get("B").?);

    var back = try forward.reverse();
    defer back.deinit();
    try back.patch(&to);
    try std.testing.expectEqualStrings("", to.get("A").?);
    try std.testing.expectEqualStrings("2", to.get("B").?);
    try std.testing.expectEqualStrings("A", to.names.items[0]);
}

test "a name the execve block cannot carry is refused" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    try b.set("A=B", "x");
    try std.testing.expectError(error.InvalidArgument, b.envp());
    var c = Builder.init(std.testing.allocator);
    defer c.deinit();
    try c.set("", "x");
    try std.testing.expectError(error.InvalidArgument, c.envp());
    var d = Builder.init(std.testing.allocator);
    defer d.deinit();
    try d.set("BASH_FUNC_f%%", "() { :; }");
    _ = try d.envp();
}
