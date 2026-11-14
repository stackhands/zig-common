# Compatibility

| zig-common | Zig | tools built on it |
|---|---|---|
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
not name prints `[Errno N] Unknown error N`; on x86_64 that is errno 134,
which glibc calls "Memory page has hardware error".

