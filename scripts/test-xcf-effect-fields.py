#!/usr/bin/env python3
"""Compile/run only the pure GLib/GIO XCF metadata decoder and specifications.

No GIMP headers, adapter objects, engine producer, engine process or GUI is
used. Run takes the preserved native foreign oracle as a read-only fixture.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "Engine/xcf-effect-fields.c", ROOT / "Engine/tests/xcf-effect-fields-tests.c"]
INPUTS = [*SOURCES, ROOT / "Engine/xcf-effect-fields.h", Path(__file__).resolve()]
DEFAULT_OUT = ROOT / ".build/xcf-effect-fields-pure"
NAME = "xcf-effect-fields-tests"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def build(args: argparse.Namespace) -> int:
    prefix = (ROOT / "_deps/macports").resolve()
    environment = os.environ.copy()
    environment.pop("PKG_CONFIG_PATH", None)
    environment.pop("PKG_CONFIG_SYSROOT_DIR", None)
    environment["PKG_CONFIG_LIBDIR"] = str(prefix / "lib/pkgconfig")
    flags = shlex.split(subprocess.check_output([str(prefix / "bin/pkg-config"), "--cflags", "--libs", "gio-2.0"],
        env=environment, text=True))
    before = {str(path): digest(path) for path in INPUTS}
    out = args.out.resolve()
    if out.is_relative_to(prefix):
        raise ValueError("pure test output must be outside the dependency prefix")
    out.mkdir(parents=True, exist_ok=True)
    binary = out / NAME
    command = ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "Engine"), *map(str, SOURCES), *flags, "-o", str(binary)]
    print("==> pure GLib/GIO compile/link only: " + shlex.join(command), flush=True)
    try:
        subprocess.run(command, check=True)
    finally:
        if any(digest(path) != before[str(path)] for path in INPUTS):
            raise ValueError("pure decoder/specification inputs changed during build")
    (out / "build.json").write_text(json.dumps({"command": command, "inputs_sha256": before,
        "binary_sha256": digest(binary)}, indent=2, sort_keys=True) + "\n")
    print(f"Built {binary}; no execution.")
    return 0


def run(args: argparse.Namespace) -> int:
    binary, fixture, work = args.binary.resolve(), args.fixture.resolve(), args.work.resolve()
    if args.timeout <= 0:
        raise ValueError("timeout must be positive")
    manifest = json.loads((binary.parent / "build.json").read_text())
    if digest(binary) != manifest["binary_sha256"]:
        raise ValueError("pure test binary changed since its build manifest")
    fixture_before = digest(fixture)
    work.mkdir(parents=True, mode=0o700, exist_ok=True)
    if any(work.iterdir()):
        raise ValueError("pure test work directory must be empty; existing files are never deleted")
    for name in ("home", "cache", "config", "data", "state", "runtime", "tmp"):
        (work / name).mkdir(mode=0o700)
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith(("DYLD_", "GLIMS_", "GIMP"))}
    environment.update(HOME=str(work / "home"), CFFIXED_USER_HOME=str(work / "home"),
        XDG_CACHE_HOME=str(work / "cache"), XDG_CONFIG_HOME=str(work / "config"), XDG_DATA_HOME=str(work / "data"),
        XDG_STATE_HOME=str(work / "state"), XDG_RUNTIME_DIR=str(work / "runtime"),
        TMPDIR=str(work / "tmp"), TMP=str(work / "tmp"), TEMP=str(work / "tmp"),
        G_DEBUG="fatal-criticals", LC_ALL="C", LANG="C")
    command = [str(binary), str(fixture), str(work)]
    print("==> pure specifications; no engine/GUI: " + shlex.join(command), flush=True)

    def interrupted(signum: int, frame: object) -> None:
        raise InterruptedError(f"interrupted by signal {signum}")

    with (work / "stdout.log").open("wb") as stdout, (work / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, env=environment, cwd=work, stdin=subprocess.DEVNULL,
            stdout=stdout, stderr=stderr, start_new_session=True)
        previous = signal.signal(signal.SIGTERM, interrupted)
        try:
            code = process.wait(timeout=args.timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt, InterruptedError):
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
            code = 124
        finally:
            signal.signal(signal.SIGTERM, previous)
    if digest(fixture) != fixture_before:
        raise ValueError("preserved native foreign oracle changed during pure specifications")
    sys.stdout.write((work / "stdout.log").read_text(errors="replace"))
    sys.stderr.write((work / "stderr.log").read_text(errors="replace"))
    (work / "run.json").write_text(json.dumps({"command": command, "exit": code, "build": manifest,
        "fixture_sha256": fixture_before}, indent=2, sort_keys=True) + "\n")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("build", help="strict pure GLib/GIO compile/link, no execution")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p = commands.add_parser("run", help="pure metadata specifications, no engine process")
    p.add_argument("--binary", type=Path, default=DEFAULT_OUT / NAME)
    p.add_argument("--fixture", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    try:
        return build(args) if args.command == "build" else run(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"test-xcf-effect-fields: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
