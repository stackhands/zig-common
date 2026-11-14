//! The environment as the C library sees it: raw bytes, no encoding assumed,
//! and when a name appears twice the first entry wins, as getenv(3) returns
//! it. A child's environment is built from it with the later duplicates
//! dropped, so the child cannot see a different value than this process did.
const std = @import("std");

const Allocator = std.mem.Allocator;
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
    entries: []const [*:0]const u8,

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

    pub fn init(gpa: Allocator) Builder {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

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

    pub fn unset(b: *Builder, name: []const u8) void {
        if (!b.values.remove(name)) return;
        for (b.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            _ = b.names.orderedRemove(i);
            return;
        };
    }

    pub fn get(b: *const Builder, name: []const u8) ?[]const u8 {
        return b.values.get(name);
    }

    /// A NULL-terminated block for execve, valid until `deinit`. Names or
    /// values with a NUL byte cannot be passed and are an error.
    pub fn envp(b: *Builder) (Allocator.Error || error{InvalidArgument})!Envp {
        const a = b.arena.allocator();
        const block = try a.allocSentinel(?[*:0]const u8, b.names.items.len, null);
        for (b.names.items, 0..) |n, i| {
            const v = b.values.get(n).?;
            if (std.mem.findScalar(u8, n, 0) != null or std.mem.findScalar(u8, v, 0) != null) return error.InvalidArgument;
            const entry = try a.allocSentinel(u8, n.len + 1 + v.len, 0);
            @memcpy(entry[0..n.len], n);
            entry[n.len] = '=';
            @memcpy(entry[n.len + 1 ..], v);
            block[i] = entry.ptr;
        }
        return block.ptr;
    }
};

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
