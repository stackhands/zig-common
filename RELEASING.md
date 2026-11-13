# Releasing

A release is an annotated tag `vX.Y.Z` on `main`; there are no binaries.

1. `.version` in `build.zig.zon` names the new version.
2. CI on `main` is green, including the `tools` job that builds every tool
   against this commit.
3. `COMPAT.md` has a row for the version: the Zig version and the tool
   versions built on it.
4. Tag and push: `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.
5. Each tool moves to the tag in a commit of its own:
   `zig fetch --save git+https://github.com/stackhands/zig-common#vX.Y.Z`.
