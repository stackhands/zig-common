#!/usr/bin/env python3
"""Differential parity test for zig-common's fsx, atomic and state layers.

The probe binary (tests/fs_lock_parity_probe.zig, built by `zig build
fs-lock-parity-probe`) prints one case per line. Path normalization is compared
with os.path.normpath and os.path.abspath byte for byte; filesystem
effects run twice, once through the library on one fixture tree and
once through the Python reference calls on an identical one, and the
two trees plus the surfaced errnos are compared; realpath is compared
with os.path.realpath(strict=True); flock exclusive and try semantics
are exercised in both directions with fcntl.flock.

Run with `python3 tests/test_fs_lock_parity.py` from a checkout that has
the probe built; the test builds it when zig is on PATH and the binary
is missing. ZIG_COMMON_PARITY_PROBE names another binary.
"""
import errno
import fcntl
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROBE = os.path.join(REPO, "zig-out", "bin", "fs_lock_parity_probe")

# zig error names by the errno Python's reference call raises.
BY_ERRNO = {errno.EEXIST: "Exists", errno.ENOTDIR: "NotDir", errno.ENOENT: "NotFound"}

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


def probe_path():
    path = os.environ.get("ZIG_COMMON_PARITY_PROBE", DEFAULT_PROBE)
    if not os.path.exists(path):
        subprocess.run(["zig", "build", "fs-lock-parity-probe"], cwd=REPO, check=True)
    return path


def run_probe(mode, *args, cwd=None):
    return subprocess.run(
        [probe_path(), mode, *args], cwd=cwd, check=True, stdout=subprocess.PIPE
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
    try:
        os.makedirs(os.path.join(root.encode(), enc(name)), exist_ok=True)
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
        mode = 0o600 if existing is not None else src_mode
        out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
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


class FsLockParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._old_umask = os.umask(0o022)

    @classmethod
    def tearDownClass(cls):
        os.umask(cls._old_umask)

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

    def assert_trees_equal(self, a, b):
        root_a, root_b = os.fsencode(a), os.fsencode(b)
        names_a = sorted(os.listdir(root_a))
        names_b = sorted(os.listdir(root_b))
        self.assertEqual(names_a, names_b)
        for name in names_a:
            pa = os.path.join(root_a, name)
            pb = os.path.join(root_b, name)
            self.assertFalse(name.startswith(b"."), "leftover temporary %r" % name)
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
