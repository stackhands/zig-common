#!/usr/bin/env python3
"""Differential parity test for zig-common's fsx, atomic and state layers.

The probe binary (tests/fs_lock_parity_probe.zig, built by `zig build
fs-lock-parity-probe`) prints one case per line. Path normalization is compared
with os.path.normpath and os.path.abspath byte for byte; filesystem
effects run twice, once through the library on one fixture tree and
once through the Python reference calls on an identical one, and the
two trees plus the surfaced errnos are compared; realpath is compared
with os.path.realpath(strict=True); flock exclusive and try semantics
are exercised in both directions with fcntl.flock. Atomic-write and
state-lock failures are compared with str() of the OSError the same
operation raises.

Run with `python3 tests/test_fs_lock_parity.py` from a checkout that has
the probe built; the test builds it when zig is on PATH and the binary
is missing. ZIG_COMMON_PARITY_PROBE names another binary.
"""
import errno
import fcntl
import gzip
import json
import os
import resource
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROBE = os.path.join(REPO, "zig-out", "bin", "fs_lock_parity_probe")

# zig error names by the errno Python's reference call raises.
BY_ERRNO = {errno.EEXIST: "Exists", errno.ENOTDIR: "NotDir", errno.ENOENT: "NotFound", errno.EACCES: "AccessDenied"}

# The umask the probe child runs under; 0o027 bites the default 0644
# mode, and the reference below computes its modes without relying on
# the runner's own umask, so a writer that ignored the umask cannot
# match.
UMASK = 0o027

FIXTURE = {
    "d": ("dir", None),
    "f": ("file", b"", 0o644, None),
    "dangling": ("symlink", "nowhere"),
    "tolink": ("symlink", "f"),
    "sym": ("symlink", "d"),
    "loop": ("symlink", "loop"),
    "copysrc": ("file", b"copy-me\n", 0o640, (1600000000, 123456789)),
    "mvsrc": ("file", b"move-me\n", 0o650, (1600000001, 987654321)),
    "dst": ("file", b"old\n", 0o644, None),
}

MTIME_CHECK = {"mvdst": (1600000001, 987654321)}


def enc(text):
    """A path name as bytes, a raw byte through surrogateescape."""
    return text.encode("utf-8", "surrogateescape")


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def probe_path():
    path = os.environ.get("ZIG_COMMON_PARITY_PROBE", DEFAULT_PROBE)
    if not os.path.exists(path):
        subprocess.run(["zig", "build", "fs-lock-parity-probe"], cwd=REPO, check=True)
    return path


def run_probe(mode, *args, cwd=None):
    return subprocess.run(
        [probe_path(), mode, *args],
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        preexec_fn=lambda: os.umask(UMASK),
    ).stdout.decode("utf-8", "surrogateescape")


def make_fixture(root):
    for name, spec in FIXTURE.items():
        kind = spec[0]
        path = os.path.join(root, name.encode() if isinstance(name, bytes) else name)
        if kind == "dir":
            os.mkdir(path, 0o755)
        elif kind == "symlink":
            os.symlink(spec[1], path)
        else:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, spec[2])
            try:
                os.write(fd, spec[1])
            finally:
                os.close(fd)
            os.chmod(path, spec[2])
            if spec[3] is not None:
                os.utime(path, ns=(spec[3][0] * 10 ** 9 + spec[3][1],) * 2)
    os.mkdir(os.path.join(root.encode(), b"\xffdir"), 0o755)


def py_makedirs(root, name):
    path = os.path.join(root.encode(), enc(name))
    # the directories this call creates, to chmod like the child's umask
    created = []
    current = path
    while not os.path.lexists(current):
        created.append(current)
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    try:
        os.makedirs(path, exist_ok=True)
        for made in created:
            os.chmod(made, 0o777 & ~UMASK)
        return "OK"
    except OSError as exc:
        return "ERR:" + BY_ERRNO[exc.errno]


def py_copy_to(root, dst):
    """The documented fsx.copyTo behavior, in Python calls."""
    dst_path = os.path.join(root.encode(), dst.encode())
    try:
        src = os.open(os.path.join(root.encode(), b"copysrc"), os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        return "ERR:" + BY_ERRNO[exc.errno]
    try:
        try:
            existing = os.lstat(dst_path)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if os.path.stat.S_ISLNK(existing.st_mode):
                return "ERR:SymLink"
            if os.path.stat.S_ISDIR(existing.st_mode):
                return "ERR:IsDir"
        src_mode = os.fstat(src).st_mode & 0o777
        temp = os.path.join(
            root.encode(), (".%s.%d.tmp" % (dst, os.getpid())).encode()
        )
        out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            data = os.read(src, 1 << 20)
            os.write(out, data)
            os.fsync(out)
            if existing is not None:
                try:
                    os.chown(temp, existing.st_uid, existing.st_gid)
                except PermissionError:
                    pass
                os.chmod(temp, existing.st_mode & 0o777)
            else:
                os.chmod(temp, src_mode & ~UMASK)
        finally:
            os.close(out)
        os.replace(temp, dst_path)
        return "OK"
    finally:
        os.close(src)


def py_move_across(root, src, dst):
    try:
        os.replace(os.path.join(root.encode(), src.encode()), os.path.join(root.encode(), dst.encode()))
        return "OK"
    except OSError as exc:
        return "ERR:" + BY_ERRNO[exc.errno]


def py_realpath(root, name):
    try:
        resolved = os.path.realpath(
            os.path.join(root.encode(), enc(name)), strict=True
        )
        return ("OK", os.path.relpath(resolved, root.encode()))
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return ("ERR", "SymLink")
        return ("ERR", BY_ERRNO[exc.errno])


def make_atomic_fixture(root):
    """The fixture the `atomic` probe mode and its reference both need."""
    root_b = root.encode()
    os.mkdir(os.path.join(root_b, b"ro"), 0o755)
    for name, mode, content in (
        (b"vfile", 0o644, b"victim\n"),
        (b"aw-keep", 0o640, b"existing\n"),
        (b"rc-keep", 0o640, b"rc\n"),
        (b"ap-exist", 0o644, b"ap-existing\n"),
    ):
        fd = os.open(os.path.join(root_b, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        try:
            os.write(fd, content)
        finally:
            os.close(fd)
        os.chmod(os.path.join(root_b, name), mode)
    fd = os.open(os.path.join(root_b, b"ro", b"rc-keep"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, b"rokeep\n")
    finally:
        os.close(fd)
    os.chmod(os.path.join(root_b, b"ro", b"rc-keep"), 0o644)
    for name, target in ((b"aw-link", b"vfile"), (b"rc-link", b"vfile"), (b"ap-link", b"vfile")):
        os.symlink(target, os.path.join(root_b, name))
    os.mkfifo(os.path.join(root_b, b"ap-fifo"), 0o644)
    os.chmod(os.path.join(root_b, b"ro"), 0o555)


def py_atomic_write(root, name, data, mode=None):
    """The documented atomicWrite behavior: a temp file beside the target,
    the existing mode kept, 0644 less the umask for a new one, a symlink
    refused, the temp file closed before os.replace, then a parent fsync.

    A close error other than InterruptedError leaves the destination
    unchanged and removes the temp file. InterruptedError is not an
    error and is not retried: Linux has already closed the descriptor,
    which is how atomicWrite treats EINTR from close (sys.result).
    """
    path = os.path.join(root, name)
    if os.path.islink(path):
        return "ERR:Refused"
    parent = os.path.dirname(path)
    tmp = os.path.join(parent, "." + os.path.basename(name) + ".new")
    try:
        if os.path.lexists(path):
            want = stat.S_IMODE(os.lstat(path).st_mode)
        elif mode is not None:
            want = mode
        else:
            want = 0o644 & ~UMASK
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
            os.fchmod(fd, want)
        finally:
            try:
                os.close(fd)
            except InterruptedError:
                pass
        os.replace(tmp, path)
        fsync_dir(parent)
        return "OK"
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return "ERR:" + BY_ERRNO.get(exc.errno, "Errno%d" % exc.errno)


def py_replace_contents(root, name, data):
    """The documented replaceContents behavior: the target must be an
    existing regular file, never a symlink, and keeps its mode."""
    path = os.path.join(root, name)
    try:
        st = os.lstat(path)
    except OSError as exc:
        return "ERR:" + BY_ERRNO[exc.errno]
    if stat.S_ISLNK(st.st_mode):
        return "ERR:SymLink"
    if not stat.S_ISREG(st.st_mode):
        return "ERR:NotRegularFile"
    tmp = os.path.join(root, "%s.tmp.%d" % (name, os.getpid()))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
            os.fchmod(fd, stat.S_IMODE(st.st_mode))
        finally:
            os.close(fd)
        os.replace(tmp, path)
        return "OK"
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return "ERR:" + BY_ERRNO.get(exc.errno, "Errno%d" % exc.errno)


def zig_temp_for(path):
    """The temporary name atomicWrite uses beside `path`."""
    parent = os.path.dirname(path)
    if parent == "":
        parent = "."
    return parent + "/." + os.path.basename(path) + ".new"


def _in_dir(root, fn):
    old = os.getcwd()
    os.chdir(root)
    try:
        return fn()
    finally:
        os.chdir(old)


def _relax(root):
    """Let a temporary tree be removed after a mode-0555 case."""
    for dirpath, dirnames, _ in os.walk(root):
        for name in dirnames:
            path = os.path.join(dirpath, name)
            try:
                os.chmod(path, 0o755)
            except OSError:
                pass


def track(test, root):
    """Remove `root` after restoring directory modes.

    Cleanup runs last in, first out. rmtree is registered first so the
    mode restore runs before it. The other order deletes a mode-0555
    directory first and leaves the tree behind.
    """
    test.addCleanup(shutil.rmtree, root, ignore_errors=True)
    test.addCleanup(_relax, root)


def fresh_dir():
    root = tempfile.mkdtemp()
    return root


def run_oserror(fn):
    """str() of the OSError `fn` raises, and the exception itself."""
    try:
        fn()
    except OSError as exc:
        return str(exc), exc
    raise AssertionError("the reference operation succeeded")


# zig's sys.Error name for the errno of a real OSError. EFBIG is not one
# of the named errors and surfaces as Unexpected, as the copy tests do.
ZIG_ERR = {
    errno.EACCES: "AccessDenied",
    errno.EPERM: "AccessDenied",
    errno.ENOENT: "NotFound",
    errno.ENOTDIR: "NotDir",
    errno.EISDIR: "IsDir",
    errno.EEXIST: "Exists",
    errno.EFBIG: "Unexpected",
    errno.ENOSPC: "NoSpace",
    errno.EROFS: "ReadOnly",
}


def rendered_oserror(text, path):
    """str(OSError) from the text and path osFailure keeps apart."""
    if path == "":
        return text
    return text + ": " + repr(path)


def py_append_line(root, name, line):
    """The documented appendLine behavior: one appended line, a symlink or
    non-regular target refused, a new file 0666 less the umask."""
    path = os.path.join(root, name)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None:
        if stat.S_ISLNK(st.st_mode):
            return "ERR:SymLink"
        if not stat.S_ISREG(st.st_mode):
            return "ERR:NotRegularFile"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, line.encode() + b"\n")
        finally:
            os.close(fd)
        if st is None:
            os.chmod(path, 0o666 & ~UMASK)
        return "OK"
    except OSError as exc:
        return "ERR:" + BY_ERRNO.get(exc.errno, "Errno%d" % exc.errno)


def make_which_fixture(root):
    """The PATH fixture the `which` probe mode needs, relative names."""
    root_b = root.encode()
    os.mkdir(os.path.join(root_b, b"binA"), 0o755)
    os.mkdir(os.path.join(root_b, b"binB"), 0o755)
    os.mkdir(os.path.join(root_b, b"empty"), 0o755)
    os.mkdir(os.path.join(root_b, b"sub"), 0o755)
    fd = os.open(os.path.join(root_b, b"binA", b"good.sh"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
    os.write(fd, b"#!/bin/sh\n")
    os.close(fd)
    fd = os.open(os.path.join(root_b, b"binA", b"plain.txt"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, b"x")
    os.close(fd)
    os.symlink(b"good.sh", os.path.join(root_b, b"binA", b"sym-good.sh"))
    os.symlink(b"nowhere", os.path.join(root_b, b"binA", b"dangling.sh"))
    os.mkdir(os.path.join(root_b, b"binA", b"dir.sh"))
    os.symlink(b"/bin/true", os.path.join(root_b, b"binA", b"abs.sh"))
    fd = os.open(os.path.join(root_b, b"binB", b"good.sh"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700)
    os.write(fd, b"#!/bin/sh\n")
    os.close(fd)
    fd = os.open(os.path.join(root_b, b"sub", b"rel.sh"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
    os.write(fd, b"#!/bin/sh\n")
    os.close(fd)


def make_gzip_fixture(root):
    root_b = root.encode()
    fd = os.open(os.path.join(root_b, b"run.1234.log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    try:
        os.write(fd, b"log line one\nlog line two\n")
    finally:
        os.close(fd)
    os.chmod(os.path.join(root_b, b"run.1234.log"), 0o640)
    os.utime(
        os.path.join(root_b, b"run.1234.log"),
        ns=(1600000000 * 10 ** 9 + 123456789,) * 2,
    )


class _Literal(Exception):
    pass


def _raise_constant(_name):
    raise _Literal()


def _depth(obj):
    """Container levels of the parsed structure, without recursion: the
    library refuses a document whose nesting passes 32."""
    deepest = 0
    stack = [(obj, 0)]
    while stack:
        node, level = stack.pop()
        if isinstance(node, dict):
            deepest = max(deepest, level + 1)
            stack.extend((v, level + 1) for v in node.values())
        elif isinstance(node, list):
            deepest = max(deepest, level + 1)
            stack.extend((v, level + 1) for v in node)
    return deepest


def _bad_lone(text):
    """A lone surrogate outside the surrogateescape range, which the
    library cannot put in the environment."""
    return any(
        0xD800 <= ord(c) <= 0xDFFF and not (0xDC80 <= ord(c) <= 0xDCFF)
        for c in text
    )


def _bad_doc(obj):
    """A document toPy refuses: an integer past i64, which json.loads
    keeps exact, or a string the environment cannot carry."""
    if isinstance(obj, bool) or obj is None:
        return False
    if isinstance(obj, int):
        return not (-(2 ** 63) <= obj < 2 ** 63)
    if isinstance(obj, str):
        return _bad_lone(obj)
    if isinstance(obj, dict):
        return any(_bad_lone(k) or _bad_doc(v) for k, v in obj.items())
    if isinstance(obj, list):
        return any(_bad_doc(v) for v in obj)
    return False


def _has_inf(obj):
    """A float out of range, which the writer emits as Infinity, the
    one literal the strict reader refuses by contract."""
    if isinstance(obj, float):
        return obj in (float("inf"), float("-inf"))
    if isinstance(obj, dict):
        return any(_has_inf(v) for v in obj.values())
    if isinstance(obj, list):
        return any(_has_inf(v) for v in obj)
    return False


class FsLockParity(unittest.TestCase):
    # ---- path normalization ----

    def test_norm_and_abs_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = run_probe("norm", cwd=tmp)
            old = os.getcwd()
            os.chdir(tmp)
            try:
                for line in out.splitlines():
                    kind, in_hex, out_hex = line.split("\t")
                    data = bytes.fromhex(in_hex)
                    text = os.fsdecode(data)
                    if kind == "normPath":
                        want = os.fsencode(os.path.normpath(text))
                    else:
                        want = os.fsencode(os.path.abspath(text))
                    self.assertEqual(
                        want.hex(), out_hex, "%s of %r" % (kind, data)
                    )
            finally:
                os.chdir(old)

    # ---- filesystem effects ----

    def test_effects(self):
        probe_root = tempfile.mkdtemp()
        python_root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, probe_root, ignore_errors=True)
        self.addCleanup(shutil.rmtree, python_root, ignore_errors=True)
        make_fixture(python_root)
        make_fixture(probe_root)

        # the probe runs its operations in its own tree, once
        out = run_probe("effects", cwd=probe_root)
        got = []
        for line in out.splitlines():
            parts = line.split("\t")
            if parts[0] == "realpath":
                got.append((parts[0], bytes.fromhex(parts[1]), parts[2], parts[3] if len(parts) > 3 else None))
            else:
                got.append((parts[0], bytes.fromhex(parts[1]), parts[2]))
        self.assertTrue(got, "the probe printed no effects")

        # python reference outcomes, computed on its own tree
        want_makedirs = [py_makedirs(python_root, c) for c in ("d", "f", "dangling", "f/x", "dangling/x", "fresh/a/b")]
        want_copy = ["ERR:" + BY_ERRNO[errno.ENOENT]] + [py_copy_to(python_root, c) for c in ("dst", "new", "d", "tolink")]
        want_move = [
            py_move_across(python_root, "mvsrc", "mvdst"),
            py_move_across(python_root, "missing-src", "mvdst2"),
        ]
        want_real = [py_realpath(python_root, c) for c in ("d", "sym", "sym/sym", "loop", "dangling", "\udcffdir", "d/\udcffdir/../f")]

        i = 0
        for name, want in zip(("d", "f", "dangling", "f/x", "dangling/x", "fresh/a/b"), want_makedirs):
            op, arg, res = got[i]
            self.assertEqual(op, "makedirs")
            self.assertEqual(arg, enc(name))
            self.assertEqual(res, want, "makedirs %s" % name)
            i += 1
        op, arg, res = got[i]
        self.assertEqual(op, "copyto-src")
        self.assertEqual(res, want_copy[0])
        i += 1
        for name, want in zip(("dst", "new", "d", "tolink"), want_copy[1:]):
            op, arg, res = got[i]
            self.assertEqual(op, "copyto")
            self.assertEqual(arg, enc(name))
            self.assertEqual(res, want, "copyto %s" % name)
            i += 1
        for name, want in zip(("mvsrc->mvdst", "missing-src->mvdst2"), want_move):
            op, arg, res = got[i]
            self.assertEqual(op, "moveacross")
            self.assertEqual(arg, enc(name))
            self.assertEqual(res, want, "moveacross %s" % name)
            i += 1
        for name, (status, value) in zip(("d", "sym", "sym/sym", "loop", "dangling", "\udcffdir", "d/\udcffdir/../f"), want_real):
            op, arg, res, resolved = got[i]
            self.assertEqual(op, "realpath")
            self.assertEqual(arg, enc(name))
            self.assertEqual(res, "OK" if status == "OK" else "ERR:" + value, "realpath %s" % name)
            if status == "OK":
                self.assertEqual(bytes.fromhex(resolved), os.path.join(probe_root.encode(), value))
            i += 1

        # the two trees must agree
        self.assert_trees_equal(probe_root, python_root)

    def test_atomic_replace_append(self):
        probe_root = tempfile.mkdtemp()
        python_root = tempfile.mkdtemp()
        # The fixture leaves ro/ at mode 0555. Restore that before rmtree.
        track(self, probe_root)
        track(self, python_root)
        make_atomic_fixture(python_root)
        make_atomic_fixture(probe_root)

        out = run_probe("atomic", cwd=probe_root)
        got = [line.split("\t") for line in out.splitlines()]
        self.assertTrue(got, "the probe printed no atomic cases")

        want = []
        want.append(("atomicwrite", "aw-new", py_atomic_write(python_root, "aw-new", b"new content\n")))
        want.append(("atomicwrite", "aw-keep", py_atomic_write(python_root, "aw-keep", b"replaced\n")))
        want.append(("atomicwrite", "aw-link", py_atomic_write(python_root, "aw-link", b"x\n")))
        want.append(("atomicwrite", "ro/aw-new", py_atomic_write(python_root, "ro/aw-new", b"x\n")))
        want.append(("atomicwrite", "aw-mode", py_atomic_write(python_root, "aw-mode", b"m\n", mode=0o600)))
        want.append(("replacecontents", "rc-keep", py_replace_contents(python_root, "rc-keep", b"replaced\n")))
        want.append(("replacecontents", "rc-missing", py_replace_contents(python_root, "rc-missing", b"x\n")))
        want.append(("replacecontents", "rc-link", py_replace_contents(python_root, "rc-link", b"x\n")))
        want.append(("replacecontents", "ro/rc-keep", py_replace_contents(python_root, "ro/rc-keep", b"x\n")))
        want.append(("appendline", "ap-new", py_append_line(python_root, "ap-new", "fresh line")))
        want.append(("appendline", "ap-exist", py_append_line(python_root, "ap-exist", "second")))
        want.append(("appendline", "ap-link", py_append_line(python_root, "ap-link", "x")))
        want.append(("appendline", "ro/ap-new", py_append_line(python_root, "ro/ap-new", "x")))
        want.append(("appendline", "ap-fifo", py_append_line(python_root, "ap-fifo", "x")))

        for parts, (w_op, w_name, w_res) in zip(got, want):
            g_op, g_arg, g_res = parts[0], parts[1], parts[2]
            self.assertEqual(g_op, w_op)
            self.assertEqual(bytes.fromhex(g_arg), enc(w_name))
            self.assertEqual(g_res, w_res, "%s %s" % (w_op, w_name))
            if w_op == "atomicwrite" and w_name == "ro/aw-new" and g_res != "OK":
                got_msg = bytes.fromhex(parts[3]).decode("utf-8", "surrogateescape")
                ref = fresh_dir()
                track(self, ref)

                def open_temp():
                    os.mkdir("ro", 0o755)
                    os.chmod("ro", 0o555)
                    os.open(
                        zig_temp_for("ro/aw-new"),
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o600,
                    )

                want_msg, _ = _in_dir(ref, lambda: run_oserror(open_temp))
                self.assertEqual(got_msg, want_msg, "atomic write names the temporary file")

        # the two trees must agree, mode bits under the umask included
        self.assert_trees_equal(probe_root, python_root)

    def _osfail(self):
        root = fresh_dir()
        track(self, root)
        out = run_probe("osfail", cwd=root)
        cases = {}
        for line in out.splitlines():
            parts = line.split("\t")
            self.assertEqual(parts[0], "osfail")
            cases[parts[1]] = parts
        return cases

    def _rootlock(self):
        root = fresh_dir()
        track(self, root)
        out = run_probe("rootlock", cwd=root)
        cases = {}
        for line in out.splitlines():
            parts = line.split("\t")
            self.assertEqual(parts[0], "rootlock")
            cases[parts[1]] = parts
        return cases

    def _assert_osfail(self, name, reference):
        parts = self._osfail()[name]
        if parts[2] == "SKIP":
            # open-ro and mkdir-ro skip only when this process is root.
            # write-fsize skips when RLIMIT_FSIZE cannot be lowered.
            if name in ("open-ro", "mkdir-ro"):
                self.assertEqual(os.geteuid(), 0)
            return
        want, exc = reference()
        self.assertEqual(parts[2], "ERR:" + ZIG_ERR[exc.errno], name)
        got = bytes.fromhex(parts[3]).decode("utf-8", "surrogateescape")
        self.assertEqual(got, want, name)

    def _assert_rootlock(self, name, reference):
        parts = self._rootlock()[name]
        if parts[2] == "SKIP":
            self.assertEqual(os.geteuid(), 0)
            return
        want, exc = reference()
        self.assertEqual(parts[2], "ERR:" + ZIG_ERR[exc.errno], name)
        self.assertNotEqual(parts[3], "NONE", name)
        text = bytes.fromhex(parts[3]).decode("utf-8", "surrogateescape")
        path = bytes.fromhex(parts[4]).decode("utf-8", "surrogateescape")
        self.assertEqual(rendered_oserror(text, path), want, name)
        filename = "" if exc.filename is None else os.fsdecode(exc.filename)
        self.assertEqual(path, filename, name)

    def test_open_names_the_temporary_file(self):
        """A failed open names the temporary file, as os.open does."""

        def reference():
            root = fresh_dir()
            track(self, root)

            def op():
                os.mkdir("ro", 0o755)
                os.chmod("ro", 0o555)
                os.open(
                    zig_temp_for("ro/new"),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                )

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_osfail("open-ro", reference)

    def test_write_names_no_file(self):
        """A failed write names no file, as os.write on the descriptor does."""

        def reference():
            root = fresh_dir()
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)

            def op():
                previous = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
                fd = None
                try:
                    resource.setrlimit(resource.RLIMIT_FSIZE, (8, hard))
                    fd = os.open(
                        "fsize-out",
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o600,
                    )
                    data = b"x" * 64
                    off = 0
                    while off < len(data):
                        n = os.write(fd, data[off:])
                        if n == 0:
                            raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
                        off += n
                finally:
                    if fd is not None:
                        os.close(fd)
                    resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))
                    signal.signal(signal.SIGXFSZ, previous)

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_osfail("write-fsize", reference)

    def test_rename_names_both_files(self):
        """A failed rename names the temporary file and the destination."""

        def reference():
            root = fresh_dir()
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)

            def op():
                os.mkdir("adir", 0o755)
                fd = os.open("./.adir.new", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
                os.close(fd)
                os.replace("./.adir.new", "adir")

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_osfail("rename-dir", reference)

    def test_makedirs_names_the_failing_ancestor(self):
        """A missing parent names the mkdir that failed, not the leaf."""

        def reference():
            root = fresh_dir()
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)

            def op():
                os.symlink("nowhere", "gone")
                os.makedirs("gone/a/b", exist_ok=True)

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_osfail("missing-ancestor", reference)

    def test_mkdir_permission_names_the_failing_ancestor(self):
        """A refused mkdir names that ancestor, not the requested leaf."""

        def reference():
            root = fresh_dir()
            track(self, root)

            def op():
                os.mkdir("ro", 0o755)
                os.chmod("ro", 0o555)
                os.makedirs("ro/a/b", exist_ok=True)

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_osfail("mkdir-ro", reference)

    def test_rootlock_preflight_matches_oserror(self):
        """A non-directory state root matches open(O_DIRECTORY)."""

        def reference():
            root = fresh_dir()
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)

            def op():
                fd = os.open("fileroot", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
                os.close(fd)
                os.open("fileroot", os.O_RDONLY | os.O_DIRECTORY)

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_rootlock("file-root", reference)

    def test_rootlock_dangling_root_matches_oserror(self):
        """A dangling state root matches open of that link as a directory."""

        def reference():
            root = fresh_dir()
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)

            def op():
                os.symlink("nowhere", "dangling")
                os.open("dangling", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_rootlock("dangling-root", reference)

    def test_rootlock_names_the_failing_ancestor(self):
        """Creating a state root names the mkdir that failed."""

        def reference():
            root = fresh_dir()
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)

            def op():
                os.symlink("nowhere", "gone")
                os.makedirs("gone/a/b", exist_ok=True)

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_rootlock("ancestor", reference)

    def test_rootlock_gate_names_the_lock_file(self):
        """A refused gate open names STATE_ROOT/.lock, not the root alone."""

        def reference():
            root = fresh_dir()
            track(self, root)

            def op():
                os.mkdir("gate", 0o755)
                os.chmod("gate", 0o555)
                os.open(
                    "gate/.lock",
                    os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                    0o600,
                )

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_rootlock("gate-ro", reference)

    def test_rootlock_sidecar_names_the_lock_file(self):
        """A refused sidecar open names STATE_ROOT/.lock.posix."""

        def reference():
            root = fresh_dir()
            track(self, root)

            def op():
                os.mkdir("side", 0o755)
                fd = os.open(
                    "side/.lock",
                    os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                )
                os.close(fd)
                os.chmod("side", 0o555)
                os.open(
                    "side/.lock.posix",
                    os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                    0o600,
                )

            return _in_dir(root, lambda: run_oserror(op))

        self._assert_rootlock("sidecar-ro", reference)

    def test_rootlock_non_os_refusal_has_no_oserror(self):
        """A directory planted at the gate is not reported as an OSError."""
        parts = self._rootlock()["gate-dir"]
        self.assertEqual(parts[2], "ERR:GateNotPrivate")
        self.assertEqual(parts[3], "NONE")
        self.assertEqual(parts[4], "NONE")

    def test_which_shutil(self):
        with tempfile.TemporaryDirectory() as probe_root, tempfile.TemporaryDirectory() as python_root:
            make_which_fixture(probe_root)
            make_which_fixture(python_root)
            out = run_probe("which", cwd=probe_root)
            old = os.getcwd()
            os.chdir(python_root)
            try:
                checked = 0
                for line in out.splitlines():
                    parts = line.split("\t")
                    if parts[0] == "whichshutil":
                        path = os.fsdecode(bytes.fromhex(parts[1]))
                        name = os.fsdecode(bytes.fromhex(parts[2]))
                        want = shutil.which(name, path=path if path else None)
                        # shutil.which treats an empty PATH as None, using
                        # os.defpath; the probe passes the empty string.
                        if path == "":
                            want = shutil.which(name)
                        got = None if parts[3] == "NULL" else bytes.fromhex(parts[3])
                        want_b = None if want is None else os.fsencode(want)
                        if (want_b is None) != (got is None):
                            self.fail(
                                "which %r in %r: python %r zig %r" % (name, path, want_b, got)
                            )
                        if want_b is not None:
                            self.assertEqual(
                                os.path.relpath(got.decode("utf-8", "surrogateescape")),
                                os.path.relpath(want),
                                "which %r in %r" % (name, path),
                            )
                        checked += 1
                    elif parts[0] == "whichshutil-unset":
                        name = os.fsdecode(bytes.fromhex(parts[1]))
                        want = shutil.which(name, path=os.defpath)
                        got = None if parts[2] == "NULL" else bytes.fromhex(parts[2])
                        if want is None:
                            self.assertIsNone(got, "which %r unset" % name)
                        else:
                            self.assertIsNotNone(got, "which %r unset" % name)
                            self.assertEqual(
                                os.fsencode(want), got, "which %r unset" % name
                            )
                        checked += 1
                self.assertGreaterEqual(checked, 60, "too few which cases")
            finally:
                os.chdir(old)

    def test_diag_repr_oserror(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = run_probe("diag", cwd=tmp)
            checked = 0
            for line in out.splitlines():
                parts = line.split("\t")
                if parts[0] == "repr":
                    data = bytes.fromhex(parts[1])
                    got = bytes.fromhex(parts[2])
                    want = repr(os.fsdecode(data)).encode("utf-8", "surrogateescape")
                    self.assertEqual(want, got, "repr of %r" % data)
                    checked += 1
                elif parts[0] == "oserror":
                    e = int(parts[1])
                    path = bytes.fromhex(parts[2])
                    got = bytes.fromhex(parts[3])
                    want = ("[Errno %d] %s: %r" % (e, os.strerror(e), os.fsdecode(path))).encode(
                        "utf-8", "surrogateescape"
                    )
                    self.assertEqual(want, got, "oserror %d of %r" % (e, path))
                    checked += 1
            self.assertGreaterEqual(checked, 60, "too few diag cases")

    def test_gzip_matches_gzip(self):
        if shutil.which("gzip") is None:
            self.skipTest("gzip is not installed")
        with tempfile.TemporaryDirectory() as probe_root, tempfile.TemporaryDirectory() as python_root:
            make_gzip_fixture(probe_root)
            make_gzip_fixture(python_root)
            out = run_probe("gzip", cwd=probe_root)
            self.assertIn("gzip\tOK", out)
            subprocess.run(
                ["gzip", "-9", "-f", "run.1234.log"],
                cwd=python_root,
                check=True,
            )
            probe_gz = os.path.join(probe_root, "run.1234.log.gz")
            python_gz = os.path.join(python_root, "run.1234.log.gz")
            for name in ("run.1234.log",):
                self.assertFalse(os.path.exists(os.path.join(probe_root, name)))
                self.assertFalse(os.path.exists(os.path.join(python_root, name)))
            st_probe = os.stat(probe_gz)
            st_python = os.stat(python_gz)
            self.assertEqual(stat.S_IMODE(st_probe.st_mode), stat.S_IMODE(st_python.st_mode))
            self.assertEqual(st_probe.st_mtime_ns, st_python.st_mtime_ns)
            self.assertEqual(
                st_probe.st_mtime_ns,
                (1600000000 * 10 ** 9 + 123456789),
                "the mtime the fixture set was kept",
            )
            with open(probe_gz, "rb") as fa:
                probe_bytes = fa.read()
            with open(python_gz, "rb") as fb:
                python_bytes = fb.read()
            # same gzip header: magic, method, flags, mtime, extra flag, os
            self.assertEqual(probe_bytes[:10], python_bytes[:10])
            # same stored name, and the same bytes once decompressed
            self.assertEqual(gzip.decompress(probe_bytes), gzip.decompress(python_bytes))

    def test_env_cli_helpers(self):
        """env parsing, the builder and the usage exit, against what a
        real Python child sees from the same environ block and against
        argparse's error exit code."""
        out = run_probe("envcli")
        lines = [l.split("\t") for l in out.splitlines()]

        # the block the probe parsed
        self.assertEqual(lines[0][0], "env-block")
        block = bytes.fromhex(lines[0][1]).decode().split("\x01")

        # Env.get, recomputed the way a getenv-walking child resolves
        # the block: the first entry wins, an entry without = is not a
        # variable, and the split is at the first =
        def py_get(name):
            for entry in block:
                if "=" not in entry:
                    continue
                key, _, value = entry.partition("=")
                if key == name:
                    return value
            return None

        i = 1
        seen_get = 0
        while lines[i][0] == "env-get":
            name = bytes.fromhex(lines[i][1]).decode()
            if lines[i][2] == "NULL":
                got = None
            else:
                got = bytes.fromhex(lines[i][2]).decode()
            self.assertEqual(py_get(name), got, "env get %r" % name)
            seen_get += 1
            i += 1
        self.assertGreaterEqual(seen_get, 6, "too few env-get cases")

        # the builder ops, replayed with the documented rules
        entries = []
        for entry in block:
            if "=" not in entry:
                continue
            key, _, value = entry.partition("=")
            if not any(k == key for k, _ in entries):
                entries.append((key, value))
        seen_ops = 0
        while lines[i][0] == "builder-op":
            op = lines[i][1]
            name = bytes.fromhex(lines[i][2]).decode()
            value = bytes.fromhex(lines[i][3]).decode() if len(lines[i]) > 3 else None
            if op == "set":
                for pos, (key, _) in enumerate(entries):
                    if key == name:
                        entries[pos] = (name, value)
                        break
                else:
                    entries.append((name, value))
            elif op == "unset":
                entries = [(k, v) for k, v in entries if k != name]
            seen_ops += 1
            i += 1
        self.assertGreaterEqual(seen_ops, 4, "too few builder ops")
        self.assertEqual(lines[i][0], "builder-block")
        built = bytes.fromhex(lines[i][1]).decode()
        if built:
            self.assertEqual(
                [(k, v) for k, _, v in (e.partition("=") for e in built.split("\x01"))],
                entries,
                "the built block",
            )
        else:
            self.assertEqual(entries, [])
        i += 1

        # names execve cannot carry are refused in both
        seen_bad = 0
        while lines[i][0] == "builder-bad":
            name = bytes.fromhex(lines[i][1]).decode()
            value = bytes.fromhex(lines[i][2]).decode()
            self.assertIn("\x00" in value or "=" in name or name == "", (True,), "case not bad")
            self.assertEqual(lines[i][3], "ERR:InvalidArgument", "builder bad %r" % name)
            seen_bad += 1
            i += 1
        self.assertGreaterEqual(seen_bad, 3, "too few bad-name cases")

        # validName against the shell assignment rule
        import re as _re

        seen_names = 0
        while lines[i][0] == "valid-name":
            name = bytes.fromhex(lines[i][1]).decode()
            want = "1" if _re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) else "0"
            self.assertEqual(lines[i][2], want, "validName %r" % name)
            seen_names += 1
            i += 1
        self.assertGreaterEqual(seen_names, 5, "too few validName cases")

        # the usage exit against argparse's own error exit
        self.assertEqual(lines[i][0], "usage-exit")
        self.assertEqual(int(lines[i][1]), 2)
        probe_code = subprocess.run(
            [
                sys.executable,
                "-c",
                "import argparse\n"
                "p = argparse.ArgumentParser(prog='tool')\n"
                "try:\n"
                "    p.parse_args(['--nope'])\n"
                "except SystemExit as e:\n"
                "    print(e.code)\n",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=True,
        ).stdout.strip()
        self.assertEqual(int(lines[i][1]), int(probe_code), "argparse exit")

    def test_errno_describe_and_frames(self):
        """sys errno text against os.strerror for every errno the kernel
        names, and the [Errno N] framing against str(OSError(...))."""
        out = run_probe("errno")
        checked_desc = checked_text = checked_frame = 0
        for line in out.splitlines():
            parts = line.split("\t")
            if parts[0] == "errno-desc":
                n = int(parts[1])
                got = bytes.fromhex(parts[2])
                want = ("[Errno %d] %s" % (n, os.strerror(n))).encode()
                self.assertEqual(want, got, "describeErrno %d" % n)
                checked_desc += 1
            elif parts[0] == "errno-text":
                n = int(parts[1])
                py = os.strerror(n)
                if parts[2] == "NULL":
                    # errnoText names fewer errnos than glibc: the null
                    # contract, exercised where glibc has no name
                    self.assertEqual(py, "Unknown error %d" % n, "errnoText null at %d" % n)
                else:
                    got = bytes.fromhex(parts[2])
                    self.assertEqual(py.encode(), got, "errnoText %d" % n)
                checked_text += 1
            elif parts[0] == "errno-frame":
                n = int(parts[1])
                path = bytes.fromhex(parts[2])
                got = bytes.fromhex(parts[3])
                want = (
                    "[Errno %d] %s: %r" % (n, os.strerror(n), os.fsdecode(path))
                ).encode("utf-8", "surrogateescape")
                self.assertEqual(want, got, "frame %d of %r" % (n, path))
                checked_frame += 1
        self.assertGreaterEqual(checked_desc, 150, "too few describeErrno cases")
        self.assertGreaterEqual(checked_text, 150, "too few errnoText cases")
        self.assertGreaterEqual(checked_frame, 90, "too few framing cases")

    def test_copy_and_rename_edges(self):
        """copyTo and moveAcross edges against shutil and os: cross-device
        moves, a read-only destination, a symlinked destination, a
        destination that cannot take the whole write and a source removed
        after its descriptor was opened."""
        if not os.path.isdir("/dev/shm"):
            self.skipTest("no /dev/shm for a second device")

        def run_edge_cases(root, other, is_probe):
            """Both sides run the same sequence; the reference uses the
            Python calls the tools replaced."""
            results = {}

            # the fixture the probe's copyedges mode expects in its
            # working directory; the second-device fixture under
            # /dev/shm the probe builds itself
            for name, content, mode in (
                ("src", b"move me across\n", 0o640),
                ("victim2", b"second source\n", 0o640),
                ("victim", b"keep me\n", 0o644),
                ("fsize-src", b"x" * 64, 0o644),
                ("fsize-dst", b"precious\n", 0o644),
                ("unlink-src", b"still readable\n", 0o644),
            ):
                fd = os.open(os.path.join(root, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
                try:
                    os.write(fd, content)
                finally:
                    os.close(fd)
                os.chmod(os.path.join(root, name), mode)
            os.symlink("victim", os.path.join(root, "dst-link"))
            os.mkdir(os.path.join(root, "ro"), 0o755)
            os.chmod(os.path.join(root, "ro"), 0o555)
            _ = other

        with tempfile.TemporaryDirectory() as probe_root, tempfile.TemporaryDirectory() as python_root:
            if os.stat(probe_root).st_dev == os.stat("/dev/shm").st_dev:
                self.skipTest("/dev/shm is on the same device as the temporary directory")
            shm_probe = "/dev/shm/zc-parity-copyedges-probe"
            shm_python = "/dev/shm/zc-parity-copyedges-python"
            for p in (shm_probe, shm_python):
                shutil.rmtree(p, ignore_errors=True)
                os.mkdir(p, 0o755)
            run_edge_cases(probe_root, shm_probe, True)
            run_edge_cases(python_root, shm_python, False)
            try:
                # the probe runs its cases in its own tree
                out = run_probe("copyedges", cwd=probe_root)
                cases = {}
                for line in out.splitlines():
                    parts = line.split("\t")
                    cases[bytes.fromhex(parts[1]).decode()] = parts[2]

                # the reference, mirroring the documented library
                # behavior with the Python calls the tools replaced
                try:
                    fd = os.open(
                        os.path.join(python_root, "ro", ".t.tmp"),
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    )
                except PermissionError as exc:
                    self.assertEqual(exc.errno, errno.EACCES)
                    self.assertEqual(cases["copy-ro"], "ERR:AccessDenied")
                else:
                    self.fail("read-only dir accepted a new file")

                # copyTo onto a symlink: the documented refusal, where
                # shutil.copy2 would follow the link
                self.assertEqual(cases["copy-link"], "ERR:SymLink")
                self.assertTrue(os.path.islink(os.path.join(python_root, "dst-link")))

                # os.replace over two filesystems: EXDEV, which the
                # documented fallback turns into a copy
                try:
                    os.replace(
                        os.path.join(python_root, "src"),
                        os.path.join(shm_python, "moved"),
                    )
                except OSError as exc:
                    self.assertEqual(exc.errno, errno.EXDEV)

                # moveAcross over EXDEV: os.replace refuses; the
                # documented fallback copies, publishes and removes
                self.assertEqual(cases["move-exdev"], "OK")

                # moveAcross over EXDEV into a read-only directory
                self.assertEqual(cases["move-exdev-ro"], "ERR:AccessDenied")

                # moveAcross over EXDEV onto a symlink replaces it, as
                # os.replace would on one filesystem
                self.assertEqual(cases["move-exdev-link"], "OK")
                self.assertFalse(os.path.islink(os.path.join(shm_probe, "moved-link")))

                # a write the file-size limit stops keeps the old bytes
                # and leaves no temporary behind; EFBIG is not in the
                # named error set and surfaces as Unexpected
                self.assertEqual(cases["copy-fsize"], "ERR:Unexpected")
                with open(os.path.join(probe_root, "fsize-dst"), "rb") as f:
                    self.assertEqual(f.read(), b"precious\n")

                # a source removed after its descriptor was opened still
                # copies in full, as the open descriptor keeps the data
                self.assertEqual(cases["copy-unlinked"], "OK")
                with open(os.path.join(probe_root, "unlinked-dst"), "rb") as f:
                    self.assertEqual(f.read(), b"still readable\n")

                # the cross-device move published the source's bytes and
                # mode, and removed the source
                with open(os.path.join(shm_probe, "moved"), "rb") as f:
                    self.assertEqual(f.read(), b"move me across\n")
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(shm_probe, "moved")).st_mode), 0o640)
                self.assertFalse(os.path.exists(os.path.join(probe_root, "src")))
            finally:
                for p in (shm_probe, shm_python):
                    ro = os.path.join(p, "ro")
                    if os.path.isdir(ro):
                        os.chmod(ro, 0o755)
                    shutil.rmtree(p, ignore_errors=True)

    def test_gunzip_matches_python_gzip(self):
        """logs.gunzip over a run-time corpus against Python's gzip
        module, whose errors and outputs the reference recomputes from
        the same bytes; GNU gzip checked the same corpus by hand when
        the mode was written."""
        out = run_probe("gunzip")
        checked = ok_cases = 0
        for line in out.splitlines():
            parts = line.split("\t")
            if parts[0] != "gunzip":
                continue
            name = bytes.fromhex(parts[1]).decode()
            limit = int(parts[2])
            blob = bytes.fromhex(parts[3])
            try:
                want = gzip.decompress(blob)
            except (gzip.BadGzipFile, EOFError, OSError):
                want = None
            if want is None:
                self.assertTrue(
                    parts[4].startswith("ERR:"),
                    "gunzip %s: python refuses, the probe says %s" % (name, parts[4]),
                )
                self.assertNotEqual(
                    parts[4],
                    "ERR:StreamTooLong",
                    "gunzip %s: the limit cannot be the refusal when python refuses too"
                    % name,
                )
            elif len(want) >= limit:
                self.assertEqual(
                    parts[4],
                    "ERR:StreamTooLong",
                    "gunzip %s: the limit should refuse" % name,
                )
            else:
                self.assertEqual(parts[4], "OK", "gunzip %s" % name)
                self.assertEqual(
                    bytes.fromhex(parts[5]), want, "gunzip %s bytes" % name
                )
                ok_cases += 1
            checked += 1
        self.assertGreaterEqual(checked, 16, "too few gunzip cases")
        self.assertGreaterEqual(ok_cases, 8, "too few accepted gunzip cases")

    def test_json_fuzz(self):
        """parse, toPy and Value.get over an edge corpus and a seeded
        random one, against Python's json.loads on strictly decoded
        text, the way the consumers read it: arch-guard decodes with
        blob.decode("utf-8") before json.loads, and eb-staged-rebuild
        decodes strict UTF-8 in engine, journal, metrics and outbox. A
        raw byte that is not UTF-8 is a refusal that must match."""
        out = run_probe("jsonfuzz")
        parse_ok = refusal_ok = topy_ok = get_ok = roundtrip_ok = 0

        for line in out.splitlines():
            parts = line.split("\t")
            doc = bytes.fromhex(parts[1])
            try:
                text = doc.decode("utf-8")
            except UnicodeDecodeError:
                # the consumers decode strict UTF-8 and refuse the
                # whole document; the library must refuse it too, and
                # the byte parser accepts it, toPy carries the refusal
                if parts[0] == "json-topy":
                    self.assertEqual(
                        parts[2],
                        "ERR:Encoding",
                        "toPy of raw non-UTF-8 %r" % doc[:60],
                    )
                    refusal_ok += 1
                continue

            if parts[0] == "json-parse":
                try:
                    obj = json.loads(text, parse_constant=_raise_constant)
                except _Literal:
                    continue
                except ValueError:
                    continue
                if _depth(obj) > 32:
                    continue
                self.assertEqual(parts[2], "OK", "parse of %r" % text[:60])
                parse_ok += 1
                continue

            try:
                state = json.loads(text, parse_constant=_raise_constant)
            except (_Literal, ValueError):
                continue
            if _depth(state) > 32:
                continue

            if parts[0] == "json-topy":
                if _bad_doc(state):
                    self.assertEqual(
                        parts[2], "ERR:Encoding", "toPy of %r" % text[:60]
                    )
                else:
                    self.assertEqual(parts[2], "OK", "toPy of %r" % text[:60])
                    self.assertEqual(
                        bytes.fromhex(parts[3]).decode(),
                        json.dumps(state, indent=0),
                        "toPy value of %r" % text[:60],
                    )
                    topy_ok += 1
            elif parts[0] == "json-get":
                if not isinstance(state, dict) or "k" not in state:
                    self.assertEqual(parts[2], "MISSING", "get of %r" % text[:60])
                elif not isinstance(state["k"], str):
                    self.assertEqual(parts[2], "OTHER", "get of %r" % text[:60])
                elif _bad_lone(state["k"]):
                    self.assertEqual(
                        parts[2], "ERR:Encoding", "get of %r" % text[:60]
                    )
                else:
                    self.assertEqual(parts[2], "OK", "get of %r" % text[:60])
                    self.assertEqual(
                        bytes.fromhex(parts[3]),
                        os.fsencode(state["k"]),
                        "get value of %r" % text[:60],
                    )
                    get_ok += 1
            elif parts[0] == "json-roundtrip":
                if _has_inf(state):
                    self.assertEqual(
                        parts[2],
                        "ERR:Syntax",
                        "the Infinity literal round trip of %r" % text[:60],
                    )
                else:
                    self.assertEqual(
                        parts[2], "OK", "round trip of %r" % text[:60]
                    )
                    roundtrip_ok += 1

        # every raw non-UTF-8 document must be refused somewhere, which
        # the toPy lines carry for the ones the byte parser accepts
        refusals = sum(
            1
            for line in out.splitlines()
            if line.split("\t")[0] == "json-topy"
            and line.split("\t")[2] == "ERR:Encoding"
        )
        self.assertGreaterEqual(refusals, 10, "too few non-UTF-8 refusals")
        self.assertGreaterEqual(parse_ok, 40, "too few accepted documents")
        self.assertGreaterEqual(topy_ok, 25, "too few toPy values")
        self.assertGreaterEqual(get_ok, 25, "too few get values")
        self.assertGreaterEqual(roundtrip_ok, 25, "too few round trips")

    def assert_trees_equal(self, a, b):
        root_a, root_b = os.fsencode(a), os.fsencode(b)
        names_a = sorted(os.listdir(root_a))
        names_b = sorted(os.listdir(root_b))
        self.assertEqual(names_a, names_b)
        for name in names_a:
            pa = os.path.join(root_a, name)
            pb = os.path.join(root_b, name)
            self.assertFalse(
                name.startswith(b".") or b".tmp." in name,
                "leftover temporary %r" % name,
            )
            sa, sb = os.lstat(pa), os.lstat(pb)
            self.assertEqual(
                (os.path.stat.S_IFMT(sa.st_mode), sa.st_mode & 0o7777, sa.st_size),
                (os.path.stat.S_IFMT(sb.st_mode), sb.st_mode & 0o7777, sb.st_size),
                "stat differs for %r" % name,
            )
            if os.path.stat.S_ISLNK(sa.st_mode):
                self.assertEqual(os.readlink(pa), os.readlink(pb))
                continue
            if os.path.stat.S_ISDIR(sa.st_mode):
                self.assert_trees_equal(pa, pb)
                continue
            if os.path.stat.S_ISREG(sa.st_mode):
                with open(pa, "rb") as fa, open(pb, "rb") as fb:
                    self.assertEqual(fa.read(), fb.read(), "content differs for %r" % name)
                if name in (b"mvdst",):
                    self.assertEqual(sa.st_mtime_ns, sb.st_mtime_ns, "mtime differs for %r" % name)
                    want = MTIME_CHECK["mvdst"]
                    self.assertEqual(
                        (sa.st_mtime_ns, sb.st_mtime_ns),
                        (want[0] * 10 ** 9 + want[1],) * 2,
                    )

    # ---- flock semantics ----

    def test_try_lock_times_out_while_python_holds(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "lockfile")
            open(path, "wb").close()
            fd = os.open(path, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                out = run_probe("try-lock", path)
                self.assertEqual(out, "lockExclusive\tTimedOut\n")
            finally:
                os.close(fd)

    def test_hold_lock_blocks_python_then_releases(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "lockfile")
            open(path, "wb").close()
            proc = subprocess.Popen(
                [probe_path(), "hold-lock", path, "1200"],
                stdout=subprocess.PIPE,
            )
            try:
                self.assertEqual(proc.stdout.readline().decode(), "held\n")
                fd = os.open(path, os.O_RDWR)
                try:
                    with self.assertRaises(BlockingIOError) as caught:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.assertEqual(caught.exception.errno, errno.EAGAIN)
                finally:
                    os.close(fd)
                proc.wait(timeout=10)
                proc.stdout.close()
                fd = os.open(path, os.O_RDWR)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(fd)
            finally:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    unittest.main()
