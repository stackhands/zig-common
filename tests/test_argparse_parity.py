"""Differential parity test comparing zig-common's argparse against Python 3.14.

Generates argv vectors at runtime from a pinned seed (override with
ZIG_COMMON_ARGPARSE_FUZZ_SEED) with no committed corpus, runs both
tests/argparse_parity_probe.zig and Python's stdlib argparse.ArgumentParser,
and asserts byte-for-byte agreement on outcomes, exit codes, parsed values,
stdout, and stderr.

Also fuzzes Policy.prolog_lenient against the reference lenient Slurm
TaskProlog parser and verifies parseOrExit real subprocess exit codes.
"""
import contextlib
import io
import json
import os
import random
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROBE = os.path.join(REPO, "zig-out", "bin", "argparse_parity_probe")

os.environ["COLUMNS"] = "80"
os.environ["NO_COLOR"] = "1"

import argparse  # noqa: E402


def resolve_seed():
    raw = os.environ.get("ZIG_COMMON_ARGPARSE_FUZZ_SEED")
    if raw is not None and raw.strip():
        return int(raw.strip(), 0)
    return 1652137504


SEED = resolve_seed()
IS_PY314 = sys.version_info >= (3, 14)


def probe_path():
    path = os.environ.get("ZIG_COMMON_ARGPARSE_PROBE", DEFAULT_PROBE)
    if not os.path.exists(path):
        subprocess.run(["zig", "build", "argparse-parity-probe"], cwd=REPO, check=True)
    return path


def make_py_parser():
    kwargs = {"prog": "tool"}
    if IS_PY314:
        kwargs["color"] = False
    p = argparse.ArgumentParser(**kwargs)
    p.add_argument("--version", action="version", version="tool 1.0")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--state-root", dest="top_state_root", metavar="STATE_ROOT")
    p.add_argument("--config")
    sp = p.add_subparsers(dest="command", required=True)

    sub_kw = {"color": False} if IS_PY314 else {}

    pr = sp.add_parser("probe", **sub_kw)
    pr.add_argument("-a", "--alpha", action="store_true")
    pr.add_argument("-b", "--beta", action="store_true")
    pr.add_argument("-o", "--out")
    pr.add_argument("-f", "--float", type=float)
    pr.add_argument("--backend", choices=["auto", "squashfs", "none"])
    pr.add_argument("--tag", action="append")

    st = sp.add_parser("status", **sub_kw)
    st.add_argument("--json", action="store_true")
    st.add_argument("--state-root", dest="sub_state_root", metavar="STATE_ROOT", required=True)
    st.add_argument("target", nargs="?")

    rs = sp.add_parser("resolve", **sub_kw)
    rs.add_argument("--json", action="store_true")
    rs.add_argument("--mode", choices=["fast", "safe"])
    rs.add_argument("spec")

    rn = sp.add_parser("run", **sub_kw)
    rn.add_argument("--state-root", dest="sub_state_root", metavar="STATE_ROOT", required=True)
    rn.add_argument("--lock-timeout", type=float)
    rn.add_argument("--dry-run", action="store_true")
    rn.add_argument("--eb-keep-logs", action="store_true")
    rn.add_argument("--eb")
    rn.add_argument("eb_args", nargs=argparse.REMAINDER)

    return p


def bhex(s):
    if s is None:
        return None
    if isinstance(s, bytes):
        return s.hex()
    return s.encode("utf-8", "surrogateescape").hex()


def run_python_py314(argv_bytes):
    argv_str = [a.decode("utf-8", "surrogateescape") for a in argv_bytes]
    parser = make_py_parser()
    out_buf = io.StringIO()
    err_buf = io.StringIO()
    with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
        try:
            ns = parser.parse_args(argv_str)
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
            if code == 0:
                return {
                    "kind": "action_done",
                    "exit_code": 0,
                    "stdout": bhex(out_buf.getvalue()),
                }
            return {
                "kind": "usage_error",
                "exit_code": code,
                "stderr": bhex(err_buf.getvalue()),
            }

    res = {
        "kind": "ok",
        "command": ns.command,
        "verbose": bool(ns.verbose),
        "top_state_root": bhex(ns.top_state_root),
        "config": bhex(ns.config),
    }
    if ns.command == "probe":
        res.update(
            {
                "alpha": bool(ns.alpha),
                "beta": bool(ns.beta),
                "out": bhex(ns.out),
                "float": None if ns.float is None else "SET",
                "backend": bhex(ns.backend),
                "tag": [bhex(t) for t in (ns.tag or [])],
            }
        )
    elif ns.command == "status":
        res.update(
            {
                "json": bool(ns.json),
                "state_root": bhex(ns.sub_state_root),
                "target": bhex(ns.target),
            }
        )
    elif ns.command == "resolve":
        res.update(
            {
                "json": bool(ns.json),
                "mode": bhex(ns.mode),
                "spec": bhex(ns.spec),
            }
        )
    elif ns.command == "run":
        res.update(
            {
                "state_root": bhex(ns.sub_state_root),
                "lock_timeout": None if ns.lock_timeout is None else "SET",
                "dry_run": bool(ns.dry_run),
                "eb_keep_logs": bool(ns.eb_keep_logs),
                "eb": bhex(ns.eb),
                "eb_args": [bhex(x) for x in ns.eb_args],
            }
        )
    return res


def run_python_prolog(argv_bytes):
    """Reference lenient TaskProlog parser matching Policy.prolog_lenient."""
    shell = False
    strict = False
    help_req = False
    ver_req = False
    timeout = None
    chain = None

    i = 0
    n = len(argv_bytes)
    while i < n:
        a = argv_bytes[i]
        if a in (b"-h", b"--help"):
            help_req = True
        elif a == b"--version":
            ver_req = True
        elif a == b"--shell":
            shell = True
        elif a == b"--strict":
            strict = True
        elif a == b"--timeout":
            if i + 1 < n and not argv_bytes[i + 1].startswith(b"-"):
                i += 1
                timeout = argv_bytes[i]
            else:
                timeout = b""
        elif a.startswith(b"--timeout="):
            timeout = a[len(b"--timeout=") :]
        elif a == b"--chain":
            if i + 1 < n and not argv_bytes[i + 1].startswith(b"-"):
                i += 1
                chain = argv_bytes[i]
            else:
                chain = b""
        elif a.startswith(b"--chain="):
            chain = a[len(b"--chain=") :]
        i += 1

    return {
        "kind": "ok",
        "shell": shell,
        "strict": strict,
        "help": help_req,
        "version": ver_req,
        "timeout": bhex(timeout),
        "chain": bhex(chain),
    }


def generate_py314_cases(rng, count=1500):
    top_tokens = [
        b"-h",
        b"--help",
        b"--h",
        b"--he",
        b"--h=1",
        b"--help=",
        b"-h=1",
        b"-hh",
        b"-hh=1",
        b"-hx",
        b"--version",
        b"--ver",
        b"--v",
        b"--version=1",
        b"-v",
        b"--verbose",
        b"-vv",
        b"-vh",
        b"-vh=1",
        b"-v=1",
        b"-vx",
        b"--state-root",
        b"--st",
        b"--state-root=/tmp/r",
        b"--state-root=-1",
        b"--config",
        b"--co",
        b"--config=-a b",
        b"--",
        b"--=foo",
        b"--s=1",
        b"--bogus",
        b"-z",
        b"-1",
        b"-.5",
        b"-foo bar",
        b"badcmd",
    ]
    sub_pools = {
        b"probe": [
            b"-h",
            b"--help",
            b"-a",
            b"-b",
            b"-ab",
            b"-ba",
            b"-ao=val",
            b"-aoval",
            b"-ao",
            b"-af1.5",
            b"-afbad",
            b"-hfbad",
            b"-ab=1",
            b"-azb",
            b"-a-b",
            b"--alpha",
            b"--al",
            b"--alpha=1",
            b"--beta",
            b"--out",
            b"--out=",
            b"--out=--x",
            b"--float",
            b"-f",
            b"1.5",
            b"1_0.5",
            b" 2.5 ",
            b"inf",
            b"-5",
            b"-.5",
            b"-1e3",
            b"--float=-nan",
            b"bad",
            b"1__0",
            b"_1",
            b"1_",
            b".",
            b"0x1",
            b"--backend",
            b"--ba",
            b"auto",
            b"squashfs",
            b"none",
            b"bogus",
            b"--tag",
            b"--tag=t1",
            b"t2",
            b"--",
            b"--=x",
            b"--b",
            b"--unknown",
            b"-foo bar",
            b"--unknown=-a b",
            b"pos1",
            b"pos2",
        ],
        b"status": [
            b"-h",
            b"--help",
            b"--json",
            b"--j",
            b"--json=1",
            b"--state-root",
            b"--st",
            b"--state-root=/s",
            b"/s",
            b"-1",
            b"-.5",
            b"--",
            b"target1",
            b"extra2",
            b"--bogus",
            b"-x",
            b"--=1",
        ],
        b"resolve": [
            b"-h",
            b"--help",
            b"--json",
            b"--mode",
            b"--m",
            b"fast",
            b"safe",
            b"badmode",
            b"--",
            b"specA",
            b"specB",
            b"-1",
            b"-h",
            b"--bogus",
            b"-foo bar",
        ],
        b"run": [
            b"-h",
            b"--help",
            b"--state-root",
            b"--state-root=/s",
            b"/s",
            b"--lock-timeout",
            b"--l",
            b"2.5",
            b"bad",
            b"-1.5",
            b"--dry-run",
            b"--dry",
            b"--eb-keep-logs",
            b"--eb",
            b"--e",
            b"--eb=eb_bin",
            b"--",
            b"a.eb",
            b"b.eb",
            b"--robot",
            b"--bogus",
            b"-x",
        ],
    }

    cases = []
    sub_names = list(sub_pools.keys())
    valid_top = [
        [b"-v"],
        [b"--verbose"],
        [b"--state-root", b"/top"],
        [b"--st=/top"],
        [b"--config", b"-1"],
        [b"--co=-a b"],
        [],
    ]
    valid_sub = {
        b"probe": [
            b"-a",
            b"-b",
            b"-ab",
            b"-ao=val",
            b"-aoval",
            b"-af1.5",
            b"-f",
            b"-1.5",
            b"--float",
            b"1_0.5",
            b"--float= 2.5 ",
            b"--float=-nan",
            b"--float=+inf",
            b"--backend",
            b"auto",
            b"--ba=squashfs",
            b"--tag",
            b"t1",
            b"--tag=t2",
            b"--out",
            b"-.5",
            b"--out=--x",
        ],
        b"status": [
            b"--json",
            b"--j",
            b"--state-root",
            b"/s",
            b"--st=/s2",
        ],
        b"resolve": [
            b"--json",
            b"--mode",
            b"fast",
            b"--m=safe",
        ],
        b"run": [
            b"--state-root",
            b"/s",
            b"--lock-timeout",
            b"2.5",
            b"--lock-timeout=-1.5",
            b"--dry-run",
            b"--eb-keep-logs",
            b"--eb",
            b"eb_bin",
            b"--eb=eb2",
        ],
    }

    for idx in range(count):
        argv = []
        if idx % 3 == 0:
            # Structured valid or near-valid invocation to exercise deep .ok paths,
            # option interactions, short clusters, -- separators, and REMAINDER.
            argv.extend(rng.choice(valid_top))
            if rng.random() < 0.15:
                argv.append(b"--")
            sub = rng.choice(sub_names)
            argv.append(sub)
            if sub in (b"status", b"run"):
                argv.extend([b"--state-root", b"/sr"])
            for _ in range(rng.randrange(0, 4)):
                tok = rng.choice(valid_sub[sub])
                argv.append(tok)
                if tok in (b"-f", b"--float", b"--lock-timeout"):
                    argv.append(rng.choice([b"1.5", b"1_0.5", b"-5", b"-.5", b"inf"]))
                elif tok == b"--backend":
                    argv.append(rng.choice([b"auto", b"squashfs", b"none"]))
                elif tok == b"--mode":
                    argv.append(rng.choice([b"fast", b"safe"]))
                elif tok in (b"--tag", b"--out", b"--eb", b"--state-root"):
                    argv.append(rng.choice([b"v1", b"-1", b"-.5", b"-foo bar"]))
            if sub == b"resolve":
                if rng.random() < 0.35:
                    argv.append(b"--")
                    argv.append(rng.choice([b"specA", b"-h", b"--", b"--bogus"]))
                else:
                    argv.append(rng.choice([b"specA", b"-1", b"-.5", b"-foo bar"]))
            elif sub == b"status" and rng.random() < 0.6:
                if rng.random() < 0.35:
                    argv.append(b"--")
                    argv.append(rng.choice([b"t1", b"--", b"-h"]))
                else:
                    argv.append(rng.choice([b"t1", b"-1", b"-.5"]))
            elif sub == b"run" and rng.random() < 0.7:
                if rng.random() < 0.4:
                    argv.append(b"--")
                argv.extend(rng.choices([b"a.eb", b"--robot", b"-h", b"--", b"-1"], k=rng.randrange(1, 4)))
            # Occasionally perturb one token to test subtle boundary errors
            if rng.random() < 0.25:
                argv.append(rng.choice(sub_pools[sub]))
            cases.append(argv)
            continue

        # 0..3 top-level tokens
        for _ in range(rng.randrange(0, 4)):
            argv.append(rng.choice(top_tokens))
        # 85% include a subcommand
        if rng.random() < 0.85:
            if rng.random() < 0.12:
                argv.append(b"--")
            sub = rng.choice(sub_names)
            argv.append(sub)
            pool = sub_pools[sub]
            for _ in range(rng.randrange(0, 7)):
                argv.append(rng.choice(pool))
        # Occasionally inject synthetic random ASCII/special tokens
        if idx % 17 == 0:
            weird = rng.choice(
                [
                    b"",
                    b"-",
                    b"--",
                    b"'quoted'",
                    b'"dq"',
                    b"a'b\"c",
                    b"line1\nline2",
                    b"\t\x0b\x0c",
                    b"-99",
                    b"-.a",
                    b"--1",
                ]
            )
            pos = rng.randrange(0, len(argv) + 1)
            argv.insert(pos, weird)
        cases.append(argv)
    return cases


def generate_prolog_cases(rng, count=500):
    tokens = [
        b"-h",
        b"--help",
        b"--help=1",
        b"-h=1",
        b"-hh",
        b"--version",
        b"--version=bad",
        b"--shell",
        b"--sh",
        b"--shell=1",
        b"--strict",
        b"--timeout",
        b"--timeout=",
        b"--timeout=-5",
        b"--timeout=3.5",
        b"--chain",
        b"--chain=/etc/prolog",
        b"--chain=",
        b"--",
        b"-",
        b"-5",
        b"-.5",
        b"10",
        b"/path/to/file",
        b"--=",
        b"--=foo",
        b"--bogus",
        b"-x",
        b"",
        b"\xff\xfe",
        b"val\xff",
    ]
    cases = []
    for _ in range(count):
        n = rng.randrange(0, 10)
        cases.append([rng.choice(tokens) for _ in range(n)])
    return cases


def run_python_intermixed(argv_bytes):
    argv_str = [a.decode("utf-8", "surrogateescape") for a in argv_bytes]
    kwargs = {"prog": "imix"}
    if IS_PY314:
        kwargs["color"] = False
    p = argparse.ArgumentParser(**kwargs)
    p.add_argument("--json", action="store_true")
    p.add_argument("--prefix")
    p.add_argument("first")
    p.add_argument("files", nargs="+")

    out_buf = io.StringIO()
    err_buf = io.StringIO()
    with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
        try:
            ns = p.parse_intermixed_args(argv_str)
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
            if code == 0:
                return {"kind": "action_done", "exit_code": 0, "stdout": bhex(out_buf.getvalue())}
            return {"kind": "usage_error", "exit_code": code, "stderr": bhex(err_buf.getvalue())}

    return {
        "kind": "ok",
        "json": bool(ns.json),
        "prefix": bhex(ns.prefix),
        "first": bhex(ns.first),
        "files": [bhex(x) for x in ns.files],
    }


def generate_intermixed_cases(rng, count=400):
    tokens = [
        b"-h",
        b"--help",
        b"--json",
        b"--json=1",
        b"--prefix",
        b"--prefix=/opt",
        b"--prefix=",
        b"--",
        b"--bogus",
        b"-1",
        b"f1",
        b"f2",
        b"f3",
    ]
    cases = [
        [],
        [b"a"],
        [b"a", b"b"],
        [b"a", b"--json", b"b", b"--prefix", b"/p", b"c"],
        [b"a", b"--json", b"--", b"--bogus", b"-h"],
        [b"--json", b"--", b"a", b"b"],
        [b"a", b"b", b"--json", b"--"],
    ]
    while len(cases) < count:
        n = rng.randrange(0, 8)
        cases.append([rng.choice(tokens) for _ in range(n)])
    return cases


def run_python_native(argv_bytes):
    """Reference parser matching Policy.native_exact, UnknownMode.positional, prescan, ignore_empty, mutex, and ErrorKind."""
    sub_idx = None
    for i, a in enumerate(argv_bytes):
        if a in (b"-h", b"--help"):
            return {"kind": "action_done", "exit_code": 0, "stdout": bhex(b"native help\n")}
        if a == b"--version":
            return {"kind": "action_done", "exit_code": 0, "stdout": bhex(b"native 1.0\n")}
        if a.startswith(b"-"):
            return {"kind": "usage_error", "exit_code": 2, "err_kind": "unknown_option", "token": bhex(a)}
        sub_idx = i
        break

    if sub_idx is None:
        return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_subcommand"}

    cmd = argv_bytes[sub_idx]
    rest = argv_bytes[sub_idx + 1 :]
    if cmd not in (b"rotate", b"failed", b"used", b"prescan", b"mutex"):
        return {"kind": "usage_error", "exit_code": 2, "err_kind": "unknown_subcommand", "token": bhex(cmd)}

    def parse_val(args, idx, name, allow_empty=True, allow_dash=True):
        a = args[idx]
        prefix = b"--" + name + b"="
        if a.startswith(prefix):
            val = a[len(prefix) :]
        else:
            if idx + 1 >= len(args):
                return None, idx, {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_value", "token": bhex(name)}
            idx += 1
            val = args[idx]
        if (not allow_empty and len(val) == 0) or (not allow_dash and val.startswith(b"-")):
            return None, idx, {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_value", "token": bhex(name)}
        return val, idx, None

    if cmd == b"rotate":
        dry_run = False
        compress_after = None
        target = None
        module = None
        pos = []
        i = 0
        while i < len(rest):
            a = rest[i]
            if a == b"--dry-run":
                dry_run = True
            elif a == b"--compress-after" or a.startswith(b"--compress-after="):
                val, i, err = parse_val(rest, i, b"compress-after", True, True)
                if err:
                    return err
                compress_after = val
            elif a == b"--target" or a.startswith(b"--target="):
                val, i, err = parse_val(rest, i, b"target", False, True)
                if err:
                    return err
                target = val
            elif a == b"--module" or a.startswith(b"--module="):
                val, i, err = parse_val(rest, i, b"module", False, False)
                if err:
                    return err
                module = val
            elif a.startswith(b"-"):
                return {"kind": "usage_error", "exit_code": 2, "err_kind": "unknown_option", "token": bhex(a)}
            else:
                if len(pos) >= 1:
                    return {"kind": "usage_error", "exit_code": 2, "err_kind": "extra_positional", "token": bhex(a)}
                pos.append(a)
            i += 1
        if len(pos) < 1:
            return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_required", "token": bhex(b"ROOT")}
        return {
            "kind": "ok",
            "command": "rotate",
            "dry_run": dry_run,
            "compress_after": bhex(compress_after),
            "target": bhex(target),
            "module": bhex(module),
            "root": bhex(pos[0]),
        }

    if cmd == b"failed":
        syslog = None
        pos = []
        i = 0
        while i < len(rest):
            a = rest[i]
            if a == b"--syslog" or a.startswith(b"--syslog="):
                val, i, err = parse_val(rest, i, b"syslog", True, True)
                if err:
                    return err
                syslog = val
            else:
                if len(pos) >= 4:
                    return {"kind": "usage_error", "exit_code": 2, "err_kind": "extra_positional", "token": bhex(a)}
                pos.append(a)
            i += 1
        req_names = [b"STATUS", b"NAME", b"LOGDIR"]
        if len(pos) < 3:
            return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_required", "token": bhex(req_names[len(pos)])}
        return {"kind": "ok", "command": "failed", "syslog": bhex(syslog), "pos": [bhex(x) for x in pos]}

    if cmd == b"prescan":
        for a in rest:
            if a in (b"-h", b"--help"):
                return {"kind": "action_done", "exit_code": 0, "stdout": bhex(b"prescan help\n")}
            if a == b"--version":
                return {"kind": "action_done", "exit_code": 0, "stdout": bhex(b"prescan 1.0\n")}
        fmt = None
        pos = []
        i = 0
        while i < len(rest):
            a = rest[i]
            if a == b"--format" or a.startswith(b"--format="):
                val, i, err = parse_val(rest, i, b"format", False, True)
                if err:
                    return err
                fmt = val
            elif a.startswith(b"-"):
                return {"kind": "usage_error", "exit_code": 2, "err_kind": "unknown_option", "token": bhex(a)}
            else:
                if len(a) == 0 and len(pos) == 0:
                    i += 1
                    continue
                if len(pos) >= 1:
                    return {"kind": "usage_error", "exit_code": 2, "err_kind": "extra_positional", "token": bhex(a)}
                pos.append(a)
            i += 1
        if len(pos) < 1:
            return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_required", "token": bhex(b"RUN")}
        return {"kind": "ok", "command": "prescan", "format": bhex(fmt), "run": bhex(pos[0])}

    if cmd == b"mutex":
        unused = False
        active = False
        json_flag = False
        pos = []
        for a in rest:
            if a == b"--unused":
                if active:
                    return {"kind": "usage_error", "exit_code": 2, "err_kind": "mutually_exclusive", "option": bhex(b"unused"), "conflict": bhex(b"active")}
                unused = True
            elif a == b"--active":
                if unused:
                    return {"kind": "usage_error", "exit_code": 2, "err_kind": "mutually_exclusive", "option": bhex(b"active"), "conflict": bhex(b"unused")}
                active = True
            elif a == b"--json":
                json_flag = True
            elif a.startswith(b"-"):
                return {"kind": "usage_error", "exit_code": 2, "err_kind": "unknown_option", "token": bhex(a)}
            else:
                pos.append(a)
        if len(pos) < 1:
            return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_required", "token": bhex(b"FILE")}
        return {"kind": "ok", "command": "mutex", "unused": unused, "active": active, "json": json_flag, "files": [bhex(x) for x in pos]}

    # cmd == b"used"
    json_flag = False
    prefix = None
    pos = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == b"--json":
            json_flag = True
        elif a == b"--prefix" or a.startswith(b"--prefix="):
            val, i, err = parse_val(rest, i, b"prefix", False, False)
            if err:
                return err
            prefix = val
        elif a.startswith(b"-"):
            return {"kind": "usage_error", "exit_code": 2, "err_kind": "unknown_option", "token": bhex(a)}
        else:
            pos.append(a)
        i += 1
    if prefix is None:
        return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_required", "token": bhex(b"prefix")}
    if len(pos) < 1:
        return {"kind": "usage_error", "exit_code": 2, "err_kind": "missing_required", "token": bhex(b"FILE")}
    return {"kind": "ok", "command": "used", "json": json_flag, "prefix": bhex(prefix), "files": [bhex(x) for x in pos]}


def generate_native_cases(rng, count=600):
    top_toks = [b"-h", b"--help", b"--help=1", b"--version", b"--version=1", b"--bogus", b"nope"]
    sub_pools = {
        b"rotate": [
            b"--dry-run",
            b"--dry-run=1",
            b"--compress-after",
            b"--compress-after=",
            b"--compress-after=-5",
            b"--target",
            b"--target=",
            b"--target=-x",
            b"--module",
            b"--module=",
            b"--module=-x",
            b"--module=GCC",
            b"--bogus",
            b"-1",
            b"",
            b"logs",
            b"extra",
        ],
        b"failed": [
            b"--syslog",
            b"--syslog=",
            b"--syslog=-x",
            b"--bogus",
            b"-1",
            b"1",
            b"Foo",
            b"logdir",
            b"tmpdir",
            b"extra",
        ],
        b"used": [
            b"--json",
            b"--json=1",
            b"--prefix",
            b"--prefix=",
            b"--prefix=-x",
            b"--prefix=/opt",
            b"--bogus",
            b"a.json",
            b"b.json",
            b"c.json",
        ],
        b"prescan": [
            b"-h",
            b"--help",
            b"--help=1",
            b"--version",
            b"--version=1",
            b"--format",
            b"--format=",
            b"--format=json",
            b"--bogus",
            b"",
            b"run1",
            b"run2",
        ],
        b"mutex": [
            b"--unused",
            b"--unused=1",
            b"--active",
            b"--active=1",
            b"--json",
            b"--bogus",
            b"a.log",
            b"b.log",
        ],
    }
    cases = [
        [],
        [b"--bogus"],
        [b"--help"],
        [b"--help=1"],
        [b"--version"],
        [b"--version=1"],
        [b"nope"],
        [b"rotate", b"--bogus"],
        [b"rotate", b"--bogus", b"--target"],
        [b"rotate", b"--dry-run=1", b"logs"],
        [b"rotate", b"--compress-after", b"-5", b"logs"],
        [b"rotate", b"--target=", b"logs"],
        [b"rotate", b"--module=-x", b"logs"],
        [b"failed", b"-1", b"Foo", b"--bogus"],
        [b"failed", b"1", b"Foo", b"dir", b"tmp", b"extra"],
        [b"used", b"a.json", b"--prefix", b"/opt", b"--json", b"b.json"],
        [b"prescan", b"--bogus", b"-h"],
        [b"prescan", b"--format", b"--help"],
        [b"prescan", b"--bogus", b"--version"],
        [b"prescan", b"", b"run1"],
        [b"prescan", b"run1", b""],
        [b"prescan", b""],
        [b"mutex", b"--unused", b"--active", b"--bogus"],
        [b"mutex", b"--bogus", b"--unused", b"--active"],
        [b"mutex", b"--active", b"--unused", b"a.log"],
        [b"mutex", b"--unused", b"--json", b"a.log"],
    ]
    subs = [b"rotate", b"failed", b"used", b"prescan", b"mutex"]
    while len(cases) < count:
        if rng.random() < 0.15:
            cases.append([rng.choice(top_toks) for _ in range(rng.randrange(0, 3))])
            continue
        argv = []
        if rng.random() < 0.1:
            argv.append(rng.choice([b"--bogus", b"--help=1"]))
        sub = rng.choice(subs)
        argv.append(sub)
        pool = sub_pools[sub]
        for _ in range(rng.randrange(0, 7)):
            argv.append(rng.choice(pool))
        cases.append(argv)
    return cases


def run_probe_batch(mode, cases):
    lines = []
    for argv in cases:
        toks = " ".join(a.hex() for a in argv)
        lines.append(f"{mode}\t{len(argv)}\t{toks}\n")
    payload = "".join(lines).encode("ascii")
    proc = subprocess.run(
        [probe_path()],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    out_lines = proc.stdout.decode("ascii").splitlines()
    assert len(out_lines) == len(cases), f"expected {len(cases)} lines, got {len(out_lines)}"
    return [json.loads(line) for line in out_lines]


class ArgparseParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        print(f"argparse differential fuzz seed={SEED} python={sys.version.split()[0]}", flush=True)
        cls.rng = random.Random(SEED)

    @unittest.skipUnless(IS_PY314, "Policy.python314 differential parity requires Python 3.14+")
    def test_py314_differential_fuzz(self):
        cases = generate_py314_cases(self.rng, count=300)
        zig_results = run_probe_batch("py314", cases)

        mismatches = []
        counts = {"ok": 0, "action_done": 0, "usage_error": 0}
        for argv, zig_res in zip(cases, zig_results):
            py_res = run_python_py314(argv)
            counts[py_res["kind"]] = counts.get(py_res["kind"], 0) + 1

            # Normalize float fields: Python converts to float while Zig stores
            # the validated raw slice; both must agree on presence (and validity
            # is already verified by kind == ok vs usage_error).
            zig_cmp = dict(zig_res)
            if zig_cmp.get("kind") == "ok":
                if "float" in zig_cmp and zig_cmp["float"] is not None:
                    raw = bytes.fromhex(zig_cmp["float"]).decode("utf-8", "surrogateescape")
                    float(raw)  # must parse cleanly as Python float
                    zig_cmp["float"] = "SET"
                if "lock_timeout" in zig_cmp and zig_cmp["lock_timeout"] is not None:
                    raw = bytes.fromhex(zig_cmp["lock_timeout"]).decode("utf-8", "surrogateescape")
                    float(raw)
                    zig_cmp["lock_timeout"] = "SET"

            if zig_cmp != py_res:
                mismatches.append((argv, py_res, zig_cmp))
                if len(mismatches) >= 10:
                    break

        if mismatches:
            lines = [f"seed={SEED}: {len(mismatches)} mismatch(es):"]
            for argv, py_res, zig_res in mismatches[:5]:
                py_s = dict(py_res)
                zig_s = dict(zig_res)
                for d in (py_s, zig_s):
                    for k in ("stdout", "stderr"):
                        if k in d and d[k] is not None:
                            d[k] = bytes.fromhex(d[k]).decode("utf-8", "replace")
                lines.append(f"  argv={argv!r}\n    py ={py_s!r}\n    zig={zig_s!r}")
            self.fail("\n".join(lines))

        self.assertGreater(counts["ok"], 10)
        self.assertGreater(counts["action_done"], 10)
        self.assertGreater(counts["usage_error"], 40)

    def test_prolog_lenient_differential_fuzz(self):
        cases = generate_prolog_cases(self.rng, count=500)
        zig_results = run_probe_batch("prolog", cases)

        mismatches = []
        for argv, zig_res in zip(cases, zig_results):
            # Invariant: prolog_lenient must never return usage_error.
            self.assertEqual(zig_res["kind"], "ok", f"seed={SEED} argv={argv!r} returned {zig_res!r}")
            py_res = run_python_prolog(argv)
            if zig_res != py_res:
                mismatches.append((argv, py_res, zig_res))
                if len(mismatches) >= 10:
                    break
        if mismatches:
            self.fail(f"seed={SEED}: prolog mismatches: {mismatches[:5]!r}")

    @unittest.skipUnless(IS_PY314, "parse_intermixed_args differential parity requires Python 3.14+")
    def test_intermixed_variadic_differential_fuzz(self):
        cases = generate_intermixed_cases(self.rng, count=400)
        zig_results = run_probe_batch("intermixed", cases)

        mismatches = []
        counts = {"ok": 0, "action_done": 0, "usage_error": 0}
        for argv, zig_res in zip(cases, zig_results):
            py_res = run_python_intermixed(argv)
            counts[py_res["kind"]] = counts.get(py_res["kind"], 0) + 1
            if zig_res != py_res:
                mismatches.append((argv, py_res, zig_res))
                if len(mismatches) >= 10:
                    break
        if mismatches:
            lines = [f"seed={SEED}: intermixed mismatches:"]
            for argv, py_res, zig_res in mismatches[:5]:
                py_s = dict(py_res)
                zig_s = dict(zig_res)
                for d in (py_s, zig_s):
                    for k in ("stdout", "stderr"):
                        if k in d and d[k] is not None:
                            d[k] = bytes.fromhex(d[k]).decode("utf-8", "replace")
                lines.append(f"  argv={argv!r}\n    py ={py_s!r}\n    zig={zig_s!r}")
            self.fail("\n".join(lines))

        self.assertGreater(counts["ok"], 20)
        self.assertGreater(counts["action_done"], 20)
        self.assertGreater(counts["usage_error"], 50)

    def test_native_exact_differential_fuzz(self):
        cases = generate_native_cases(self.rng, count=500)
        zig_results = run_probe_batch("native", cases)

        mismatches = []
        counts = {"ok": 0, "action_done": 0, "usage_error": 0}
        for argv, zig_res in zip(cases, zig_results):
            py_res = run_python_native(argv)
            counts[py_res["kind"]] = counts.get(py_res["kind"], 0) + 1
            if zig_res != py_res:
                mismatches.append((argv, py_res, zig_res))
                if len(mismatches) >= 10:
                    break
        if mismatches:
            self.fail(f"seed={SEED}: native_exact mismatches: {mismatches[:5]!r}")

        self.assertGreater(counts["ok"], 20)
        self.assertGreater(counts["action_done"], 10)
        self.assertGreater(counts["usage_error"], 100)

    @unittest.skipUnless(IS_PY314, "Policy.python314 subprocess parity requires Python 3.14+")
    def test_parse_or_exit_subprocess_codes_and_streams(self):
        probe = probe_path()
        samples = [
            ["-h"],
            ["--version"],
            ["probe", "-h"],
            ["probe", "--float", "bad"],
            ["--=foo"],
            ["status", "--state-root", "/tmp/sr", "t1"],
            ["run", "--state-root", "/tmp/sr", "--", "-h", "a.eb"],
        ]
        for argv in samples:
            py_res = run_python_py314([a.encode("utf-8") for a in argv])
            proc = subprocess.run(
                [probe, "--exec", *argv],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if py_res["kind"] == "action_done":
                self.assertEqual(proc.returncode, 0, f"argv={argv!r}")
                self.assertEqual(proc.stderr, b"", f"argv={argv!r}")
                if IS_PY314:
                    self.assertEqual(proc.stdout.hex(), py_res["stdout"], f"argv={argv!r}")
            elif py_res["kind"] == "usage_error":
                self.assertEqual(proc.returncode, 2, f"argv={argv!r}")
                self.assertEqual(proc.stdout, b"", f"argv={argv!r}")
                self.assertEqual(proc.stderr.hex(), py_res["stderr"], f"argv={argv!r}")
            else:
                self.assertEqual(proc.returncode, 0, f"argv={argv!r}")
                self.assertEqual(proc.stderr, b"", f"argv={argv!r}")
                got = json.loads(proc.stdout.decode("ascii"))
                self.assertEqual(got, py_res, f"argv={argv!r}")


if __name__ == "__main__":
    unittest.main()
