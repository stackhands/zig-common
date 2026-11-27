"""Parity test for fsx.TempDir against tempfile.gettempdir.

The probe (tests/tempdir_probe.zig, built by `zig build tempdir-probe`)
and one Python process read the same batch of cases on stdin. Each case
is an environment, an optional file size limit, and whether the working
directory has been removed. Their output lines are compared byte for
byte. The scenarios are generated here, in a temporary tree, so no
fixture is committed: writable and unwritable directories, files and
links in place of directories, relative and unnormalized values, empty
values, the three variable names in every order of precedence, a removed
working directory, and a file size limit that makes the probe write fail.
A directory of mode 0500 is unwritable only where permission checks apply,
and the comparison holds either way. The case that needs an unwritable
candidate uses /proc, where no user can create a file.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "zig-out" / "bin" / "tempdir_probe"

BATCH = r"""
import os, resource, signal, sys, tempfile
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
lines = sys.stdin.buffer.read().decode("ascii").splitlines()
n = int(lines[0])
i = 1
saved = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
try:
    for _ in range(n):
        cap_s, gone_s, nenv_s = lines[i].split("\t")
        i += 1
        nenv = int(nenv_s)
        for key in list(os.environb):
            del os.environb[key]
        for _env in range(nenv):
            hk, hv = lines[i].split("\t")
            i += 1
            os.environb[bytes.fromhex(hk)] = bytes.fromhex(hv)
        tempfile.tempdir = None
        if cap_s == "-":
            resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))
        else:
            cap = int(cap_s)
            resource.setrlimit(resource.RLIMIT_FSIZE, (cap, hard))
        if gone_s == "1":
            os.mkdir("gone-batch")
            os.chdir("gone-batch")
            os.rmdir(os.path.join(os.getcwd(), "..", "gone-batch"))
        try:
            line = b"ok\t" + os.fsencode(tempfile.gettempdir()) + b"\n"
        except OSError as exc:
            line = (
                b"err\t"
                + type(exc).__name__.encode()
                + b"\t"
                + os.fsencode(str(exc))
                + b"\n"
            )
        os.write(1, line)
        if gone_s == "1":
            os.fchdir(saved)
finally:
    os.close(saved)
"""


def _bytes(value: object) -> bytes:
    return value if isinstance(value, bytes) else os.fsencode(value)


class GetTempDirParityTests(unittest.TestCase):
    def setUp(self) -> None:
        if not PROBE.exists():
            self.skipTest("run `zig build tempdir-probe` first")
        self.root = Path(tempfile.mkdtemp(prefix="gettempdir-parity-")).resolve()
        self.addCleanup(self._cleanup)
        self.work = self.root / "work"
        self.work.mkdir()
        self.good = self.root / "good"
        self.good.mkdir()
        self.good2 = self.root / "good2"
        self.good2.mkdir()
        self.locked = self.root / "locked"
        self.locked.mkdir()
        self.locked.chmod(0o500)
        self.plain = self.root / "plain-file"
        self.plain.write_bytes(b"x")
        self.link = self.root / "link"
        self.link.symlink_to(self.good)
        self.missing = self.root / "missing"

    def _cleanup(self) -> None:
        for path in self.root.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        shutil.rmtree(self.root, ignore_errors=True)

    def _payload(self, cases: List[tuple]) -> bytes:
        path = os.environ.get("PATH", "/usr/bin:/bin")
        lines = [str(len(cases))]
        for _label, env, cap, gone in cases:
            merged: Dict[object, object] = {"PATH": path, **env}
            cap_s = "-" if cap is None else str(cap)
            lines.append("%s\t%s\t%d" % (cap_s, "1" if gone else "0", len(merged)))
            for key, value in merged.items():
                lines.append("%s\t%s" % (_bytes(key).hex(), _bytes(value).hex()))
        return ("\n".join(lines) + "\n").encode("ascii")

    def _batch(self, cases: List[tuple]) -> List[bytes]:
        payload = self._payload(cases)
        python = subprocess.run(
            [sys.executable, "-S", "-c", BATCH],
            input=payload,
            cwd=self.work,
            capture_output=True,
            timeout=30,
            check=False,
        )
        probe = subprocess.run(
            [str(PROBE)],
            input=payload,
            cwd=self.work,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(python.returncode, 0, python.stderr)
        self.assertEqual(probe.returncode, 0, probe.stderr)
        py_lines = python.stdout.splitlines(keepends=True)
        pr_lines = probe.stdout.splitlines(keepends=True)
        self.assertEqual(len(py_lines), len(cases), python.stdout)
        self.assertEqual(len(pr_lines), len(cases), probe.stdout)
        for case, py, pr in zip(cases, py_lines, pr_lines):
            with self.subTest(case=case[0]):
                self.assertEqual(pr, py)
        return py_lines

    def test_variable_precedence_and_system_fallback(self) -> None:
        good, good2 = str(self.good), str(self.good2)
        bad = {
            "locked": str(self.locked),
            "file": str(self.plain),
            "missing": str(self.missing),
            "empty": "",
        }
        cases: List[tuple] = [
            ("no variables", {}, None, False),
            ("TMPDIR", {"TMPDIR": good}, None, False),
            ("TEMP only", {"TEMP": good}, None, False),
            ("TMP only", {"TMP": good}, None, False),
            ("TMPDIR over TEMP", {"TMPDIR": good, "TEMP": good2}, None, False),
            ("TEMP over TMP", {"TEMP": good, "TMP": good2}, None, False),
        ]
        for name, value in bad.items():
            cases.append(("%s TMPDIR, TEMP good" % name, {"TMPDIR": value, "TEMP": good}, None, False))
            cases.append(("%s TMPDIR, TMP good" % name, {"TMPDIR": value, "TMP": good}, None, False))
            cases.append(("%s all three" % name, {"TMPDIR": value, "TEMP": value, "TMP": value}, None, False))
        cases.append(("mode 0500 then writable", {"TMPDIR": str(self.locked), "TEMP": good}, None, False))
        cases.append(("unwritable then writable", {"TMPDIR": "/proc", "TEMP": good}, None, False))
        lines = self._batch(cases)
        self.assertEqual(lines[-1], b"ok\t" + good.encode() + b"\n")

    def test_values_are_made_absolute_and_normalized(self) -> None:
        good = str(self.good)
        (self.work / "rel").mkdir()
        self._batch(
            [
                ("trailing slashes", {"TMPDIR": good + "///"}, None, False),
                ("dot segments", {"TMPDIR": good + "/./sub/../."}, None, False),
                ("double slash", {"TMPDIR": good.replace("/", "//", 1)}, None, False),
                ("relative", {"TMPDIR": "rel"}, None, False),
                ("relative dot segments", {"TMPDIR": "./rel/../rel/."}, None, False),
                ("relative parent", {"TMPDIR": "../good"}, None, False),
                ("dot", {"TMPDIR": "."}, None, False),
                ("link is not resolved", {"TMPDIR": str(self.link)}, None, False),
            ]
        )

    def test_file_size_limit(self) -> None:
        env = {"TMPDIR": str(self.good)}
        self._batch(
            [
                ("limit of the probe size", env, 4, False),
                ("limit under the probe size", env, 3, False),
                ("limit of one byte", env, 1, False),
            ]
        )

    def test_failure_text(self) -> None:
        env: Dict[object, object] = {"TMPDIR": str(self.good)}
        lines = self._batch(
            [
                ("every probe write fails", env, 0, False),
                ("all variables", {"TMPDIR": "it's", "TEMP": 'a"b', "TMP": "back\\slash"}, 0, False),
                (
                    "non-UTF-8 and control bytes",
                    {b"TMPDIR": b"x\xffy\n", b"TEMP": b"\t\x01\xc3\xa9", b"TMP": b"/p\xed\xa0\x80"},
                    0,
                    False,
                ),
                ("quote and double quote", {"TMPDIR": "it's \"x\""}, 0, False),
                ("removed working directory", env, 0, True),
                ("removed working directory, writable", env, None, True),
                ("removed working directory, relative value", {"TMPDIR": "rel"}, None, True),
            ]
        )
        self.assertTrue(lines[0].startswith(b"err\tFileNotFoundError\t[Errno 2] No usable"), lines[0])


if __name__ == "__main__":
    unittest.main()
