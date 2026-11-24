"""Parity test for fsx.TempDir against tempfile.gettempdir.

The probe (tests/tempdir_probe.zig, built by `zig build tempdir-probe`)
and a Python one-liner run in a fresh process under the same environment,
working directory and file size limit, and their output lines are compared
byte for byte. The scenarios are generated here, in a temporary tree, so
no fixture is committed: writable and unwritable directories, files and
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
from typing import Dict, List, Optional

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "zig-out" / "bin" / "tempdir_probe"

LAUNCHER = r"""
import os, resource, sys
cap, gone = sys.argv[1], sys.argv[2]
if gone != "-":
    os.mkdir(gone)
    os.chdir(gone)
    os.rmdir(gone)
if cap != "-":
    n = int(cap)
    resource.setrlimit(resource.RLIMIT_FSIZE, (n, n))
os.execv(sys.argv[3], sys.argv[3:])
"""

PYTHON_PROBE = r"""
import os, sys, tempfile
try:
    line = b"ok\t" + os.fsencode(tempfile.gettempdir()) + b"\n"
except OSError as exc:
    line = (
        b"err\t" + type(exc).__name__.encode() + b"\t" + os.fsencode(str(exc)) + b"\n"
    )
os.write(1, line)
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

    def _run(self, program: List[str], env: Dict[object, object], cap: Optional[int], gone: bool):
        argv = [
            sys.executable,
            "-c",
            LAUNCHER,
            "-" if cap is None else str(cap),
            str(self.root / "gone") if gone else "-",
            *program,
        ]
        raw = {_bytes(k): _bytes(v) for k, v in env.items()}
        return subprocess.run(
            argv,
            env=raw,
            cwd=self.work,
            capture_output=True,
            timeout=20,
            check=False,
        )

    def _agree(self, label: str, env: Dict[object, object], cap: Optional[int] = None, gone: bool = False):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **env}
        python = self._run([sys.executable, "-S", "-c", PYTHON_PROBE], env, cap, gone)
        probe = self._run([str(PROBE)], env, cap, gone)
        with self.subTest(case=label):
            self.assertEqual(python.returncode, 0, python.stderr)
            self.assertEqual(probe.returncode, 0, probe.stderr)
            self.assertEqual(probe.stdout, python.stdout)
        return python.stdout

    def test_variable_precedence_and_system_fallback(self) -> None:
        good, good2 = str(self.good), str(self.good2)
        bad = {
            "locked": str(self.locked),
            "file": str(self.plain),
            "missing": str(self.missing),
            "empty": "",
        }
        self._agree("no variables", {})
        self._agree("TMPDIR", {"TMPDIR": good})
        self._agree("TEMP only", {"TEMP": good})
        self._agree("TMP only", {"TMP": good})
        self._agree("TMPDIR over TEMP", {"TMPDIR": good, "TEMP": good2})
        self._agree("TEMP over TMP", {"TEMP": good, "TMP": good2})
        for name, value in bad.items():
            self._agree("%s TMPDIR, TEMP good" % name, {"TMPDIR": value, "TEMP": good})
            self._agree("%s TMPDIR, TMP good" % name, {"TMPDIR": value, "TMP": good})
            self._agree("%s all three" % name, {"TMPDIR": value, "TEMP": value, "TMP": value})
        self._agree("mode 0500 then writable", {"TMPDIR": str(self.locked), "TEMP": good})
        out = self._agree("unwritable then writable", {"TMPDIR": "/proc", "TEMP": good})
        self.assertEqual(out, b"ok\t" + good.encode() + b"\n")

    def test_values_are_made_absolute_and_normalized(self) -> None:
        good = str(self.good)
        self._agree("trailing slashes", {"TMPDIR": good + "///"})
        self._agree("dot segments", {"TMPDIR": good + "/./sub/../."})
        self._agree("double slash", {"TMPDIR": good.replace("/", "//", 1)})
        (self.work / "rel").mkdir()
        self._agree("relative", {"TMPDIR": "rel"})
        self._agree("relative dot segments", {"TMPDIR": "./rel/../rel/."})
        self._agree("relative parent", {"TMPDIR": "../good"})
        self._agree("dot", {"TMPDIR": "."})
        self._agree("link is not resolved", {"TMPDIR": str(self.link)})

    def test_file_size_limit(self) -> None:
        env = {"TMPDIR": str(self.good)}
        self._agree("limit of the probe size", env, cap=4)
        self._agree("limit under the probe size", env, cap=3)
        self._agree("limit of one byte", env, cap=1)

    def test_failure_text(self) -> None:
        env: Dict[object, object] = {"TMPDIR": str(self.good)}
        out = self._agree("every probe write fails", env, cap=0)
        self.assertTrue(out.startswith(b"err\tFileNotFoundError\t[Errno 2] No usable"), out)
        self._agree("all variables", {"TMPDIR": "it's", "TEMP": 'a"b', "TMP": "back\\slash"}, cap=0)
        self._agree(
            "non-UTF-8 and control bytes",
            {b"TMPDIR": b"x\xffy\n", b"TEMP": b"\t\x01\xc3\xa9", b"TMP": b"/p\xed\xa0\x80"},
            cap=0,
        )
        self._agree("quote and double quote", {"TMPDIR": "it's \"x\""}, cap=0)
        self._agree("removed working directory", env, cap=0, gone=True)
        self._agree("removed working directory, writable", env, gone=True)
        self._agree("removed working directory, relative value", {"TMPDIR": "rel"}, gone=True)


if __name__ == "__main__":
    unittest.main()
