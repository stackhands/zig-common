# Changelog

<!-- towncrier release notes start -->

## 0.14.0 (2026-11-26)

### Features

- `env_scrub.childClearNames` returns the install-location names in
  `src/env-scrub.json`, in the order `eb-local env` prints them.
- `logs.gzipInPlaceAtStep` compresses a log as `logs.gzipInPlace` does, and on an error sets a `logs.GzipStep` that says whether the error came before the archive was in place (`archive`) or from the sync of its directory afterwards (`directory_sync`). `gzipInPlace` keeps its signature and calls it.

### Fixes

- `atomic.atomicWrite` and `atomic.atomicWriteAt` sync and close the temporary file before renaming it over the destination. A failed close is returned as `sys.Error`, the destination is left as it was, and the temporary file is removed. `atomicWrite` puts that errno in `why` with no path, as it does for a failed write or fsync. Before this change, `atomicWrite` ignored the close, and `atomicWriteAt` closed only after the rename and ignored the result. A write that the Network File System (NFS) reported lost at the close then replaced the destination and was returned as success. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. The call is replaceable through `atomic.ops.close` in the same builds as the other `atomic.ops` calls.
- `fsx.TempDir.get` does not keep a directory whose probe file close fails, so a write that a network file system (NFS) reported lost at the close is not committed as the temporary directory. The probe file is removed. A close that `EINTR` interrupts counts as success and is not retried. The close goes through `fsx.temp_probe_ops`.
- `fsx.absPath` returns `Error` as well as `Allocator.Error` in its error set, which is a source-breaking change for callers that switch exhaustively on its errors. It handles a removed working directory, reporting `error.NotFound`.
- `fsx.appendLine` closes the list after the line is written and returns that close. A failed close is returned as `sys.Error` with `sys.last_errno` set. The line is not removed, because the descriptor is already gone and the file is not shortened back to its old size. Before this change the close result was ignored, so a write that a network file system (NFS) reported lost at the close was returned as success. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. The close is replaceable through `fsx.publish_ops` in the same builds as `atomic.ops`. A cleanup close on an earlier error still ignores its result so the earlier error keeps its errno.
- `fsx.copyTo` closes the temporary file before the rename that publishes it. A failed close is returned with `sys.last_errno` set, the destination keeps its old contents, and the temporary file is removed. A close that `EINTR` interrupts counts as success and is not retried. The caller still gets an open descriptor of the published file.
- `fsx.moveAcross` closes a copied directory after syncing it and before the rename that publishes the copy, including each directory of a copied tree. `fsx.copyTo` and `moveAcross` close the parent directory after the sync that makes the new name durable. `atomic.fsyncDir` and the parent directory sync in `atomic.atomicWrite` check that close as well, as does the directory sync at the end of `logs.gzipInPlace`. A failed close is returned as `sys.Error`. A close on the way out of an earlier error is ignored and that errno is kept. Before this change those closes were ignored, so a directory sync that a network file system (NFS) reported lost only at the close was returned as success. Before the rename, a failure leaves the destination name as it was and removes the temporary path. After the rename, the published name keeps what the rename put there. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. The closes go through `fsx.publish_ops`, `atomic.ops.close` and `logs.gzip_ops` in the same builds as the other replaceable calls.
- `fsx.replaceContents` closes the file before the rename that publishes it. So does the cross-device copy inside `fsx.moveAcross`, for a regular file and for each regular file of a copied tree. A failed close is returned as `sys.Error`, the destination is left as it was, and the temporary path is removed. Before this change, the close of `replaceContents` ran after the rename, and the copy ignored the result of its close. A write that the Network File System (NFS) reported lost at the close was then published and returned as success. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. The close is replaceable through `fsx.publish_ops` in the same builds as `atomic.ops`.
- `logs.gzipInPlace` and `logs.gzipInPlaceAtStep` sync and close the temporary archive before renaming it over `name.gz`. A failed close is returned as `sys.Error`, the temporary file is removed, and the log and any existing archive are left as they were. Before this change the archive was closed after the rename and the close error was dropped, so a write that a network file system (NFS) reported lost at the close published `name.gz`, removed the log, and was returned as success. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. The call is replaceable through `logs.gzip_ops` in the same builds as `atomic.ops`.
- `state.RootLock.release` reports a failed release of the state-root lock. It closes both lock files and returns the first error as `sys.Error`. It used to drop that error, so callers that discarded the result have to handle it.
- `state.createPrivateAt` returns a failed close of the file it creates as `sys.Error`, with that errno in `sys.last_errno`. The created name is left in place, including when the close fails. Before this change the close was ignored, so a write that a network file system (NFS) reported lost at the close was returned as success. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. After an earlier error, the cleanup close ignores its result and keeps that error's errno. The close goes through `state.write_ops.close`, the same replaceable call `state.writePrivate` uses.
- `state.writePrivate` syncs and closes the temporary file before it renames it over the name. A failed fsync or close is returned as `sys.Error`, the name is left as it was, and the temporary file is removed. Before this change the file was closed after the rename and the close error was dropped, so a write that a network file system (NFS) reported lost at the close replaced the name and was returned as success. A close that `EINTR` interrupts is not retried and is not an error, as `sys.result` treats `EINTR`. The calls are replaceable through `state.write_ops` in the same builds as `state.lock_ops`.

### Documentation

- The API reference and the compress-and-mark-logs how-to list `logs.GzipStep` and `logs.gzipInPlaceAtStep`, and the how-to shows how to read the step an error came from.
- The README module table lists `argparse`, and COMPAT.md names eb-local as a consumer of 0.13.0.
- `logs.GzipStep` says that an `archive` error from opening `name` changes nothing, so a `name` that was already absent stays absent and any `name.gz` already there is left alone, that after a later `archive` error the original is still there and `name.gz` is absent unless it existed before or both the removal of the original and the removal of the archive failed, and that `directory_sync` follows one rename and one unlink.

### Miscellaneous

- Add a descriptor count around the `proc` paths that call `sys.keepAboveStdio`, checking `/proc/self/fd` before and after so a leaked descriptor fails the test.
- Add a test that `state.RootLock.release` returns the error when the `fcntl` or `flock` release fails through `state.lock_ops`, returns the record lock error when both fail, and closes both lock descriptors in each case.
- Add a test that `sys.keepAboveStdio` returns `error.Unexpected` and leaves the original descriptor open when duplication fails with `EMFILE`.
- Add tests that `state.writePrivate` returns a failed `fsync` or `close` injected through `state.write_ops`, closes the descriptor once, leaves the name and no temporary file, retries an `fsync` that `EINTR` interrupts, and treats a `close` that `EINTR` interrupts as success without a retry.
- Move the forked-child wait that retries an interrupted `wait4` into the shared test helper.
- Move the open-descriptor count into a shared test helper and return an error when reading `/proc/self/fd` fails.
- Move the scratch directory the `logs` tests and the `fsx` `moveAcross` fixture make into `test_support.ScratchDir`, which removes a directory left by an earlier run of the same pid before it creates its own.
- Prepare `zig-common` `0.14.0` in `COMPAT.md` for callers of `fsx.absPath`, whose error set now includes `Error` as well as `Allocator.Error`.


## 0.13.0 (2026-11-24)

### Features

- Add `Policy.native_exact` with `NegativeNumberMode.any` and `SpecialActionMode.prescan` plus `Policy.fail_fast` and `CommandSpec.mutually_exclusive` alongside `OptionSpec.allow_empty` / `allow_dash_value` in `zig_common.argparse`.
- Add `Policy.prolog_lenient` preset with `optional_value` (`nargs="?"`, `const=""`), deferred help/version recording, silent unknown skipping, and non-exiting Slurm TaskProlog semantics.
- Add `PositionalArity.zero_or_more` and `PositionalArity.one_or_more` alongside `PositionalSpec.ignore_empty` and `UnknownMode.positional` in `zig_common.argparse`.
- Add `argparse.types` eager validators (`pyFloat`, `nonNegativeFiniteFloat`, `nonNegativeU128`, `boundedU64`, `choice`) and eager option/positional choice checking in `src/argparse.zig`.
- Add `cli.Stdout` and `cli.writeOut` for checked standard-output writes that report the first write error on standard error and turn a zero exit status into `1`.
- Add `fsx.TempDir`, a port of `tempfile.gettempdir`. It probes the candidates from the environment first and the system directories after. Each probe is a file write, as in Python. The answer is made absolute and normalized, and it is kept for later calls. A failure gives the text of Python's FileNotFoundError, which lists the candidates. The `TempDir` owns the answer and the message, and `deinit` frees them. `fsx.tempDirCandidates` returns the list alone, and `fsx.freeTempDirCandidates` frees it.
- Add `fsx.mkstemp` to create a private `0600` file with a random suffix under a given directory. The file is open for reading and writing. As in Python, a relative directory is made absolute, so the path is absolute. A refused open reports its path, so the caller can format the error as Python does.
- Add `pytext.decimalDigit` and `pytext.decimalToAscii`. They read the decimal digits of every script as Python's `float()` and `int()` do. A generator script under tools builds the table from `unicodedata`, and the table is pinned to Unicode 16.0.0, the data of Python 3.14.
- Add declarative `argparse` specification, policy, outcome, and `optionLike` types in `src/argparse.zig` and export `zig_common.argparse`.
- Add structured `ErrorKind` classification on `UsageError` in `zig_common.argparse` so callers can render native diagnostics without parsing `UsageError.message`.
- Implement pure `argparse.parse` and `argparse.parseOrExit` with Python 3.14 prefix abbreviations, short-option clustering, `--` termination, subcommand dispatch, `REMAINDER`, and argv-ordered unrecognized argument reporting.
- `Builder.diff`, `Diff.reverse` and `Diff.patch` record an environment
  change and apply it in either direction.
- `atomic.atomicWriteAt` writes through an open directory descriptor with
  the exact mode the caller names, umask aside, for the metrics writers
  that hold their directory pinned.
- `fsx.mkdtempReport` is `mkdtemp` with a `Why`. A failed create reports the OSError text that Python gives, with the whole path it tried, random name included, in one repr.
- `fsx.selfExe` reads this program's own path from /proc/self/exe, answering a
  failed, empty or truncated read with null so each caller can choose what
  that means.
- `json.dumpsCompact` writes the one-line form Python's default json.dumps
  call gives, with the same separators and ensure_ascii, byte for byte.
- `logs.gunzip` reads the members of a gzip stream one after another,
  checking each member's CRC-32 and size, ported from eb-keep-logs.
- `state.createPrivateAt` creates a private file through an open directory
  descriptor at an exact mode without ever replacing an existing name, the
  never-clobber shape the tools' new-file writers need.
- `state.lockExclusive` and `lockExclusiveCancel` take the timeout as u64
  milliseconds, wide enough for the 999_999_999 seconds a flock -w style
  caller passes, where a u32 held only about 49 days.
- `sys.keepAboveStdio` moves an open descriptor in slots 0, 1 or 2 to 3
  or above with `FD_CLOEXEC` set and closes the original slot, returning
  descriptors already at 3 or above unchanged; `proc.run` uses it for its
  child setup and exec-failure pipe.

### Fixes

- A failed lock acquisition records the OSError text and whether Python names .lock, .lock.posix, the state directory, or no file.
- A failed replacement names the temporary file when the open fails, names both files when the rename fails, and names no file when the write or the flush fails.
- An interrupted non-blocking flock is retried instead of reported as a busy lock.
- Classify a space-containing dash token that matches a registered option as an option token, and drop a double-dash separator only when it is adjacent to a consumed positional.
- Keep the original operating-system error when allocation fails while formatting its atomic-write diagnostic.
- Record the state-root path and error text when lock acquisition rejects a non-directory or broken symbolic link.
- Report the ancestor that actually failed when recursive state-root or atomic-write directory creation stops.
- Reset stale lock errno state and preserve the parent-directory errno after an atomic replacement has been renamed.
- `atomic.makedirs` reports EEXIST for a final name that exists as a
  non-directory, and no longer passes silently when that name is a dangling
  link, matching os.makedirs with exist_ok.
- `fsx.copyTo` creates its temporary file in the destination parent directory
  for nested targets, avoiding cross-device rename failures.
- `fsx.moveAcross` syncs the destination parent directory for nested targets.
- `fsx.moveAcross` syncs the parent directory of the source name, also when one descriptor holds both names and the destination is nested.
- `gzipInPlace` refused to compress a log whose name, well within the
  reference compressor's own limit, no longer fit a filesystem's 255-byte
  limit on one path component once its temporary file's pid and random
  suffix were added on. That suffix alone already makes the temporary
  name unique, so the original name is left off a temporary name that
  would otherwise overflow, and a name that reference tool would have
  compressed compresses here too.
- `json.toPy` keeps the last value of a duplicate key without decoding the
  members the document drops, as json.loads does, so an undecodable dropped
  duplicate no longer fails the document.
- `json.toPy` refuses a document whose raw non-UTF-8 byte sits in the
  member a duplicate key drops, as the consumers decode the whole text
  strictly before json.loads.
- `logs.gunzip` treats bytes that are all zero after the last member as
  padding, as gzip -d and Python's gzip do, instead of refusing them as
  another damaged member.
- `logs.gzipInPlace` now handles nested relative paths and writes temporary
  archives beside the destination gzip path.
- `proc.run` rejects an empty argument vector instead of spawning a child with
  no `argv[0]`.
- `state.RootLock.acquire` tightens accepted owner-checked lock descriptors to
  mode 0600, repairing permissive pre-existing lock files.
- `state.writePrivate` accepts names with directory components and creates
  its temporary file in the same subdirectory as the destination.
- `sys.strerror(.SUCCESS)` reports `Success`, matching libc wording for errno
  zero.
- `sys.strerror` returns `Unknown error N` for non-Linux `linux.E` tags such as
  `NSRNODATA` through `NSRCNAMELOOP`, matching glibc and Python's `os.strerror`.

### Removals

- `syslog`: `formatRfc5424`, `formatJournald` and `emit`, the functions without an `Identity`, are removed, with the identity they wrote; call `formatRfc5424For`, `formatJournaldFor` and `emitFor` with the caller's own `Identity`, `.{ .app = "eb-keep-logs", .sd_name = "ebKeepLogs" }` for the events they sent.

### Miscellaneous

- A differential fuzz compares json.parse, toPy and Value.get against
  json.loads on strictly decoded text, the way the consumers read it, with
  the writer's own output read back through the same strict reader.
- A differential fuzz compares logs.gunzip over a run-time corpus with
  Python's gzip module: the header flags, multi-member streams, truncated
  and damaged members, trailing garbage and trailing zero padding.
- A differential parity test compares atomicWrite, replaceContents and
  appendLine with the Python tempfile-plus-replace pattern and the append
  mode of open, covering the umask in the mode bits, symlink targets and
  read-only parent directories.
- A differential parity test compares env parsing and building with what a
  Python child resolves from the same environ block, and the CLI usage exit
  code with argparse's own error exit.
- A differential parity test compares sys.describeErrno and sys.errnoText
  with os.strerror for every errno the kernel names, and the OSError framing
  with quotes, non-UTF-8 and newlines in the path against Python's repr.
- A differential parity test compares the library's JSON and pytext output
  with Python's own json, repr, shlex and text calls, byte for byte, from
  a probe built in the CI test job.
- A differential parity test compares the library's path normalization,
  makedirs errnos, copy and move effects, realpath results and lock
  outcomes with Python's own os.path, os.makedirs, os.replace,
  realpath and fcntl.flock calls, from a probe built in the CI test job.
- A differential parity test compares whichShutil with shutil.which over a
  PATH fixture, reprStr and osErrorErrno with Python's repr and OSError
  text, and gzipInPlace with GNU gzip's mode, mtime, header and content.
- A differential parity test covers copyTo and moveAcross edges against
  shutil and os: cross-device moves and their copy fallback, a read-only
  destination, a symlinked destination, a write stopped by the file-size
  limit and a source removed after its descriptor was opened.
- Add a runtime-seeded differential parity test (`tests/test_argparse_parity.py` and `zig build argparse-parity-probe`) comparing `argparse` against Python 3.14 `argparse` and fixing two subtle edge cases uncovered by fuzzing.
- Add a unit test that pins the `fsx.copyTo` error for a FIFO destination.
- Add differential parity fuzz tests covering variadic intermixed positionals (`parse_intermixed_args`) plus `Policy.native_exact` with `SpecialActionMode.prescan` and `CommandSpec.mutually_exclusive` alongside `PositionalSpec.ignore_empty` and `ErrorKind`.
- Prepare `zig-common` `0.13.0` in `COMPAT.md` for callers of `syslog` that name their own `Identity`.
- The CI runs the argparse parity suite under Python 3.14 next to the JSON, filesystem and `tempfile.gettempdir` suites, guarded by a Python 3.14+ version check.
- The external link check skips `https://www.gnu.org/software/gzip/manual/gzip.html`, which times out from CI.
- `fsx` unit tests trace the renames and directory syncs that `moveAcross` makes.


## 0.12.0 (2026-11-19)

### Features

- `syslog`: `Identity` names the program and the structured-data identifier of an event; `formatRfc5424For`, `formatJournaldFor` and `emitFor` take one, and `send` delivers an already formatted payload, for a tool with formatting of its own. The functions without an identity keep writing `eb-keep-logs`, as 0.11.0 did, until 0.13.0 removes them.

### Miscellaneous

- Prepare `zig-common` `0.12.0` in `COMPAT.md` for callers adopting `syslog.Identity` and `syslog.send`.


## 0.11.0 (2026-11-19)

### Features

- Add `pytext.osError` and `pytext.osErrorErrno` for Python-formatted `OSError` path messages.
- Add `pytext.reprStr` and `pytext.reprStrAlloc` for Python-compatible surrogateescape string quoting.
- Add `state.lockExclusiveCancel` supporting atomic cancellation while polling `flock`.
- Add `sys.strerror` returning `errnoText(e)` or the enum tag name fallback.
- `json.writeCacheStringTo` writes cache-style JSON strings to a writer without allocation.
- `proc.resolveExecutable` resolves executable names to absolute executable regular-file paths from slash paths or PATH lookup with a null-PATH default of `/bin:/usr/bin`.
- `proc.whichShutil` adds an opt-in executable lookup mode that matches POSIX `shutil.which` behavior.
- `syslog`: the RFC 5424 and systemd-journald event emitter that eb-keep-logs and eessi-arch-guard each carried a copy of: `Target`, `parseTarget`, `parsePen`, `formatRfc5424`, `formatJournald` and `emit`.

### Fixes

- Decode UTF-8 keys, UTF-16 surrogate pairs, and surrogateescape cache bytes in `json.Value.get` so escaped non-ASCII keys match like `json.loads`.
- Fix `sys.strerror` to avoid panicking on unnamed `linux.E` values by using `std.enums.tagName` with an `"Unknown error N"` fallback.
- `fsx.appendLine` reports `not a regular file` for an existing non-regular target such as a FIFO.
- `fsx.moveAcross` reports `error.NotRegularFile` when EXDEV fallback copies a tree entry that none of the earlier copy branches handle.
- `fsx.moveAcross` reports `not a regular file` for a FIFO source that takes the EXDEV copy fallback.
- `fsx.openRegular` now reports `error.NotRegularFile` for FIFOs, sockets, and device nodes, and `sys.describe` renders that as `not a regular file` instead of `[Errno 22] Invalid argument`.
- `fsx.openRegular` now returns `error.IsDir` for directory paths, so `sys.describe` reports `[Errno 21] Is a directory` instead of `[Errno 22] Invalid argument` for that case.

### Documentation

- List every public function and error set including PR #24 shared helpers in `docs/orgmode/reference/api.org`.

### Miscellaneous

- Add `atomic.Ops` fault hooks and unit tests covering `atomicWrite` failures on `ENOSPC`, `EROFS`, and `EXDEV`, as well as `makedirs` and `fsyncDir` error paths.
- Add unit tests covering `gzipInPlace` error paths (missing file, directory, symlink, hard link, and existing `.gz` archive) in `src/logs.zig`.
- Add unit tests covering `sys.errnoText` for unknown errno values and error paths for `sys` syscall wrappers.
- Add unit tests covering error and boundary paths for `which`, `groupAlive`, `killGroup`, `stopGroup`, and `run` in `src/proc.zig`.
- Add unit tests covering error paths for public file and directory helpers in `src/fsx.zig`.
- Add unit tests verifying `cli.put` and `cli.print` ignore descriptor write errors and checking `cli.versionLine` formatting.
- Prepare `zig-common` `0.11.0` in `COMPAT.md` for callers adopting `syslog`. A release is now `cog bump` on a release branch: `cog.toml` sets the version in `build.zig.zon` and refuses a version without a `COMPAT.md` row.
- Proc resolver tests share one executable fixture helper for scratch script and plain file setup.
- Route `lockExclusiveCancel` through `state.lock_ops.flock` and add unit tests covering `lockExclusive` with timeout 0, bounded timeout, unsupported `flock`, and private state file error paths.
- The private `proc.isExecutableFile` helper holds the executable regular-file probe that `proc.which` runs for each PATH candidate.
- `json.writeWireString` writes each string through one writer and the shared escape code.
- `proc.resolveExecutable` tests cover relative slash paths for executable and non-executable files.
- `proc.which` tests cover executable resolution and null returns for non-executable candidates.
- `proc.which` uses one internal options-driven search loop for executable path matching.
- `proc` test fixtures clean up scratch directories when setup fails after partial creation.


## 0.10.0 (2026-11-18)

### Features

- Add `fsx.mkdtemp` to create a private `0700` directory with a random suffix under a given parent directory and retry on name collisions.
- Add `fsx.normPath` and `fsx.absPath` to normalize and absolutize POSIX paths without following symbolic links.
- `fsx.moveAcross` adds a durable cross-filesystem move primitive: it tries `rename` first, falls back on EXDEV to a destination-side temporary copy, publishes with an atomic rename, and removes the source only after publish. The new `fsx.MoveAcrossOptions` policy is opt-in, with `strict` for ACL-preserving copies and `portable` for ACL downgrade when destination filesystems do not represent the source ACL form.

### Documentation

- Every `pub` declaration has a doc comment, whose first sentence is the summary the API pages list.
- The documentation site is built from Org pages in `docs/orgmode/` with Sphinx, in four parts: the tutorial "Write a small tool on zig-common", how-to guides, explanation and reference. Each module's API page is generated from its doc comments, and the site publishes an `objects.inv` of every `pub` declaration for the tools' sites to link into. `pixi run -e docs docbld` builds it as CI does and fails on a warning, an unresolved name or a dead internal link; `pixi run -e docs linkcheck` checks the external links. The `docs` workflow publishes the site to GitHub Pages; `docs/requirements.txt` and `pages.yml` are gone.
- The site has how-to guides for replacing a file and keeping its access control lists, keeping private state in `/tmp`, compressing logs that `.licensed-logs` marks, matching a Python tool's output and upgrading zig-common; explanations of process groups and deadlines, system calls without a C library, and Python compatibility; and a reference of the messages, exit statuses and version line that `cli` gives the tools.

### Miscellaneous

- Prepare `zig-common` `0.10.0` in `build.zig.zon` and `COMPAT.md` for callers adopting `fsx.mkdtemp` plus `fsx.normPath` and `fsx.absPath`.


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
