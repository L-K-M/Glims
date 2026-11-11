#!/usr/bin/env python3
"""Build or run the Lens Blur slot147 native oracle against an existing producer.

Source-only helper; this task does not execute the harness.
Build compiles test-local copies of filter-input.c and filter.c, excludes their
producer objects, and links the remaining immutable producer inputs without
relinking/rebuilding the producer. Run uses private HOME/XDG/GIMP/tmp settings
and a bounded process-group timeout. Hashes of immutable inputs are recorded
before/after build.
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
import time

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/lens-blur-source-tests.c"
FIXTURE = ROOT / "Engine/tests/filter-input-tests.c"
READER = ROOT / "Engine/filter-input.c"
FILTER_C = ROOT / "Engine/filter.c"
BINARY_NAME = "lens-blur-source-tests"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(msg)


def response_tokens(path: Path, inputs: set[Path], stack: set[Path]) -> list[str]:
    path = path.resolve()
    require(path not in stack, f"cyclic producer response input: {path}")
    require(path.is_file(), f"missing response input: {path}")
    inputs.add(path)
    stack = stack | {path}
    tokens = shlex.split(path.read_text())
    normalized: list[str] = []
    directory_flags = {"-I", "-L", "-F", "-isystem", "-iquote", "-isysroot"}
    file_flags = {"-include", "-imacros"}
    argument_flag: str | None = None

    def absolute(value: str, record: bool) -> str:
        candidate = Path(value)
        candidate = (candidate if candidate.is_absolute() else path.parent / candidate).resolve()
        if record:
            require(candidate.is_file(), f"missing producer file input: {candidate}")
            inputs.add(candidate)
        return str(candidate)

    for token in tokens:
        if argument_flag:
            normalized.append(absolute(token, record=argument_flag in file_flags))
            argument_flag = None
        elif token.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            normalized.append(token)
        elif token.startswith("@"):
            nested = Path(token[1:])
            nested = nested if nested.is_absolute() else path.parent / nested
            normalized.extend(response_tokens(nested, inputs, stack))
        elif token in directory_flags | file_flags:
            normalized.append(token)
            argument_flag = token
        elif token.startswith(("-I", "-L", "-F")) and len(token) > 2:
            normalized.append(token[:2] + absolute(token[2:], record=False))
        elif token.startswith("-Wl,"):
            parts = token.split(",")
            for i, part in enumerate(parts[1:], 1):
                if Path(part).suffix in {".o", ".a", ".dylib"} and not part.startswith("@"):
                    parts[i] = absolute(part, record=True)
            normalized.append(",".join(parts))
        elif not token.startswith("-") and Path(token).suffix in {".o", ".a", ".dylib"}:
            normalized.append(absolute(token, record=True))
        else:
            normalized.append(token)
    require(argument_flag is None, f"missing path argument in response {path}")
    return normalized


def producer_for_ref(ref: str) -> Path:
    env_root = os.environ.get("GLIMS_ADAPTER_ROOT")
    base = Path(env_root).resolve() if env_root else (ROOT / "_engine/adapter").resolve()
    return base / ref


def build(args: argparse.Namespace) -> Path:
    producer = (args.producer.resolve() if args.producer else producer_for_ref(args.ref))
    output = args.out.resolve()
    require(producer.is_dir(), f"missing producer: {producer}")
    require(output != producer and not output.is_relative_to(producer) and not producer.is_relative_to(output),
            "output must be disjoint from producer")
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())),
            "output must be new or empty")
    obj_dir = producer / "obj"
    require(obj_dir.is_dir(), "producer missing obj/ directory")
    # Exclude filter-input/filter objects; compile test-local copies (no producer relink).
    objects = sorted(p for p in obj_dir.glob("*.o") if p.stem not in {"filter-input", "filter"})
    require({"engine"}.issubset({p.stem for p in objects}), "producer lacks required engine object(s)")
    responses = {name: producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")}
    inputs: set[Path] = set(objects)
    expanded = {name: response_tokens(path, inputs, set()) for name, path in responses.items()}
    inputs.update({HARNESS, FIXTURE, READER, FILTER_C, Path(__file__).resolve(),
                   ROOT / "Engine/engine-private.h", ROOT / "Engine/filter-input.h",
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h"})
    inputs = {p.resolve() for p in inputs}
    require(all(p.is_file() for p in inputs), "an immutable input is missing")
    protected = {p.parent for p in inputs} | {ROOT / "Engine", ROOT / "Sources/CGlimsEngine", ROOT / "scripts"}
    require(not any(output == p or output.is_relative_to(p) or p.is_relative_to(output) for p in protected),
            "output must be disjoint from declared input directories")

    before = {str(p): digest(p) for p in sorted(inputs)}
    output.mkdir(parents=True, exist_ok=True)
    (output / "inputs.json").write_text(json.dumps(
        {"producer": str(producer), "inputs": before}, indent=2) + "\n")
    for name, path in {n: output / ("normalized-" + n) for n in responses}.items():
        path.write_text(shlex.join(expanded[name.split('-', 1)[1] if '-' in name else name]) + "\n")
    normalized = {name: output / f"normalized-{name}" for name in responses}

    obj_files = []
    common = [f"@{normalized['compile.rsp']}", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
              "-I", str(ROOT / "Engine")]
    for src, flags in [
        (READER, ["-fvisibility=hidden", "-Wall", "-Wextra", "-Werror=implicit-function-declaration"]),
        (FILTER_C, ["-fvisibility=hidden", "-Wall", "-Wextra", "-Werror=implicit-function-declaration"]),
        (HARNESS, ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]),
    ]:
        obj = output / (src.stem + ".o")
        cmd = ["xcrun", "clang", *common, *flags, "-c", str(src), "-o", str(obj)]
        print("==>", shlex.join(cmd), flush=True)
        subprocess.run(cmd, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
        obj_files.append(str(obj))
    binary = output / BINARY_NAME
    link = ["xcrun", "clang++", "-o", str(binary), *obj_files, *map(str, objects),
            f"@{normalized['objects.rsp']}", f"@{normalized['link.rsp']}"]
    try:
        print("==>", shlex.join(link), flush=True)
        subprocess.run(link, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
    finally:
        after = {path: (digest(Path(path)) if Path(path).is_file() else None) for path in before}
        changed = [path for path, val in before.items() if after[path] != val]
        (output / "inputs-after.json").write_text(json.dumps(
            {"inputs": after, "changed": changed}, indent=2) + "\n")
        if changed:
            msg = "Immutable producer/source inputs changed: " + ", ".join(changed)
            if sys.exc_info()[0] is None:
                raise RuntimeError(msg)
            print(msg, file=sys.stderr)
    (output / "binary.json").write_text(json.dumps(
        {"path": str(binary), "sha256": digest(binary)}, indent=2) + "\n")
    print(f"Built {binary}; NOT EXECUTED.", flush=True)
    return binary


def run(args: argparse.Namespace) -> int:
    binary = args.binary.resolve()
    work = args.work.resolve()
    require(binary.is_file(), f"missing test binary: {binary}")
    require(not work.exists() or (work.is_dir() and not any(work.iterdir())),
            "run requires a fresh empty work directory")
    require(work != ROOT and not work.is_relative_to(ROOT) and not ROOT.is_relative_to(work),
            "run directory must be outside the source checkout")
    work.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GLIMS_", "DYLD_", "GIMP3_", "GEGL_", "BABL_"))}
    for key, leaf in [("HOME", "home"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                      ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"), ("GEGL_SWAP", "swap")]:
        d = work / leaf
        d.mkdir()
        env[key] = str(d)
    env["G_DEBUG"] = "fatal-criticals"
    cmd = [str(binary), str(work)]
    log_path = work / "native.log"
    start = time.monotonic()
    with log_path.open("x") as log:
        proc = subprocess.Popen(cmd, env=env, cwd=work, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                pass
            proc.wait(timeout=5)
            rc = 124
    (work / "run.json").write_text(json.dumps({
        "binary": str(binary), "exit_code": rc, "timeout": args.timeout,
        "elapsed_seconds": time.monotonic() - start,
    }, indent=2) + "\n")
    print(f"Run exit {rc}; log {log_path}", flush=True)
    return rc


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="compile/link only against existing immutable producer")
    b.add_argument("--ref", default=os.environ.get("GLIMS_ENGINE_REF", "GIMP_3_2_8"))
    b.add_argument("--producer", type=Path)
    b.add_argument("--out", type=Path)
    r = sub.add_parser("run", help="execute built harness with private env and bounded timeout")
    r.add_argument("--binary", type=Path, required=True)
    r.add_argument("--work", type=Path, required=True)
    r.add_argument("--timeout", type=int, default=180)
    args = p.parse_args()
    if args.command == "build":
        if args.out is None:
            args.out = ROOT / ".build/lens-blur-source-tests" / args.ref
        build(args)
    else:
        if args.timeout <= 0:
            p.error("--timeout must be positive")
        sys.exit(run(args))


if __name__ == "__main__":
    main()
