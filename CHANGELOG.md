# Changelog

<!-- towncrier release notes start -->

## 0.9.0 (2026-11-16)

### Features

- `proc.killGroup(pgid, sig)` sends a signal to the process group that `Options.pgid_out` published, or to the child itself while it has not made that group yet, as `proc.run` does. It makes only kill system calls and does not wait, so a signal handler can call it; `proc.stopGroup` also waits for the group to go.

### Fixes

- A refused gate is the new `RootLock.AcquireError.GateNotPrivate` (`NotPrivate` stays the sidecar's), a symbolic link as the state root is `NotDir`, and `LockOps.open_sidecar` takes the state root's descriptor and a name.
- `atomic.atomicWrite` frees everything it allocates from the caller's allocator before it returns (the temporary path, the step names, the ACLs it reads and the refusals it wraps), which only an arena used to hide. A refusal's `why.msg` is the caller's, freed by the new `Why.deinit`; the ACLs `readAcls` and `readMetadata` return are freed by the new `Acls.deinit` and `Metadata.deinit`.
- `atomicWrite` frees the path, the step names and the spare ACL read it allocates.
- `atomic` retries an ACL read interrupted by a signal, instead of refusing the replacement.
- `atomic` words a failed ACL read with `sys.describeErrno`, glibc's text for every errno Linux names (`[Errno 116] Stale file handle`), instead of its own six-entry table that printed the errno's name for the rest.
- `fsx.appendLine` rolls a short write back, so a full disk does not leave a partial line.
- `fsx.copyTo` copies the whole source, whatever the descriptor's offset, and leaves the offset where it was, as its doc says; it copied from the offset to the end and left the offset there.
- `fsx.copyTo` renames the new bytes into place, so a short write leaves the existing file unchanged.
- `fsx.replaceContents` copies a GPFS native NFSv4 ACL (`system.gpfs_nfs4_acl`), which it dropped, and, as `atomic` does, copies only the most native ACL form the old file has. GPFS's EINVAL for an NFSv4 form of a file with a POSIX ACL no longer fails the replacement. `fsx.acl_attributes` is the one list of forms, and `atomic` uses it.
- `json.decodeCache` and `json.decodeWire` return `error.Encoding` for an escape that is cut off, unknown or a `\u` without four hex digits, where they read past the string or took `\u+123` and `\x0041`; what they allocated before the error is freed. `Value.get` does not read past a key that ends in a backslash.
- `json.parse` refuses arrays and objects nested more than 32 deep, now `json.max_depth`, whether or not the innermost one is empty; 33 nested empty containers used to parse. The limit is documented, and the module summary covers the parser, both codecs, `toPy` and `dumps`.
- `json.toPy` returns `error.Encoding` for an integer that does not fit an `i64`, which `json.loads` keeps exact, instead of a rounded float; a number with a fraction or an exponent is still a float.
- `json` returns an encoding error for a truncated or unknown escape, instead of reading past the string.
- `logs.gzipInPlace` writes the archive under a temporary name and renames it into place, so a crash does not leave a partial `.gz` at the final name.
- `proc.groupAlive` retries a `/proc` read interrupted by a signal, instead of reporting that the process group is gone.
- `proc.run` gives the child /dev/null or its pipes on fds 0 to 2 when the caller started with one of them closed: the child's stderr no longer lands in the captured stdout, and its stdin or stderr is no longer closed at exec.
- `proc.run` kills a child that is canceled or times out before it has made its process group, instead of signalling a group that does not exist yet, which let the child run to the end and what it started outlive the call. `proc.stopGroup` likewise kills a child whose pgid `Options.pgid_out` has only just published.
- `proc.run` returns `error.NoChild` when the child's status is lost because the caller ignores SIGCHLD, instead of reporting a kill by signal 9.
- `pytext.pySplit` frees its list when an allocation fails, and the slice it returns is the whole allocation.
- `state.RootLock.acquire` no longer truncates the file behind a hard link planted at `.lock`. It opens the state root `O_DIRECTORY|O_NOFOLLOW` and both lock files relative to it with `O_NOFOLLOW`, creating them mode 0600; a lock file name that is not a regular file with one link is refused before it is opened, so a FIFO or symbolic link there is never followed; and once both locks are held, the gate must still be a regular file whose one link is `.lock` before it is truncated.
- `state.RootLock` also refuses a gate or sidecar that another user owns, as `GateNotPrivate` and `NotPrivate`: each must be a regular file of this user with one link.
- `state.lockExclusive` measures its deadline on the monotonic clock, so a signal that cuts a sleep short does not expire the wait.
- `state.lockExclusive` with a timeout returns a failing flock's own error, with its errno in `sys.last_errno`, as it does without one, instead of `error.Unexpected`.

### Documentation

- The `atomic.Ops` doc says the calls can be replaced in a tool's `-Dtest-ops` artifact too, as `atomic.replaceable` allows, not only under `builtin.is_test`.
- `COMPAT.md` names errno 133 as the hardware-error text. Errno 134 is unnamed, which is what glibc prints too.

### Miscellaneous

- The test that `proc.groupAlive` stays true while signals arrive sends one signal a millisecond, as the `state.lockExclusive` one does, instead of back to back, which made it take a minute or more on several CPUs and minutes under QEMU. It runs until ten of its checks have caught a signal, so it fails rather than passes when none lands.
- The test that `proc.stopGroup` kills a child whose pgid was only just published runs 50 times instead of 100: without the kill fix it fails within its first three runs either way, and it takes half as long.


## 0.8.1

* `atomic` reads the umask from `/proc/self/status` instead of setting it to
  0 and back, which another thread creating a file could see.
* `atomic.atomicWrite` removes its temporary file when the `fstat` after
  creating it fails.
* `env.Builder.envp` refuses an empty name or one holding `=`, which an
  `execve` environment block cannot carry.
* The std names Zig 0.17 keeps, not its deprecated aliases; `state` uses
  std's lock-type constants. Tests use scratch directories under
  `.zig-cache`.

## 0.8.0

* `sys.describe` prints the errno the kernel gave, with glibc's strerror
  text for every errno Linux names (`[Errno 122] Disk quota exceeded` where
  EDQUOT shares `NoSpace`); `sys.last_errno` is thread-local; `sys.asError`.
* `proc.run` ignores SIGPIPE while feeding stdin, so a child that exits
  without reading it is an EPIPE, not the end of the caller; the child's pipe
  ends are closed on every error path.
* CI pins actions to commit SHAs and runs with least-privilege tokens.

## 0.7.0

* `proc.Options.exec_error` returns a failed exec as its errno's error, as
  Python's `Popen` raises `OSError`; `proc.stopGroup` kills and waits for a
  process group from a signal handler; `pgid_out` is cleared before each reap.

Earlier versions are listed in `COMPAT.md`.
