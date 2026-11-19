//! Linux system calls with errno mapped to a Zig error set. The standard
//! library's `std.os.linux` returns raw `usize` results; every call here
//! retries on EINTR and returns a named error otherwise.
const std = @import("std");
const linux = std.os.linux;

/// A file descriptor, as `std.os.linux.fd_t`.
pub const fd_t = linux.fd_t;
/// The open(2) flags, as `std.os.linux.O`. `openat` adds `CLOEXEC` to
/// every set it is given.
pub const O = linux.O;
/// The constants of the `*at` calls, as `std.os.linux.AT`: `AT.FDCWD`,
/// `AT.REMOVEDIR`, `AT.SYMLINK_NOFOLLOW` and the rest.
pub const AT = linux.AT;
/// The size of a path buffer, NUL included: Linux's `PATH_MAX`. `z` refuses
/// a path of this many bytes or more with `error.NameTooLong`.
pub const path_max = 4096;

/// The error a failed call returns, named for its errno. Several errnos
/// share one error, and `last_errno` keeps the errno itself:
///
/// - `AccessDenied`: EACCES and EPERM
/// - `NoSpace`: ENOSPC and EDQUOT
/// - `Busy`: EBUSY and ETXTBSY
/// - `InvalidArgument`: EINVAL and EBADF
/// - `Unsupported`: EOPNOTSUPP and ENOSYS
/// - `NotRegularFile`: no one errno; returned by higher-level checks
/// - `Unexpected`: any errno not named here
///
/// Each other error has one errno: `NotFound` ENOENT, `Exists` EEXIST,
/// `SymLink` ELOOP, `NotDir` ENOTDIR, `IsDir` EISDIR, `NotEmpty` ENOTEMPTY,
/// `CrossDevice` EXDEV, `NameTooLong` ENAMETOOLONG, `TooManyLinks` EMLINK,
/// `ReadOnly` EROFS, `NoData` ENODATA, `Range` ERANGE, `NoChild` ECHILD and
/// `NoProcess` ESRCH. EINTR is not an error: `call` retries it, and
/// `result` returns null for it.
pub const Error = error{
    NotFound,
    Exists,
    AccessDenied,
    SymLink,
    NotDir,
    IsDir,
    NotEmpty,
    NoSpace,
    Busy,
    CrossDevice,
    InvalidArgument,
    NameTooLong,
    TooManyLinks,
    ReadOnly,
    Unsupported,
    NotRegularFile,
    NoData,
    Range,
    NoChild,
    NoProcess,
    Unexpected,
};

/// The errno of the last call that failed through this module, on this
/// thread. Several errnos share one error (EPERM and EACCES are
/// AccessDenied, as both are Python's PermissionError; EDQUOT is NoSpace;
/// anything unlisted is Unexpected), and `describe` reads this to print the
/// errno the kernel gave. Read it before making another call.
pub threadlocal var last_errno: linux.E = .SUCCESS;

/// The text glibc's strerror, and so Python's os.strerror, gives for `e`;
/// null for an errno it does not name.
pub fn errnoText(e: linux.E) ?[]const u8 {
    return switch (e) {
        .PERM => "Operation not permitted",
        .NOENT => "No such file or directory",
        .SRCH => "No such process",
        .INTR => "Interrupted system call",
        .IO => "Input/output error",
        .NXIO => "No such device or address",
        .@"2BIG" => "Argument list too long",
        .NOEXEC => "Exec format error",
        .BADF => "Bad file descriptor",
        .CHILD => "No child processes",
        .AGAIN => "Resource temporarily unavailable",
        .NOMEM => "Cannot allocate memory",
        .ACCES => "Permission denied",
        .FAULT => "Bad address",
        .NOTBLK => "Block device required",
        .BUSY => "Device or resource busy",
        .EXIST => "File exists",
        .XDEV => "Invalid cross-device link",
        .NODEV => "No such device",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .INVAL => "Invalid argument",
        .NFILE => "Too many open files in system",
        .MFILE => "Too many open files",
        .NOTTY => "Inappropriate ioctl for device",
        .TXTBSY => "Text file busy",
        .FBIG => "File too large",
        .NOSPC => "No space left on device",
        .SPIPE => "Illegal seek",
        .ROFS => "Read-only file system",
        .MLINK => "Too many links",
        .PIPE => "Broken pipe",
        .DOM => "Numerical argument out of domain",
        .RANGE => "Numerical result out of range",
        .DEADLK => "Resource deadlock avoided",
        .NAMETOOLONG => "File name too long",
        .NOLCK => "No locks available",
        .NOSYS => "Function not implemented",
        .NOTEMPTY => "Directory not empty",
        .LOOP => "Too many levels of symbolic links",
        .NOMSG => "No message of desired type",
        .IDRM => "Identifier removed",
        .CHRNG => "Channel number out of range",
        .L2NSYNC => "Level 2 not synchronized",
        .L3HLT => "Level 3 halted",
        .L3RST => "Level 3 reset",
        .LNRNG => "Link number out of range",
        .UNATCH => "Protocol driver not attached",
        .NOCSI => "No CSI structure available",
        .L2HLT => "Level 2 halted",
        .BADE => "Invalid exchange",
        .BADR => "Invalid request descriptor",
        .XFULL => "Exchange full",
        .NOANO => "No anode",
        .BADRQC => "Invalid request code",
        .BADSLT => "Invalid slot",
        .BFONT => "Bad font file format",
        .NOSTR => "Device not a stream",
        .NODATA => "No data available",
        .TIME => "Timer expired",
        .NOSR => "Out of streams resources",
        .NONET => "Machine is not on the network",
        .NOPKG => "Package not installed",
        .REMOTE => "Object is remote",
        .NOLINK => "Link has been severed",
        .ADV => "Advertise error",
        .SRMNT => "Srmount error",
        .COMM => "Communication error on send",
        .PROTO => "Protocol error",
        .MULTIHOP => "Multihop attempted",
        .DOTDOT => "RFS specific error",
        .BADMSG => "Bad message",
        .OVERFLOW => "Value too large for defined data type",
        .NOTUNIQ => "Name not unique on network",
        .BADFD => "File descriptor in bad state",
        .REMCHG => "Remote address changed",
        .LIBACC => "Can not access a needed shared library",
        .LIBBAD => "Accessing a corrupted shared library",
        .LIBSCN => ".lib section in a.out corrupted",
        .LIBMAX => "Attempting to link in too many shared libraries",
        .LIBEXEC => "Cannot exec a shared library directly",
        .ILSEQ => "Invalid or incomplete multibyte or wide character",
        .RESTART => "Interrupted system call should be restarted",
        .STRPIPE => "Streams pipe error",
        .USERS => "Too many users",
        .NOTSOCK => "Socket operation on non-socket",
        .DESTADDRREQ => "Destination address required",
        .MSGSIZE => "Message too long",
        .PROTOTYPE => "Protocol wrong type for socket",
        .NOPROTOOPT => "Protocol not available",
        .PROTONOSUPPORT => "Protocol not supported",
        .SOCKTNOSUPPORT => "Socket type not supported",
        .OPNOTSUPP => "Operation not supported",
        .PFNOSUPPORT => "Protocol family not supported",
        .AFNOSUPPORT => "Address family not supported by protocol",
        .ADDRINUSE => "Address already in use",
        .ADDRNOTAVAIL => "Cannot assign requested address",
        .NETDOWN => "Network is down",
        .NETUNREACH => "Network is unreachable",
        .NETRESET => "Network dropped connection on reset",
        .CONNABORTED => "Software caused connection abort",
        .CONNRESET => "Connection reset by peer",
        .NOBUFS => "No buffer space available",
        .ISCONN => "Transport endpoint is already connected",
        .NOTCONN => "Transport endpoint is not connected",
        .SHUTDOWN => "Cannot send after transport endpoint shutdown",
        .TOOMANYREFS => "Too many references: cannot splice",
        .TIMEDOUT => "Connection timed out",
        .CONNREFUSED => "Connection refused",
        .HOSTDOWN => "Host is down",
        .HOSTUNREACH => "No route to host",
        .ALREADY => "Operation already in progress",
        .INPROGRESS => "Operation now in progress",
        .STALE => "Stale file handle",
        .UCLEAN => "Structure needs cleaning",
        .NOTNAM => "Not a XENIX named type file",
        .NAVAIL => "No XENIX semaphores available",
        .ISNAM => "Is a named type file",
        .REMOTEIO => "Remote I/O error",
        .DQUOT => "Disk quota exceeded",
        .NOMEDIUM => "No medium found",
        .MEDIUMTYPE => "Wrong medium type",
        .CANCELED => "Operation canceled",
        .NOKEY => "Required key not available",
        .KEYEXPIRED => "Key has expired",
        .KEYREVOKED => "Key has been revoked",
        .KEYREJECTED => "Key was rejected by service",
        .OWNERDEAD => "Owner died",
        .NOTRECOVERABLE => "State not recoverable",
        .RFKILL => "Operation not possible due to RF-kill",
        .HWPOISON => "Memory page has hardware error",
        else => null,
    };
}

/// Python's str() of the OSError for `err`, "[Errno N] text", from the
/// errno of the last failed call when that errno maps to `err`; otherwise
/// the usual errno for `err`.
pub fn describe(err: Error) []const u8 {
    const recorded = last_errno != .SUCCESS and last_errno != .INTR and errorFor(last_errno) == err;
    if (err == error.NotRegularFile) return "not a regular file";
    const e: linux.E = if (recorded) last_errno else switch (err) {
        error.NotFound => .NOENT,
        error.Exists => .EXIST,
        error.AccessDenied => .ACCES,
        error.SymLink => .LOOP,
        error.NotDir => .NOTDIR,
        error.IsDir => .ISDIR,
        error.NotEmpty => .NOTEMPTY,
        error.NoSpace => .NOSPC,
        error.Busy => .BUSY,
        error.CrossDevice => .XDEV,
        error.InvalidArgument => .INVAL,
        error.NameTooLong => .NAMETOOLONG,
        error.TooManyLinks => .MLINK,
        error.ReadOnly => .ROFS,
        error.Unsupported => .OPNOTSUPP,
        error.NotRegularFile => unreachable,
        error.NoData => .NODATA,
        error.Range => .RANGE,
        error.NoChild => .CHILD,
        error.NoProcess => .SRCH,
        error.Unexpected => .IO,
    };
    return describeErrno(e);
}

/// `err` as a `sys.Error` when it is one; null for any other error.
pub fn asError(err: anyerror) ?Error {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        if (std.mem.eql(u8, @errorName(err), name)) return @errorCast(err);
    }
    return null;
}

/// "[Errno N] text" for one errno, as Python prints an OSError: a static
/// string for every errno Linux names, so it stays valid however many are
/// taken. Only an errno Linux does not name is formatted into a
/// thread-local buffer.
pub fn describeErrno(e: linux.E) []const u8 {
    const info = @typeInfo(linux.E).@"enum";
    @setEvalBranchQuota(info.field_names.len * 1000);
    inline for (info.field_values) |value| {
        if (@backingInt(e) == value) return comptime describeNamed(@fromBackingInt(value));
    }
    const S = struct {
        threadlocal var buf: [48]u8 = undefined;
    };
    return std.mem.print(&S.buf, "[Errno {d}] Unknown error {d}", .{ @backingInt(e), @backingInt(e) }) catch "[Errno ?] Unknown error";
}

fn describeNamed(comptime e: linux.E) []const u8 {
    return if (errnoText(e)) |text|
        std.fmt.comptimePrint("[Errno {d}] {s}", .{ @backingInt(e), text })
    else
        std.fmt.comptimePrint("[Errno {d}] Unknown error {d}", .{ @backingInt(e), @backingInt(e) });
}

/// The strerror text for `e`, the Zig enum tag name when `errnoText` does not
/// name a known tag, or `"Unknown error N"` for an unnamed errno value.
pub fn strerror(e: linux.E) []const u8 {
    if (errnoText(e)) |text| return text;
    if (std.enums.tagName(linux.E, e)) |name| return name;
    const S = struct {
        threadlocal var buf: [32]u8 = undefined;
    };
    return std.mem.print(&S.buf, "Unknown error {d}", .{@backingInt(e)}) catch "Unknown error";
}

/// Map a raw result. EINTR is returned as `null` so callers can retry.
fn map(rc: usize) Error!?usize {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return rc;
    if (e == .INTR) return null;
    last_errno = e;
    return errorFor(e);
}

/// The error a failure errno maps to.
fn errorFor(e: linux.E) Error {
    return switch (e) {
        .NOENT => error.NotFound,
        .EXIST => error.Exists,
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.SymLink,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NOTEMPTY => error.NotEmpty,
        .NOSPC, .DQUOT => error.NoSpace,
        .BUSY, .TXTBSY => error.Busy,
        .XDEV => error.CrossDevice,
        .INVAL, .BADF => error.InvalidArgument,
        .NAMETOOLONG => error.NameTooLong,
        .MLINK => error.TooManyLinks,
        .ROFS => error.ReadOnly,
        .OPNOTSUPP, .NOSYS => error.Unsupported,
        .NODATA => error.NoData,
        .RANGE => error.Range,
        .CHILD => error.NoChild,
        .SRCH => error.NoProcess,
        else => error.Unexpected,
    };
}

/// The result of a raw system call: its value, `null` for EINTR (retry), or
/// the error.
pub fn result(rc: usize) Error!?usize {
    return map(rc);
}

/// Run `f` until it does not fail with EINTR.
pub inline fn call(comptime f: anytype, args: anytype) Error!usize {
    while (true) {
        if (try map(@call(.auto, f, args))) |rc| return rc;
    }
}

/// A NUL-terminated copy of `s` in `buf`. Paths with a NUL byte are refused.
pub fn z(buf: *[path_max:0]u8, s: []const u8) Error![:0]const u8 {
    if (s.len >= path_max) return error.NameTooLong;
    if (std.mem.findScalar(u8, s, 0) != null) return error.InvalidArgument;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// openat(2) of `path` relative to `dir`, with `CLOEXEC` added to `flags`;
/// `mode` applies when `flags` creates the file. Returns the new
/// descriptor, which the caller closes. A path with a NUL byte is
/// `error.InvalidArgument`, one of `path_max` bytes or more
/// `error.NameTooLong`.
pub fn openat(dir: fd_t, path: []const u8, flags: O, mode: linux.mode_t) Error!fd_t {
    var buf: [path_max:0]u8 = undefined;
    var f = flags;
    f.CLOEXEC = true;
    const rc = try call(linux.openat, .{ dir, (try z(&buf, path)).ptr, f, mode });
    return @intCast(rc);
}

/// close(2). The result is ignored: Linux frees the descriptor even when
/// close fails, so there is nothing to retry.
pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// read(2) into `buf`: the number of bytes read, 0 at the end of the file.
pub fn read(fd: fd_t, buf: []u8) Error!usize {
    return call(linux.read, .{ fd, buf.ptr, buf.len });
}

/// write(2) until all of `bytes` is written, going on after a short write.
/// A write that returns 0 is `error.NoSpace`.
pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try call(linux.write, .{ fd, bytes[off..].ptr, bytes.len - off });
        if (n == 0) return error.NoSpace;
        off += n;
    }
}

/// fchmod(2): set the permission bits of an open file to `mode`.
pub fn fchmod(fd: fd_t, mode: linux.mode_t) Error!void {
    _ = try call(linux.fchmod, .{ fd, mode });
}

/// fchown(2): set the owner and group of an open file. Changing the owner
/// needs privilege, and is `error.AccessDenied` without it.
pub fn fchown(fd: fd_t, uid: linux.uid_t, gid: linux.gid_t) Error!void {
    _ = try call(linux.fchown, .{ fd, uid, gid });
}

/// fsync(2): return once the file's data and metadata are on stable
/// storage. For a directory, that includes the names in it.
pub fn fsync(fd: fd_t) Error!void {
    _ = try call(linux.fsync, .{fd});
}

/// unlinkat(2) of `path` relative to `dir`. `flags` is 0 for a file and
/// `AT.REMOVEDIR` for an empty directory.
pub fn unlinkat(dir: fd_t, path: []const u8, flags: u32) Error!void {
    var buf: [path_max:0]u8 = undefined;
    _ = try call(linux.unlinkat, .{ dir, (try z(&buf, path)).ptr, flags });
}

/// renameat(2): rename `old_dir/old` to `new_dir/new`, replacing `new` in
/// one step when it exists. Both must be on one file system, or it is
/// `error.CrossDevice`.
pub fn renameat(old_dir: fd_t, old: []const u8, new_dir: fd_t, new: []const u8) Error!void {
    var a: [path_max:0]u8 = undefined;
    var b: [path_max:0]u8 = undefined;
    _ = try call(linux.renameat, .{ old_dir, (try z(&a, old)).ptr, new_dir, (try z(&b, new)).ptr });
}

/// The real user id of this process, getuid(2).
pub fn getuid() linux.uid_t {
    return linux.getuid();
}

test "describe prints the errno the kernel gave, as Python's OSError does" {
    _ = map(@bitCast(@as(isize, -@as(isize, @backingInt(linux.E.DQUOT))))) catch |err| {
        try std.testing.expectEqual(error.NoSpace, err);
        try std.testing.expectEqualStrings("[Errno 122] Disk quota exceeded", describe(err));
    };
    _ = map(@bitCast(@as(isize, -@as(isize, @backingInt(linux.E.PERM))))) catch |err| {
        try std.testing.expectEqualStrings("[Errno 1] Operation not permitted", describe(err));
    };
    _ = map(@bitCast(@as(isize, -@as(isize, @backingInt(linux.E.MFILE))))) catch |err| {
        try std.testing.expectEqual(error.Unexpected, err);
        try std.testing.expectEqualStrings("[Errno 24] Too many open files", describe(err));
    };
    // An error that the last errno does not map to gets its usual errno.
    try std.testing.expectEqualStrings("[Errno 2] No such file or directory", describe(error.NotFound));
    try std.testing.expectEqual(@as(?Error, null), asError(error.OutOfMemory));
    try std.testing.expectEqualStrings("[Errno 133] Memory page has hardware error", describeErrno(.HWPOISON));
    try std.testing.expectEqualStrings("[Errno 134] Unknown error 134", describeErrno(@fromBackingInt(@intCast(134))));
    try std.testing.expectEqualStrings("No such file or directory", strerror(.NOENT));
    try std.testing.expectEqualStrings("File name too long", strerror(.NAMETOOLONG));
    const compat_fd = try openat(linux.AT.FDCWD, "COMPAT.md", .{}, 0);
    defer close(compat_fd);
    var compat: std.ArrayList(u8) = .empty;
    defer compat.deinit(std.testing.allocator);
    var chunk: [512]u8 = undefined;
    while (true) {
        const n = try read(compat_fd, &chunk);
        if (n == 0) break;
        try compat.appendSlice(std.testing.allocator, chunk[0..n]);
    }
    try std.testing.expect(std.mem.indexOf(u8, compat.items, "errno 133") != null);
    try std.testing.expect(std.mem.indexOf(u8, compat.items, "errno 134,") == null);
}

test "strerror formats unnamed errno values instead of panicking" {
    var raw: u16 = 134;
    const unknown_134: linux.E = @fromBackingInt(raw);
    try std.testing.expectEqualStrings("Unknown error 134", strerror(unknown_134));
    raw = 999;
    const unknown_999: linux.E = @fromBackingInt(raw);
    try std.testing.expectEqualStrings("Unknown error 999", strerror(unknown_999));
}

test "errnoText returns null for unknown errnos and sys wrappers surface expected errors" {
    try std.testing.expectEqual(@as(?[]const u8, null), errnoText(.SUCCESS));
    var raw: u16 = 134;
    try std.testing.expectEqual(@as(?[]const u8, null), errnoText(@fromBackingInt(raw)));
    raw = 999;
    try std.testing.expectEqual(@as(?[]const u8, null), errnoText(@fromBackingInt(raw)));
    try std.testing.expectEqualStrings("Operation not supported", errnoText(.OPNOTSUPP).?);

    var zb: [path_max:0]u8 = undefined;
    var too_long: [path_max]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(error.NameTooLong, z(&zb, &too_long));
    try std.testing.expectError(error.InvalidArgument, z(&zb, "bad\x00path"));

    try std.testing.expectError(error.NotFound, openat(linux.AT.FDCWD, "/no/such/zig-common-path", .{}, 0));
    try std.testing.expectError(error.InvalidArgument, openat(linux.AT.FDCWD, "bad\x00path", .{}, 0));

    var rbuf: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, read(-1, &rbuf));
    try std.testing.expectError(error.InvalidArgument, writeAll(-1, "x"));
    try std.testing.expectError(error.InvalidArgument, fchmod(-1, 0o600));
    try std.testing.expectError(error.InvalidArgument, fchown(-1, 0, 0));
    try std.testing.expectError(error.InvalidArgument, fsync(-1));
    try std.testing.expectError(error.NotFound, unlinkat(linux.AT.FDCWD, "/no/such/zig-common-path", 0));
    try std.testing.expectError(error.NotFound, renameat(linux.AT.FDCWD, "/no/such/zig-common-src", linux.AT.FDCWD, "/no/such/zig-common-dst"));

    if (openat(linux.AT.FDCWD, "/dev/full", .{ .ACCMODE = .WRONLY }, 0)) |full_fd| {
        defer close(full_fd);
        try std.testing.expectError(error.NoSpace, writeAll(full_fd, "x"));
    } else |_| {}
}
