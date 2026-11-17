const std = @import("std");
const common = @import("zig_common");

const json_fixture =
    \\{"kind":"tool-result","ok":true,"elapsed":1.25,"paths":["a.log","b.log","bad\udcff"],"details":{"attempts":3,"reason":null}}
;

const log_list_fixture =
    \\/run/alpha.log
    \\/run/beta.log
    \\/run/gamma.log
    \\/run/delta.log
    \\/run/epsilon.log
    \\/run/zeta.log
    \\/run/eta.log
    \\/run/theta.log
    \\/run/iota.log
    \\/run/kappa.log
;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) return error.InvalidArguments;

    const checksum = if (std.mem.eql(u8, args[1], "json-parse"))
        try jsonParse()
    else if (std.mem.eql(u8, args[1], "json-round-trip"))
        try jsonRoundTrip()
    else if (std.mem.eql(u8, args[1], "python-text-split"))
        try pythonTextSplit()
    else if (std.mem.eql(u8, args[1], "shell-quote"))
        try shellQuote()
    else if (std.mem.eql(u8, args[1], "log-list-rename"))
        try logListRename()
    else
        return error.InvalidArguments;

    common.cli.out("{d}\n", .{checksum});
}

fn jsonParse() !usize {
    var checksum: usize = 0;
    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const value = try common.json.parse(arena.allocator(), json_fixture);
        checksum +%= value.get("paths").?.array.len;
        checksum +%= value.get("details").?.object.len;
    }
    return checksum;
}

fn jsonRoundTrip() !usize {
    var checksum: usize = 0;
    for (0..200) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const value = try common.json.parse(allocator, json_fixture);
        const rendered = try common.json.dumps(
            allocator,
            try common.json.toPy(allocator, value),
            2,
            true,
        );
        checksum +%= rendered.len;
    }
    return checksum;
}

fn pythonTextSplit() !usize {
    const fixture = "\u{3000}avx\u{a0}waitpkg  x\xff alpha beta gamma\n";
    var checksum: usize = 0;
    for (0..2000) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const parts = try common.pytext.pySplit(arena.allocator(), fixture);
        checksum +%= parts.len;
    }
    return checksum;
}

fn shellQuote() !usize {
    const values = [_][]const u8{
        "",
        "/tmp/plain.log",
        "two words",
        "it's quoted",
        "x\xff",
    };
    var checksum: usize = 0;
    for (0..4000) |_| {
        for (values) |value| {
            const quoted = try common.pytext.shellQuote(std.heap.page_allocator, value);
            checksum +%= quoted.len;
            std.heap.page_allocator.free(quoted);
        }
    }
    return checksum;
}

fn logListRename() !usize {
    const gpa = std.heap.page_allocator;
    var renames: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer renames.deinit(gpa);
    try renames.put(gpa, "/run/beta.log", "/run/beta.log.gz");
    try renames.put(gpa, "/run/epsilon.log", "/run/epsilon.log.gz");
    try renames.put(gpa, "/run/theta.log", "/run/theta.log.gz");

    var checksum: usize = 0;
    for (0..1000) |_| {
        const renamed = (try common.logs.renameInList(gpa, log_list_fixture, &renames)).?;
        checksum +%= renamed.len;
        gpa.free(renamed);
    }
    return checksum;
}
