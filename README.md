# zig-common

The pieces the stackhands Zig tools share: Linux system calls with named
errors, file handling checked on the open descriptor, running a child
program, gzip in place and the `.licensed-logs` list, and command-line
plumbing.

It holds only what at least two tools need, or what one tool needs in a form
the next port will reuse. It is Linux only and needs Zig 0.17.1.

## Use it from a tool

```zig
// build.zig.zon
.dependencies = .{
    .zig_common = .{
        .url = "git+https://github.com/stackhands/zig-common#<commit>",
        .hash = "<hash zig fetch prints>",
    },
},
```

```zig
// build.zig
const common = b.dependency("zig_common", .{ .target = target, .optimize = optimize });
mod.addImport("zig_common", common.module("zig_common"));
```

`zig fetch --save git+https://github.com/stackhands/zig-common#<commit>` writes
the entry and its hash.

## Modules

| module | what it does |
|---|---|
| `sys` | `std.os.linux` calls with EINTR retried and errno mapped to a Zig error set |
| `fsx` | open without following a final symbolic link, checks on the descriptor (`fstat`), cp-style copy, line append, atomic replace keeping owner, mode and access ACLs, directory iteration, `rm -rf` that never follows links, `realpath` through `/proc/self/fd` |
| `proc` | run a program by absolute path in its own session with an empty signal mask, default handlers and no descriptors above 2; stdout captured with a cap; a deadline, SIGTERM, a grace period, SIGKILL to the process group; group members left after the child exits are killed before it is reaped |
| `logs` | `gzip -9` in place with gzip's header (name, mtime, OS byte), owner, mode and times kept; rewrite of `.licensed-logs` entries |
| `env` | the environment as raw bytes with getenv's first-entry rule, duplicate names found, a child environment built with each name once, shell name check |
| `state` | private files in a shared directory: trusted only when the open file is a regular file of this user with one link and no group or other bits, a lock trusted the same way, atomic 0600 writes |
| `cli` | messages to stdout and stderr that ignore a closed stream, exit code 2 for a refused invocation, the version line |

## Test

```bash
zig build test --summary all
```

## Compatibility

[COMPAT.md](COMPAT.md) lists the library version, the Zig version, and the tool
versions built on each.

## License

MIT, see [LICENSE](LICENSE).
