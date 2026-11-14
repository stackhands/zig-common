# Changelog

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
