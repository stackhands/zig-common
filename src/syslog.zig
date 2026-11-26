//! Best-effort RFC 5424 syslog and native systemd-journald event emitter:
//! a target (`unix:`, `journal:`, `udp:` or `tcp:`), the two wire formats, and
//! one send with a timeout. A tool builds its own events on top. Sending never
//! fails the caller: an unreachable collector is the collector's problem.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;

pub const Scheme = enum {
    rfc5424_unix,
    journal_unix,
    rfc5424_udp,
    rfc5424_tcp,
};

/// IANA documentation Private Enterprise Number (RFC 5398 / RFC 5424 section 6.3.2),
/// used as the default SD-ID suffix until a site or project PEN is assigned.
pub const default_pen = "32473";

pub const Target = struct {
    scheme: Scheme,
    host_or_path: []const u8,
    port: u16 = 0,
    pen: []const u8 = default_pen,
};

pub fn parsePen(raw: []const u8) ?[]const u8 {
    const s = trimWs(raw);
    if (s.len == 0 or s.len > 20) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    const trimmed = std.mem.trimStart(u8, s, "0");
    if (trimmed.len == 0) return null;
    _ = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    return trimmed;
}

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const JournalField = struct {
    key: []const u8,
    value: []const u8,
};

/// Who an event is from: the program name of the syslog header and of
/// journald's SYSLOG_IDENTIFIER, and the name in front of the enterprise
/// number in the structured-data identifier (`ebKeepLogs@32473`).
pub const Identity = struct {
    app: []const u8,
    sd_name: []const u8,
};

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
}

fn hasControl(s: []const u8) bool {
    for (s) |ch| if (ch < 32 or ch == 127) return true;
    return false;
}

fn oneLine(arena: Allocator, raw: []const u8, limit: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |ch| {
        if (ch < 32 or ch == 127) {
            try out.append(arena, ' ');
        } else {
            try out.append(arena, ch);
        }
        if (out.items.len >= limit) break;
    }
    return out.items;
}

fn splitHostPort(addr: []const u8) ?struct { host: []const u8, port: u16 } {
    if (addr.len == 0) return null;
    var host: []const u8 = "";
    var port_s: []const u8 = "";
    if (addr[0] == '[') {
        const end = std.mem.findScalar(u8, addr, ']') orelse return null;
        if (end + 2 > addr.len or addr[end + 1] != ':') return null;
        host = addr[1..end];
        port_s = addr[end + 2 ..];
    } else {
        const colon = std.mem.findScalarLast(u8, addr, ':') orelse return null;
        host = addr[0..colon];
        port_s = addr[colon + 1 ..];
    }
    if (host.len == 0 or port_s.len == 0) return null;
    for (port_s) |c| if (!std.ascii.isDigit(c)) return null;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    if (port == 0) return null;
    return .{ .host = host, .port = port };
}

pub fn parseTarget(raw: []const u8) ?Target {
    const s = trimWs(raw);
    if (s.len == 0 or hasControl(s)) return null;
    if (std.mem.eql(u8, s, "syslog")) return .{ .scheme = .rfc5424_unix, .host_or_path = "/dev/log" };
    if (std.mem.eql(u8, s, "journald") or std.mem.eql(u8, s, "journal"))
        return .{ .scheme = .journal_unix, .host_or_path = "/run/systemd/journal/socket" };
    if (s[0] == '/') return .{ .scheme = .rfc5424_unix, .host_or_path = s };
    if (std.mem.startsWith(u8, s, "unix://")) {
        const path = s["unix://".len..];
        if (path.len == 0 or path[0] != '/') return null;
        return .{ .scheme = .rfc5424_unix, .host_or_path = path };
    }
    if (std.mem.startsWith(u8, s, "journal+unix://")) {
        const path = s["journal+unix://".len..];
        if (path.len == 0 or path[0] != '/') return null;
        return .{ .scheme = .journal_unix, .host_or_path = path };
    }
    if (std.mem.startsWith(u8, s, "udp://")) {
        const hp = splitHostPort(s["udp://".len..]) orelse return null;
        return .{ .scheme = .rfc5424_udp, .host_or_path = hp.host, .port = hp.port };
    }
    if (std.mem.startsWith(u8, s, "tcp://")) {
        const hp = splitHostPort(s["tcp://".len..]) orelse return null;
        return .{ .scheme = .rfc5424_tcp, .host_or_path = hp.host, .port = hp.port };
    }
    return null;
}

fn sdEscape(arena: Allocator, value: []const u8) Allocator.Error![]u8 {
    const clean = try oneLine(arena, value, 256);
    var out: std.ArrayList(u8) = .empty;
    for (clean) |ch| {
        if (ch == '\\' or ch == '"' or ch == ']') try out.append(arena, '\\');
        try out.append(arena, ch);
    }
    return out.items;
}

fn rfc5424Token(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |ch| {
        if (ch >= 33 and ch <= 126) {
            try out.append(arena, ch);
            if (out.items.len == 255) break;
        }
    }
    if (out.items.len == 0) return "-";
    return out.items;
}

fn hostname(arena: Allocator) []const u8 {
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return "-";
    const raw = std.mem.sliceTo(&uts.nodename, 0);
    return rfc5424Token(arena, raw) catch "-";
}

fn utcTimestamp(arena: Allocator) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const secs: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const usec: u32 = if (ts.nsec >= 0) @intCast(@divTrunc(ts.nsec, 1000)) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return arena.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z", .{
        day.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        usec,
    }) catch "1970-01-01T00:00:00.000000Z";
}

/// One RFC 5424 message from `id`: header, one structured-data element
/// `[<sd_name>@<pen> key="value"...]`, and `msg` on one line.
pub fn formatRfc5424For(
    arena: Allocator,
    id: Identity,
    severity: u8,
    msgid: []const u8,
    params: []const Param,
    msg: []const u8,
    pen: []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const pri: u8 = 8 + severity;
    const ts = utcTimestamp(arena);
    const host = hostname(arena);
    const pid = linux.getpid();
    try out.print(arena, "<{d}>1 {s} {s} {s} {d} {s} [{s}@{s}", .{
        pri, ts, host, id.app, pid, msgid, id.sd_name, pen,
    });
    for (params) |p| {
        const esc = try sdEscape(arena, p.value);
        try out.print(arena, " {s}=\"{s}\"", .{ p.key, esc });
    }
    const clean_msg = try oneLine(arena, msg, 500);
    try out.print(arena, "] {s}", .{clean_msg});
    return out.items;
}

fn journalKv(arena: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) Allocator.Error!void {
    if (std.mem.findAny(u8, value, "\n\x00") != null) {
        try out.appendSlice(arena, key);
        try out.append(arena, '\n');
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, value.len, .little);
        try out.appendSlice(arena, &len_buf);
        try out.appendSlice(arena, value);
        try out.append(arena, '\n');
    } else {
        try out.print(arena, "{s}={s}\n", .{ key, value });
    }
}

/// One native journald datagram from `id`: MESSAGE, PRIORITY,
/// SYSLOG_IDENTIFIER, SYSLOG_FACILITY, MSGID, then `fields` with a value.
pub fn formatJournaldFor(
    arena: Allocator,
    id: Identity,
    severity: u8,
    msgid: []const u8,
    fields: []const JournalField,
    msg: []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var sev_buf: [4]u8 = undefined;
    const sev_s = std.fmt.bufPrint(&sev_buf, "{d}", .{severity}) catch "6";
    try journalKv(arena, &out, "MESSAGE", try oneLine(arena, msg, 500));
    try journalKv(arena, &out, "PRIORITY", sev_s);
    try journalKv(arena, &out, "SYSLOG_IDENTIFIER", id.app);
    try journalKv(arena, &out, "SYSLOG_FACILITY", "1");
    try journalKv(arena, &out, "MSGID", msgid);
    for (fields) |f| {
        if (f.value.len == 0) continue;
        try journalKv(arena, &out, f.key, try oneLine(arena, f.value, 500));
    }
    return out.items;
}

fn setSockTimeout(fd: linux.fd_t) void {
    const tv: linux.timeval = .{ .sec = 0, .usec = 500_000 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
}

fn sendAllFd(fd: linux.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, 0, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += rc;
            },
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn sendUnixOnce(path: []const u8, sock_type: u32, payload: []const u8) bool {
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..path.len], path);
    const addr_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    const s_rc = linux.socket(linux.AF.UNIX, sock_type | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(s_rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(s_rc);
    defer sys.close(fd);
    setSockTimeout(fd);
    while (true) {
        const c_rc = unixConnect(fd, &addr, addr_len);
        switch (linux.errno(c_rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return false,
        }
    }
    return sendAllFd(fd, payload);
}

/// Replacement for the unix `connect` above. Null calls the kernel. Tests
/// point it at a function that returns an errno, so `send` does not wait on
/// a socket nobody listens on.
var test_unix_connect: ?*const fn (fd: linux.fd_t, addr: *const anyopaque, len: linux.socklen_t) usize = null;

fn unixConnect(fd: linux.fd_t, addr: *const linux.sockaddr.un, len: linux.socklen_t) usize {
    if (test_unix_connect) |hook| return hook(fd, @ptrCast(addr), len);
    return linux.connect(fd, @ptrCast(addr), len);
}

fn sendUnix(arena: Allocator, path: []const u8, payload: []const u8, stream_nl: bool) bool {
    if (sendUnixOnce(path, linux.SOCK.DGRAM, payload)) return true;
    if (!stream_nl) return false;
    const framed = arena.print("{s}\n", .{payload}) catch return false;
    return sendUnixOnce(path, linux.SOCK.STREAM, framed);
}

fn sendUdpIp(ip: net.IpAddress, payload: []const u8) bool {
    switch (ip) {
        .ip4 => |ip4| {
            const s_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, linux.IPPROTO.UDP);
            if (linux.errno(s_rc) != .SUCCESS) return false;
            const fd: linux.fd_t = @intCast(s_rc);
            defer sys.close(fd);
            setSockTimeout(fd);
            var sa: linux.sockaddr.in = .{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            while (true) {
                const rc = linux.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
                switch (linux.errno(rc)) {
                    .SUCCESS => return rc == payload.len,
                    .INTR => continue,
                    else => return false,
                }
            }
        },
        .ip6 => |ip6| {
            const s_rc = linux.socket(linux.AF.INET6, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, linux.IPPROTO.UDP);
            if (linux.errno(s_rc) != .SUCCESS) return false;
            const fd: linux.fd_t = @intCast(s_rc);
            defer sys.close(fd);
            setSockTimeout(fd);
            var sa: linux.sockaddr.in6 = .{
                .family = linux.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = 0,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            while (true) {
                const rc = linux.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6));
                switch (linux.errno(rc)) {
                    .SUCCESS => return rc == payload.len,
                    .INTR => continue,
                    else => return false,
                }
            }
        },
    }
}

fn sendTcpIp(ip: net.IpAddress, frame: []const u8) bool {
    switch (ip) {
        .ip4 => |ip4| {
            const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
            if (linux.errno(s_rc) != .SUCCESS) return false;
            const fd: linux.fd_t = @intCast(s_rc);
            defer sys.close(fd);
            setSockTimeout(fd);
            var sa: linux.sockaddr.in = .{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            while (true) {
                const rc = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
                switch (linux.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => return false,
                }
            }
            return sendAllFd(fd, frame);
        },
        .ip6 => |ip6| {
            const s_rc = linux.socket(linux.AF.INET6, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
            if (linux.errno(s_rc) != .SUCCESS) return false;
            const fd: linux.fd_t = @intCast(s_rc);
            defer sys.close(fd);
            setSockTimeout(fd);
            var sa: linux.sockaddr.in6 = .{
                .family = linux.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = 0,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            while (true) {
                const rc = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6));
                switch (linux.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => return false,
                }
            }
            return sendAllFd(fd, frame);
        },
    }
}

fn sendInet(arena: Allocator, host: []const u8, port: u16, tcp: bool, payload: []const u8) bool {
    const data = if (tcp) (arena.print("{d} {s}", .{ payload.len, payload }) catch return false) else payload;
    if (net.IpAddress.parse(host, port)) |ip| {
        return if (tcp) sendTcpIp(ip, data) else sendUdpIp(ip, data);
    } else |_| {}
    const io = Io.Threaded.global_single_threaded.io();
    net.HostName.validate(host) catch return false;
    const hn: net.HostName = .{ .bytes = host };
    var canonical: [net.HostName.max_len]u8 = undefined;
    var buf: [16]net.HostName.LookupResult = undefined;
    var q: Io.Queue(net.HostName.LookupResult) = .init(&buf);
    var fut = io.async(net.HostName.lookup, .{ hn, io, &q, .{
        .port = port,
        .canonical_name_buffer = &canonical,
    } });
    defer fut.cancel(io) catch {};
    while (q.getOne(io)) |item| {
        switch (item) {
            .address => |ip| {
                if (if (tcp) sendTcpIp(ip, data) else sendUdpIp(ip, data)) return true;
            },
            .canonical_name => {},
        }
    } else |_| {}
    return false;
}

/// Send one already formatted payload to `target`: a journald datagram to a
/// `journal_unix` target, an RFC 5424 message to the others. A unix syslog
/// socket is tried as a datagram, then as a stream with a newline; TCP uses
/// octet counting. False when nothing was delivered. A caller with its own
/// formatting uses this for the transport alone.
pub fn send(arena: Allocator, target: Target, payload: []const u8) bool {
    return switch (target.scheme) {
        .journal_unix => sendUnix(arena, target.host_or_path, payload, false),
        .rfc5424_unix => sendUnix(arena, target.host_or_path, payload, true),
        .rfc5424_udp => sendInet(arena, target.host_or_path, target.port, false, payload),
        .rfc5424_tcp => sendInet(arena, target.host_or_path, target.port, true, payload),
    };
}

/// Format one event from `id` for `target` and send it. Best effort: false
/// when it could not be formatted or delivered, and never an error.
pub fn emitFor(
    arena: Allocator,
    id: Identity,
    target: Target,
    severity: u8,
    msgid: []const u8,
    params: []const Param,
    jfields: []const JournalField,
    msg: []const u8,
) bool {
    const payload = switch (target.scheme) {
        .journal_unix => formatJournaldFor(arena, id, severity, msgid, jfields, msg),
        else => formatRfc5424For(arena, id, severity, msgid, params, msg, target.pen),
    } catch return false;
    return send(arena, target, payload);
}

test "parseTarget accepts unix, journald, udp and tcp" {
    try std.testing.expectEqual(Scheme.rfc5424_unix, parseTarget("syslog").?.scheme);
    try std.testing.expectEqual(Scheme.journal_unix, parseTarget("journald").?.scheme);
    try std.testing.expectEqual(Scheme.rfc5424_unix, parseTarget("unix:///tmp/s.sock").?.scheme);
    try std.testing.expectEqual(Scheme.journal_unix, parseTarget("journal+unix:///tmp/j.sock").?.scheme);
    try std.testing.expectEqual(@as(u16, 5140), parseTarget("udp://127.0.0.1:5140").?.port);
    try std.testing.expectEqual(@as(u16, 1514), parseTarget("tcp://[::1]:1514").?.port);
    try std.testing.expect(parseTarget("bogus://x") == null);
    try std.testing.expect(parseTarget("unix://relative") == null);
    try std.testing.expect(parseTarget("tcp://host:0") == null);
}

test "formatRfc5424For escapes structured data values and uses configured PEN" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const id: Identity = .{ .app = "eb-keep-logs", .sd_name = "ebKeepLogs" };
    const msg = try formatRfc5424For(a, id, 4, "EB_KEEP_FAILED", &.{
        .{ .key = "cmd", .value = "failed" },
        .{ .key = "name", .value = "a\"b\\c]d" },
    }, "kept 1", "55555");
    try std.testing.expect(std.mem.startsWith(u8, msg, "<12>1 "));
    try std.testing.expect(std.mem.find(u8, msg, "EB_KEEP_FAILED [ebKeepLogs@55555 cmd=\"failed\" name=\"a\\\"b\\\\c\\]d\"] kept 1") != null);
    try std.testing.expect(parsePen("0") == null);
    try std.testing.expect(parsePen("abc") == null);
    try std.testing.expectEqualStrings("49152", parsePen("049152").?);
}

test "the formatters write the identity they are given" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const id: Identity = .{ .app = "some-tool", .sd_name = "someTool" };
    const line = try formatRfc5424For(a, id, 6, "EVENT", &.{.{ .key = "k", .value = "v" }}, "hello", "32473");
    try std.testing.expect(std.mem.find(u8, line, " some-tool ") != null);
    try std.testing.expect(std.mem.find(u8, line, "[someTool@32473 k=\"v\"] hello") != null);
    try std.testing.expect(std.mem.find(u8, line, "eb-keep-logs") == null);
    const datagram = try formatJournaldFor(a, id, 6, "EVENT", &.{}, "hello");
    try std.testing.expect(std.mem.find(u8, datagram, "SYSLOG_IDENTIFIER=some-tool\n") != null);
}

fn refuseConnect(fd: linux.fd_t, addr: *const anyopaque, len: linux.socklen_t) usize {
    _ = fd;
    _ = addr;
    _ = len;
    return @bitCast(-@as(isize, @backingInt(linux.E.CONNREFUSED)));
}

test "send reports false for a target nobody listens on" {
    test_unix_connect = refuseConnect;
    defer test_unix_connect = null;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(!send(a, .{ .scheme = .rfc5424_unix, .host_or_path = "/nonexistent/zig-common/syslog.sock" }, "x"));
    try std.testing.expect(!send(a, .{ .scheme = .journal_unix, .host_or_path = "/nonexistent/zig-common/journal.sock" }, "x"));
}
