# Releasing

A release is an annotated tag `vX.Y.Z` on `main`; there are no binaries.

1. Branch from `main`: `git switch -c chore/release-X.Y.Z origin/main`.
2. `COMPAT.md` gets a row for the version: the Zig version and the tool
   versions built on it. Commit it with a `changelog.d` fragment.
3. `cog bump --minor` (or `--patch`, `--major`, `--version X.Y.Z`). The hooks
   of `cog.toml` set `.version` in `build.zig.zon` and refuse a version with
   no `COMPAT.md` row; cog commits `chore(version): vX.Y.Z` and creates the
   tag on that commit.
4. Push the branch, open the pull request, and merge it with a merge commit
   once CI is green, including the `tools` job that builds every tool
   against this commit.
5. Sign and push the tag:
   `git tag -s -f vX.Y.Z -m vX.Y.Z 'vX.Y.Z^{}' && git push origin vX.Y.Z`.
6. Each tool moves to the tag in a commit of its own:
   `zig fetch --save git+https://github.com/stackhands/zig-common#vX.Y.Z`.
