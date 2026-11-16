//! Log files: gzip in place as `gzip -9` does, and the `.licensed-logs`
//! list that names log files which may carry a licence number.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fsx = @import("fsx.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

pub const licensed_list = ".licensed-logs";

pub const GzipError = sys.Error || Allocator.Error || error{WriteFailed};

/// Replace `dir/name` with `dir/name.gz`, as `gzip -9 name` does: the header
/// carries the original name and modification time, the compressed file
/// gets the original's owner (when this process may set it), permission
/// bits and access and modification times, and the original is removed.
/// A file with other hard links, a symbolic link, a non-regular file and an
/// existing `name.gz` are refused, as gzip refuses them.
pub fn gzipInPlace(gpa: Allocator, io: Io, dir: fsx.fd_t, name: []const u8) GzipError!void {
    const src = try fsx.openRegular(dir, name, false);
    defer sys.close(src.fd);
    if (src.stat.nlink > 1) return error.TooManyLinks;

    const gz_name = try gpa.print("{s}.gz", .{name});
    defer gpa.free(gz_name);
    // Refuse an existing archive before creating anything, as gzip does.
    // The bytes then go to a temporary name, so a crash or a short write
    // cannot leave a partial `name.gz` that a later run skips.
    if (fsx.statAt(dir, gz_name, false)) |_| return error.Exists else |err| switch (err) {
        error.NotFound => {},
        else => |e| return e,
    }
    var rnd: [4]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
    const tmp_name = try gpa.print(".{s}.{d}.{x:0>8}.tmp", .{ gz_name, linux.getpid(), std.mem.readInt(u32, &rnd, .little) });
    defer gpa.free(tmp_name);
    const dst = try sys.openat(dir, tmp_name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, 0o600);
    var done = false;
    defer {
        sys.close(dst);
        if (!done) sys.unlinkat(dir, tmp_name, 0) catch {};
    }

    const file: Io.File = .{ .handle = dst, .flags = .{ .nonblocking = false } };
    var out_buf: [64 * 1024]u8 = undefined;
    var out = file.writerStreaming(io, &out_buf);
    const w = &out.interface;

    // RFC 1952 header: FNAME set, MTIME from the file, XFL 2 (best
    // compression), OS 3 (Unix).
    const base = std.fs.path.basename(name);
    var hdr: [10]u8 = .{ 0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 2, 3 };
    const mtime: u32 = if (src.stat.mtime.sec > 0 and src.stat.mtime.sec <= std.math.maxInt(u32)) @intCast(src.stat.mtime.sec) else 0;
    std.mem.writeInt(u32, hdr[4..8], mtime, .little);
    try w.writeAll(&hdr);
    try w.writeAll(base);
    try w.writeByte(0);

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compress = try flate.Compress.init(w, window, .raw, .best);

    var crc = std.hash.Crc32.init();
    var size: u64 = 0;
    var in_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(src.fd, &in_buf);
        if (n == 0) break;
        crc.update(in_buf[0..n]);
        size += n;
        try compress.writer.writeAll(in_buf[0..n]);
    }
    try compress.finish();
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], crc.final(), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(size), .little);
    try w.writeAll(&trailer);
    try w.flush();

    sys.fchown(dst, src.stat.uid, src.stat.gid) catch |err| switch (err) {
        error.AccessDenied => {},
        else => return err,
    };
    try sys.fchmod(dst, @intCast(src.stat.perm()));
    const times = [2]linux.timespec{ src.stat.atime, src.stat.mtime };
    _ = try sys.call(linux.futimens, .{ dst, &times });
    try sys.fsync(dst);
    try sys.renameat(dir, tmp_name, dir, gz_name);
    sys.unlinkat(dir, name, 0) catch |err| {
        // The archive is complete, but the original is still there. Drop
        // the archive so a retry compresses the original instead of
        // skipping an existing .gz and leaving both.
        sys.unlinkat(dir, gz_name, 0) catch {};
        return err;
    };
    done = true;
    try sys.fsync(dir);
}

/// The lines of a `.licensed-logs` list with every line found in `renames`
/// replaced by its value; every line ends in a newline, as awk prints it.
/// Null when no line changed.
pub fn renameInList(gpa: Allocator, content: []const u8, renames: *const std.StringHashMapUnmanaged([]const u8)) Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var changed = false;
    const body = if (content.len > 0 and content[content.len - 1] == '\n') content[0 .. content.len - 1] else content;
    if (content.len > 0) {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            if (renames.get(line)) |to| {
                try out.appendSlice(gpa, to);
                changed = true;
            } else try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    if (!changed) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn archiveIntact(path: [*:0]const u8) bool {
    const pid: isize = @bitCast(linux.fork());
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "gzip", "-t", path, null };
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve("/usr/bin/gzip", &argv, &envp);
        linux.exit_group(127);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), @ptrCast(&status), 0, null);
    return linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0;
}

test "gzip does not publish a partial archive under the final name" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/zig-common-gzip-{d}", .{ here, linux.getpid() });
    defer gpa.free(base);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(dir);
    }
    const src = try sys.openat(dir, "a.log", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    const ur = try sys.openat(fsx.cwd, "/dev/urandom", .{}, 0);
    defer sys.close(ur);
    var buf: [64 * 1024]u8 = undefined;
    var left: usize = 6 << 20;
    while (left > 0) {
        const n = try sys.read(ur, buf[0..@min(buf.len, left)]);
        if (n == 0) return error.Unexpected;
        try sys.writeAll(src, buf[0..n]);
        left -= n;
    }
    sys.close(src);
    const gz = try std.fmt.allocPrint(gpa, "{s}/a.log.gz", .{base});
    defer gpa.free(gz);
    var gz_z: [sys.path_max:0]u8 = undefined;
    const gz_sent = try sys.z(&gz_z, gz);

    const Watch = struct {
        var stop = std.atomic.Value(bool).init(false);
        var partial = std.atomic.Value(bool).init(false);
        var path: [*:0]const u8 = undefined;
        fn run() void {
            while (!stop.load(.acquire)) {
                if (fsx.statAt(fsx.cwd, std.mem.span(path), false)) |_| {
                    if (!archiveIntact(path)) partial.store(true, .release);
                } else |_| {}
                var ts: linux.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
            }
        }
    };
    Watch.path = gz_sent.ptr;
    Watch.stop.store(false, .release);
    Watch.partial.store(false, .release);
    const watch = try std.Thread.spawn(.{}, Watch.run, .{});
    const io = std.Io.Threaded.global_single_threaded.io();
    try gzipInPlace(gpa, io, dir, "a.log");
    Watch.stop.store(true, .release);
    watch.join();
    try std.testing.expect(!Watch.partial.load(.acquire));
    try std.testing.expect(archiveIntact(gz_sent.ptr));
    try std.testing.expectError(error.NotFound, fsx.statAt(dir, "a.log", false));
}

test "renameInList" {
    const gpa = std.testing.allocator;
    var m: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer m.deinit(gpa);
    try m.put(gpa, "/r/a.log", "/r/a.log.gz");
    const got = (try renameInList(gpa, "/r/a.log\n/r/b.log", &m)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/r/a.log.gz\n/r/b.log\n", got);
    try std.testing.expect((try renameInList(gpa, "/r/b.log\n", &m)) == null);
}
