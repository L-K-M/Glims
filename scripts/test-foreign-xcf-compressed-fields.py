#!/usr/bin/env python3
"""Build/run the pinned bzip2/xz compressed foreign-XCF field oracle.

Source-only driver for Engine/tests/foreign-xcf-compressed-fields-tests.c,
which reuses the independently validated patched plain-XCF fixture from
Engine/tests/foreign-xcf-effect-fields-tests.c by including it with its main
renamed. The build compiles ONLY the new harness and links existing immutable
producer objects; -lbz2/-llzma are fixture-only link additions, and no
production link or dependency changes. The result is never executed by
build. Only GIMP_3_2_8 has a specified oracle; other engine sets are rejected.

    python3 scripts/test-foreign-xcf-compressed-fields.py build \
        --producer /absolute/producer/GIMP_3_2_8 --out /tmp/compressed-build
    python3 scripts/test-foreign-xcf-compressed-fields.py run \
        --binary /tmp/compressed-build/foreign-xcf-compressed-fields-tests \
        --work /tmp/compressed-work
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

REPO_ROOT = Path(__file__).resolve().parent.parent
PINNED_REF = "GIMP_3_2_8"
HARNESS = REPO_ROOT / "Engine/tests/foreign-xcf-compressed-fields-tests.c"
FIXTURE = REPO_ROOT / "Engine/tests/foreign-xcf-effect-fields-tests.c"
DEFAULT_OUT = REPO_ROOT / ".build/foreign-xcf-compressed-fields-tests" / PINNED_REF
BINARY_NAME = "foreign-xcf-compressed-fields-tests"
# Fixture-only additions to the test link command; production links untouched.
FIXTURE_LINK_FLAGS = [str((REPO_ROOT / "_deps/macports/lib" / name).resolve())
                      for name in ("libbz2.dylib", "liblzma.dylib")]


def fail(message: str) -> None:
    raise SystemExit(f"test-foreign-xcf-compressed-fields: {message}")


def default_producer() -> Path:
    selected = os.environ.get("GLIMS_ADAPTER_ROOT")
    base = Path(selected) if selected else REPO_ROOT / "_engine/adapter"
    return base / PINNED_REF


def print_command(command: list[str]) -> None:
    print("    " + shlex.join(command), flush=True)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def build(args: argparse.Namespace) -> int:
    producer = (args.producer or default_producer()).resolve()
    if not producer.is_dir():
        fail(f"producer prefix is not a directory: {producer}")
    responses = [producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")]
    for response in responses:
        if not response.is_file():
            fail(f"immutable producer is missing {response.name}: {producer}")
    objects = sorted((producer / "obj").glob("*.o"))
    if not objects or any(not path.is_file() for path in objects):
        fail(f"immutable producer has no complete obj/*.o set: {producer}")
    if not HARNESS.is_file():
        fail(f"test harness is missing: {HARNESS}")
    if not FIXTURE.is_file():
        fail(f"included fixture harness is missing: {FIXTURE}")
    core_objects = [Path(value) for value in shlex.split(responses[1].read_text())]
    if not core_objects or any(not path.is_absolute() or not path.is_file() for path in core_objects):
        fail("objects.rsp must name existing absolute native core objects")
    inputs = sorted(set(objects + core_objects + responses + [HARNESS, FIXTURE, Path(__file__).resolve(),
        REPO_ROOT / "Engine/engine-private.h", REPO_ROOT / "Sources/CGlimsEngine/include/glims_engine.h"]))
    before = {str(path): digest(path) for path in inputs}

    out = (args.out or DEFAULT_OUT).resolve()
    if out.is_relative_to(producer) or producer.is_relative_to(out):
        fail("test output must not overlap the immutable producer prefix")
    harness_object = out / (BINARY_NAME + ".o")
    binary = out / BINARY_NAME
    for output in (harness_object, binary, out / "build.json"):
        if output.resolve().is_relative_to(producer):
            fail(f"test output resolves into the immutable producer: {output}")
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        fail("test output must be new or empty; existing evidence is never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    compile_command = [
        "xcrun", "clang", f"@{responses[0]}",
        "-I", str(REPO_ROOT / "Sources/CGlimsEngine/include"),
        "-I", str(REPO_ROOT / "Engine"),
        "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-c", str(HARNESS), "-o", str(harness_object),
    ]
    link_command = [
        "xcrun", "clang++", "-o", str(binary), str(harness_object),
        *(str(path) for path in objects),
        f"@{responses[1]}", f"@{responses[2]}", *FIXTURE_LINK_FLAGS,
    ]
    try:
        print("==> compile test harness only", flush=True)
        print_command(compile_command)
        subprocess.run(compile_command, check=True, cwd=REPO_ROOT)
        print("==> link existing producer objects (compile-only; not executed)", flush=True)
        print_command(link_command)
        subprocess.run(link_command, check=True, cwd=REPO_ROOT)
    finally:
        if sorted((producer / "obj").glob("*.o")) != objects or any(
                not path.is_file() or digest(path) != before[str(path)] for path in inputs):
            fail("immutable producer/source inputs changed during isolated harness build")
    (out / "build.json").write_text(json.dumps({
        "producer": str(producer), "ref": PINNED_REF,
        "commands": [compile_command, link_command], "fixture_link_flags": FIXTURE_LINK_FLAGS,
        "source_sha256": digest(HARNESS), "fixture_sha256": digest(FIXTURE),
        "binary_sha256": digest(binary), "inputs_sha256": before,
    }, indent=2, sort_keys=True) + "\n")
    print(f"-- built {binary}; input hashes unchanged (not run)", flush=True)
    return 0


def run(args: argparse.Namespace) -> int:
    binary = (args.binary or DEFAULT_OUT / BINARY_NAME).resolve()
    if not binary.is_file():
        fail(f"harness binary is missing: {binary}; build it separately first")
    manifest = json.loads((binary.parent / "build.json").read_text())
    if digest(binary) != manifest["binary_sha256"]:
        fail("binary does not match its immutable-input build manifest")
    if args.timeout <= 0:
        fail("timeout must be greater than zero")
    work = args.work.resolve()
    if work in (Path("/"), Path.home().resolve()):
        fail("work must be a throwaway directory, not the filesystem or home root")
    work.mkdir(parents=True, mode=0o700, exist_ok=True)
    if any(work.iterdir()):
        fail("run work directory must be empty; existing contents are never deleted")
    for name in ("home", "cache", "config", "data", "state", "runtime", "user", "tmp"):
        (work / name).mkdir(mode=0o700)
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith(("DYLD_", "GLIMS_"))}
    environment.update(HOME=str(work / "home"), CFFIXED_USER_HOME=str(work / "home"),
        XDG_CACHE_HOME=str(work / "cache"), XDG_CONFIG_HOME=str(work / "config"),
        XDG_DATA_HOME=str(work / "data"), XDG_STATE_HOME=str(work / "state"),
        XDG_RUNTIME_DIR=str(work / "runtime"), GIMP3_DIRECTORY=str(work / "user"),
        TMPDIR=str(work / "tmp"), TMP=str(work / "tmp"), TEMP=str(work / "tmp"),
        G_DEBUG="fatal-criticals", LC_ALL="C", LANG="C", PYTHONDONTWRITEBYTECODE="1")
    command = [str(binary), str(work)]
    print(f"==> run pinned native oracle with throwaway settings in {work}", flush=True)
    print_command(command)
    def interrupted(signum: int, frame: object) -> None:
        raise InterruptedError(f"interrupted by signal {signum}")

    with (work / "stdout.log").open("wb") as stdout, (work / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, env=environment, cwd=work, stdin=subprocess.DEVNULL,
            stdout=stdout, stderr=stderr, start_new_session=True)
        previous_term = signal.signal(signal.SIGTERM, interrupted)
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
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    print("test-foreign-xcf-compressed-fields: process did not reap after SIGKILL", file=sys.stderr)
            print("test-foreign-xcf-compressed-fields: timed out/interrupted; private files preserved", file=sys.stderr)
            code = 124
        finally:
            signal.signal(signal.SIGTERM, previous_term)
    sys.stdout.write((work / "stdout.log").read_text(errors="replace"))
    sys.stderr.write((work / "stderr.log").read_text(errors="replace"))
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="compile/link only the harness; never execute it")
    build_parser.add_argument("--ref", choices=(PINNED_REF,), default=PINNED_REF)
    build_parser.add_argument("--producer", type=Path, help="existing immutable prefix with obj/ and response files")
    build_parser.add_argument("--out", type=Path, help=f"isolated output directory (default: {DEFAULT_OUT})")
    run_parser = commands.add_parser("run", help="run a previously built harness with throwaway settings")
    run_parser.add_argument("--ref", choices=(PINNED_REF,), default=PINNED_REF)
    run_parser.add_argument("--binary", type=Path, help=f"existing binary (default: {DEFAULT_OUT / BINARY_NAME})")
    run_parser.add_argument("--work", required=True, type=Path, help="throwaway directory for home/cache/GIMP settings and oracle XCFs")
    run_parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    try:
        return build(args) if args.command == "build" else run(args)
    except subprocess.CalledProcessError as error:
        return error.returncode
    except (OSError, ValueError, KeyError) as error:
        print(f"test-foreign-xcf-compressed-fields: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
