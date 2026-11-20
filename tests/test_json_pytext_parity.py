"""Differential parity test for zig-common's JSON and pytext output.

The probe binary (tests/parity_probe.zig, built by `zig build
parity-probe`) prints one case per line: kind, hex input and hex
output, tab separated. Every case is recomputed here with the Python
call the module promises to match, and the bytes are compared, so an
escape, a float format or a sort order cannot drift quietly.

Run with `python3 tests/test_json_pytext_parity.py` from a checkout
that has the probe built; the test builds it when zig is on PATH and
the binary is missing. ZIG_COMMON_PARITY_PROBE names another binary.
"""
import json
import os
import random
import shlex
import struct
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROBE = os.path.join(REPO, "zig-out", "bin", "parity_probe")

# The kinds the probe must cover. A kind with no cases means the parity
# is silently unchecked, so the counts are asserted, not just the lines.
KINDS = ("cache", "wire", "quote", "strip", "split", "replace", "float", "dumps", "strerror", "oserror", "dumpscompact")
MIN_CASES = {
    "cache": 1500,
    "wire": 1500,
    "quote": 1500,
    "strip": 1500,
    "split": 1500,
    "replace": 1500,
    "float": 2000,
    "dumps": 90,
    "strerror": 300,
    "oserror": 100,
    "dumpscompact": 24,
}


def probe_path():
    path = os.environ.get("ZIG_COMMON_PARITY_PROBE", DEFAULT_PROBE)
    if not os.path.exists(path):
        subprocess.run(["zig", "build", "parity-probe"], cwd=REPO, check=True)
    return path


def probe_cases():
    out = subprocess.run([probe_path()], check=True, stdout=subprocess.PIPE)
    cases = {kind: [] for kind in KINDS}
    for line in out.stdout.decode("ascii").splitlines():
        kind, in_hex, out_hex = line.split("\t")
        cases[kind].append((in_hex, out_hex))
    return cases


def cache_expected(data):
    return json.dumps(data.decode("utf-8", "surrogateescape"), ensure_ascii=True).encode("ascii")


def wire_expected(data):
    return json.dumps(data.decode("latin-1"), ensure_ascii=True).encode("ascii")


def quote_expected(data):
    text = data.decode("utf-8", "surrogateescape")
    return shlex.quote(text).encode("utf-8", "surrogateescape")


def strip_expected(data):
    return data.decode("utf-8", "surrogateescape").strip().encode("utf-8", "surrogateescape")


def split_expected(data):
    parts = data.decode("utf-8", "surrogateescape").split()
    return " ".join(p.encode("utf-8", "surrogateescape").hex() for p in parts)


def replace_expected(data):
    return data.decode("utf-8", "replace").encode("utf-8")


def float_expected(data):
    return json.dumps(struct.unpack("<d", data)[0]).encode("ascii")


def dumpscompact_expected(data, zig_out):
    sort = data.decode("ascii")
    parsed = json.loads(zig_out.decode("ascii"))
    return json.dumps(parsed, sort_keys=sort == "true").encode("ascii")


def dumps_expected(data, zig_out):
    indent, sort = data.decode("ascii").split(",")
    parsed = json.loads(zig_out.decode("ascii"))
    return json.dumps(parsed, indent=int(indent), sort_keys=sort == "true").encode("ascii")


def strerror_expected(data):
    (code,) = struct.unpack("<H", data)
    return os.strerror(code).encode("utf-8")


def oserror_expected(data):
    (code,) = struct.unpack("<H", data[:2])
    path = data[2:].decode("utf-8", "surrogateescape")
    return str(OSError(code, os.strerror(code), path)).encode("utf-8", "surrogateescape")


class JsonPytextParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = probe_cases()

    def assert_parity(self, kind, expected_of):
        bad = []
        for in_hex, out_hex in self.cases[kind]:
            data = bytes.fromhex(in_hex)
            if kind == "split":
                # The split output is the parts' hex, spaced, not one blob.
                want = expected_of(data)
                if want != out_hex:
                    bad.append((in_hex, out_hex, want))
                continue
            zig_out = bytes.fromhex(out_hex)
            if kind == "dumps":
                want = dumps_expected(data, zig_out)
            elif kind == "dumpscompact":
                want = dumpscompact_expected(data, zig_out)
            else:
                want = expected_of(data)
            want_hex = want if isinstance(want, str) else want.hex()
            if want_hex != out_hex:
                bad.append((in_hex, out_hex, want_hex))
        message = kind
        if bad:
            first_in, first_zig, first_python = bad[0]
            message = (
                f"{kind}: {len(bad)} of {len(self.cases[kind])} cases differ; "
                f"first: in={first_in} zig={first_zig} python={first_python}"
            )
        self.assertEqual(len(bad), 0, message)

    def test_cache_strings(self):
        self.assert_parity("cache", cache_expected)

    def test_wire_strings(self):
        self.assert_parity("wire", wire_expected)

    def test_shell_quote(self):
        self.assert_parity("quote", quote_expected)

    def test_py_strip(self):
        self.assert_parity("strip", strip_expected)

    def test_py_split(self):
        self.assert_parity("split", split_expected)

    def test_decode_replace(self):
        self.assert_parity("replace", replace_expected)

    def test_float_repr(self):
        self.assert_parity("float", float_expected)

    def test_dumps_documents(self):
        self.assert_parity("dumps", dumps_expected)

    def test_strerror(self):
        self.assert_parity("strerror", strerror_expected)

    def test_oserror(self):
        self.assert_parity("oserror", oserror_expected)

    def test_strerror_oserror_runtime_fuzz(self):
        env_seed = os.environ.get("ZIG_COMMON_FUZZ_SEED")
        seed = int(env_seed, 0) if env_seed else int.from_bytes(os.urandom(8), "little")
        print(f"strerror/oserror fuzz seed={hex(seed)}", file=sys.stderr, flush=True)
        rng = random.Random(seed)

        errnos = list(range(0, 201))
        for _ in range(500):
            errnos.append(rng.randrange(0, 4096))

        lines = [f"strerror\t{code}" for code in errnos]
        oserror_cases = []
        for code in errnos:
            plen = rng.randint(0, 12)
            # Restrict to ASCII and ill-formed UTF-8 bytes so paths stay
            # independent of Unicode printable tables across Python releases.
            raw = bytes(
                rng.choice(
                    (
                        rng.randrange(0, 0x80),
                        rng.randrange(0x80, 0xC0),
                        rng.randrange(0xF5, 0x100),
                    )
                )
                for _ in range(plen)
            )
            oserror_cases.append((code, raw))
            lines.append(f"oserror\t{code}\t{raw.hex()}")

        payload = ("\n".join(lines) + "\n").encode("ascii")
        out = subprocess.run(
            [probe_path(), "--errno-stdin"],
            input=payload,
            check=True,
            stdout=subprocess.PIPE,
        )
        got_lines = out.stdout.decode("ascii").splitlines()
        self.assertEqual(len(got_lines), len(lines))

        bad_str = []
        for code, got_hex in zip(errnos, got_lines[: len(errnos)]):
            want = os.strerror(code).encode("utf-8")
            got = bytes.fromhex(got_hex)
            if got != want:
                bad_str.append((code, got, want))
        self.assertEqual(
            len(bad_str),
            0,
            f"strerror fuzz (seed={hex(seed)}): {len(bad_str)} mismatches; first={bad_str[:1]}",
        )

        bad_os = []
        for (code, raw), got_hex in zip(oserror_cases, got_lines[len(errnos) :]):
            path = raw.decode("utf-8", "surrogateescape")
            exc = OSError(code, os.strerror(code), path)
            want = str(exc).encode("utf-8", "surrogateescape")
            got = bytes.fromhex(got_hex)
            if got != want:
                bad_os.append((code, raw, got, want))
        self.assertEqual(
            len(bad_os),
            0,
            f"oserror fuzz (seed={hex(seed)}): {len(bad_os)} mismatches; first={bad_os[:1]}",
        )

    def test_case_set_is_covered(self):
        for kind in KINDS:
            self.assertGreaterEqual(
                len(self.cases[kind]),
                MIN_CASES[kind],
                f"the parity probe produced too few {kind} cases",
            )


if __name__ == "__main__":
    unittest.main()
