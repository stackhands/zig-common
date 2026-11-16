# Compatibility

| zig-common | Zig | tools built on it |
|---|---|---|
| 0.9.0 | 0.17.1 | eessi-arch-guard on its next release (proc.killGroup); eb-keep-logs builds against it in CI |
| 0.8.1 | 0.17.1 | eb-local 2.0.0 (its first Zig release) to 2.4.0; eb-staged-rebuild, eb-keep-logs and eessi-arch-guard on their next releases (umask read without changing it, std names without deprecated aliases) |
| 0.8.0 | 0.17.1 | eb-staged-rebuild 1.0.0 (errno text as Python prints it, from the errno the kernel gave); eb-keep-logs builds against it in CI |
| 0.7.0 | 0.17.1 | eb-staged-rebuild (Zig port; exec errors and the ledger group stop of its build-events path); eb-keep-logs builds against it in CI |
| 0.6.0 | 0.17.1 | eb-staged-rebuild (Zig port; failing fault points in its -Dtest-ops artifact); eb-keep-logs builds against it in CI |
| 0.5.0 | 0.17.1 | eb-staged-rebuild (Zig port; bounded ledger call); eb-keep-logs builds against it in CI |
| 0.4.0 | 0.17.1 | eb-staged-rebuild (Zig port); eb-keep-logs builds against it in CI |
| 0.3.0 | 0.17.1 | eb-staged-rebuild (Zig port; `-Dtest-ops` test artifact); eb-keep-logs builds against it in CI |
| 0.2.0 | 0.17.1 | eb-staged-rebuild (Zig port); eb-keep-logs builds against it in CI |
| 0.1.0 | 0.17.1 | eb-keep-logs 0.2.0 |

A Zig upgrade lands here first, as one commit, after `zig build test` passes
on the new version; each tool then moves to it in a commit of its own. The
scheduled CI job builds every tool against `main`, so a library change that
breaks a tool shows before the tool moves to it.

## Where errno text differs from Python

`sys.describe` prints glibc's `strerror` text, as Python's `os.strerror` does,
for every errno the Zig standard library's `linux.E` names. An errno it does
not name prints `[Errno N] Unknown error N`. On x86_64, errno 133 is
`HWPOISON`, `[Errno 133] Memory page has hardware error`, and errno 134 is
not a named errno: both glibc and this library print `[Errno 134] Unknown
error 134`.

