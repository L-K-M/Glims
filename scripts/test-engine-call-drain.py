#!/usr/bin/env python3
"""Build/run the synthetic admitted-RPC lifetime regression using immutable objects.

Build compiles the new fixture and a PRIVATE engine.c with test-only symbol
shims, excludes the producer engine.o, and links its other existing objects.
It never executes the result or rebuilds/relinks a producer library. Run uses
synthetic authoritative GIMP structs and a GLib loop; it never starts GIMP.
The initial specified compile target is GIMP_3_2_8 only.

    python3 scripts/test-engine-call-drain.py build \
        --producer /absolute/producer/GIMP_3_2_8 --out /tmp/engine-call-drain-build
    python3 scripts/test-engine-call-drain.py run \
        --binary /tmp/engine-call-drain-build/engine-call-drain-tests \
        --work /tmp/engine-call-drain-work
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
HARNESS = REPO_ROOT / "Engine/tests/engine-call-drain-tests.c"
TRANSPORT = REPO_ROOT / "Engine/engine.c"
SHIMS = REPO_ROOT / "Engine/tests/engine-call-drain-shims.h"
DEFAULT_OUT = REPO_ROOT / ".build/engine-call-drain-tests" / PINNED_REF
BINARY_NAME = "engine-call-drain-tests"
SYMBOL_SHIMS = {
    "g_cond_wait": "glims_test_call_drain_cond_wait",
    "g_mutex_clear": "glims_test_call_drain_mutex_clear",
    "g_cond_clear": "glims_test_call_drain_cond_clear",
    "g_free": "glims_test_call_drain_free",
    "g_main_context_invoke_full": "glims_test_call_drain_invoke",
    "g_source_attach": "glims_test_call_drain_attach",
}


def fail(message: str) -> None:
    raise SystemExit(f"test-engine-call-drain: {message}")


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
    if sum(path.name == "engine.o" for path in objects) != 1:
        fail("producer must contain exactly one engine.o to exclude from private test linkage")
    linked_objects = [path for path in objects if path.name != "engine.o"]
    for source in (HARNESS, TRANSPORT, SHIMS):
        if not source.is_file():
            fail(f"fixture input is missing: {source}")
    core_objects = [Path(value) for value in shlex.split(responses[1].read_text())]
    if not core_objects or any(not path.is_absolute() or not path.is_file() for path in core_objects):
        fail("objects.rsp must name existing absolute native core objects")
    inputs = sorted(set(objects + core_objects + responses + [HARNESS, TRANSPORT, SHIMS, Path(__file__).resolve(),
        REPO_ROOT / "Engine/engine-private.h", REPO_ROOT / "Sources/CGlimsEngine/include/glims_engine.h"]))
    before = {str(path): digest(path) for path in inputs}

    out = (args.out or DEFAULT_OUT).resolve()
    if out.is_relative_to(producer) or producer.is_relative_to(out):
        fail("test output must not overlap the immutable producer prefix")
    harness_object = out / (BINARY_NAME + ".o")
    transport_object = out / "engine-call-drain-private-engine.o"
    binary = out / BINARY_NAME
    for output in (harness_object, transport_object, binary, out / "build.json"):
        if output.resolve().is_relative_to(producer):
            fail(f"test output resolves into the immutable producer: {output}")
    out.mkdir(parents=True, exist_ok=True)
    common = [f"@{responses[0]}", "-I", str(REPO_ROOT / "Sources/CGlimsEngine/include"),
              "-I", str(REPO_ROOT / "Engine"), "-I", str(HARNESS.parent)]
    transport_command = [
        "xcrun", "clang", *common,
        '-DGLIMS_ENGINE_TYPELIB_PATH="unused-transport-fixture"',
        '-DGLIMS_ENGINE_BIN_PATH="unused-transport-fixture"',
        *(f"-D{name}={replacement}" for name, replacement in SYMBOL_SHIMS.items()),
        "-include", str(SHIMS), "-fvisibility=hidden", "-Wall", "-Wextra",
        "-Werror=implicit-function-declaration", "-c", str(TRANSPORT), "-o", str(transport_object),
    ]
    compile_command = [
        "xcrun", "clang", *common,
        "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-c", str(HARNESS), "-o", str(harness_object),
    ]
    link_command = [
        "xcrun", "clang++", "-o", str(binary), str(harness_object), str(transport_object),
        *(str(path) for path in linked_objects),
        f"@{responses[1]}", f"@{responses[2]}",
    ]
    try:
        print("==> compile private transport with test-only symbol shims", flush=True)
        print_command(transport_command)
        subprocess.run(transport_command, check=True, cwd=REPO_ROOT)
        print("==> compile isolated fixture without symbol shims", flush=True)
        print_command(compile_command)
        subprocess.run(compile_command, check=True, cwd=REPO_ROOT)
        print("==> link immutable objects excluding producer engine.o (not executed)", flush=True)
        print_command(link_command)
        subprocess.run(link_command, check=True, cwd=REPO_ROOT)
    finally:
        if sorted((producer / "obj").glob("*.o")) != objects or any(
                not path.is_file() or digest(path) != before[str(path)] for path in inputs):
            fail("immutable producer/source inputs changed during isolated harness build")
    (out / "build.json").write_text(json.dumps({
        "producer": str(producer), "ref": PINNED_REF,
        "commands": [transport_command, compile_command, link_command], "source_sha256": digest(HARNESS),
        "private_transport_sha256": digest(TRANSPORT), "symbol_shims": SYMBOL_SHIMS,
        "excluded_producer_object": str(producer / "obj/engine.o"),
        "runtime_scope": "synthetic GLib transport; no GIMP startup or native operations",
        "binary_sha256": digest(binary), "inputs_sha256": before,
    }, indent=2, sort_keys=True) + "\n")
    print(f"-- built {binary}; input hashes unchanged (not run)", flush=True)
    return 0


def run(args: argparse.Namespace) -> int:
    binary = (args.binary or DEFAULT_OUT / BINARY_NAME).resolve()
    if not binary.is_file():
        fail(f"harness binary is missing: {binary}; build it separately first")
    manifest = json.loads((binary.parent / "build.json").read_text())
    if manifest["ref"] != PINNED_REF:
        fail("build manifest is not the pinned engine specification")
    if digest(binary) != manifest["binary_sha256"]:
        fail("binary does not match its immutable-input build manifest")
    inputs = {Path(path): expected for path, expected in manifest["inputs_sha256"].items()}
    if any(not path.is_file() or digest(path) != expected for path, expected in inputs.items()):
        fail("immutable producer/source inputs no longer match the build manifest")
    if args.timeout <= 0:
        fail("timeout must be greater than zero")
    work = args.work.resolve()
    if work in (Path("/"), Path.home().resolve()):
        fail("work must be a throwaway directory, not the filesystem or home root")
    producer = Path(manifest["producer"]).resolve()
    if work.is_relative_to(producer) or producer.is_relative_to(work) or binary.is_relative_to(work):
        fail("run work must not overlap the immutable producer or harness binary")
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
    command = [str(binary)]
    print(f"==> run synthetic GLib transport oracle with throwaway settings in {work}", flush=True)
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
                    print("test-engine-call-drain: process did not reap after SIGKILL", file=sys.stderr)
            print("test-engine-call-drain: timed out/interrupted; private files preserved", file=sys.stderr)
            code = 124
        finally:
            signal.signal(signal.SIGTERM, previous_term)
    if digest(binary) != manifest["binary_sha256"] or any(
            not path.is_file() or digest(path) != expected for path, expected in inputs.items()):
        fail("immutable binary/producer/source inputs changed during the oracle run")
    sys.stdout.write((work / "stdout.log").read_text(errors="replace"))
    sys.stderr.write((work / "stderr.log").read_text(errors="replace"))
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="compile private transport and fixture; link immutable objects without executing")
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
        print(f"test-engine-call-drain: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
