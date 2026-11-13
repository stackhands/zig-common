# Compatibility

| zig-common | Zig | tools built on it |
|---|---|---|
| 0.4.0 | 0.17.1 | eb-staged-rebuild (Zig port); eb-keep-logs builds against it in CI |
| 0.3.0 | 0.17.1 | eb-staged-rebuild (Zig port; `-Dtest-ops` test artifact); eb-keep-logs builds against it in CI |
| 0.2.0 | 0.17.1 | eb-staged-rebuild (Zig port); eb-keep-logs builds against it in CI |
| 0.1.0 | 0.17.1 | eb-keep-logs 0.2.0 |

A Zig upgrade lands here first, as one commit, after `zig build test` passes
on the new version; each tool then moves to it in a commit of its own. The
scheduled CI job builds every tool against `main`, so a library change that
breaks a tool shows before the tool moves to it.
