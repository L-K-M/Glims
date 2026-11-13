#!/usr/bin/env python3
"""Compile private carrier code and tests against immutable adapter objects.

Requires a prior native input manifest binding the producer objects and its
private/public headers. No adapter or upstream rebuild, app adoption or GUI.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_runner", ROOT / "scripts/test-lab-storage.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
SOURCES = [ROOT / name for name in (
    "Engine/lab-layer-map.c", "Engine/lab-layer-storage.c",
    "Engine/tests/lab-layer-storage-tests.c")]
HEADERS = ["Engine/engine-private.h", "Sources/CGlimsEngine/include/glims_engine.h"]


def require(value, message):
    if not value:
        raise RuntimeError(message)


def run(args, work):
    producer = (args.adapter_root / args.ref).resolve()
    receipt_path = args.producer_inputs.resolve()
    receipt = json.loads(receipt_path.read_text())
    require(receipt["ref"] == args.ref and Path(receipt["producer"]).resolve() == producer,
            "Producer attestation identifies different inputs")
    attested = receipt["inputs"]
    require(isinstance(attested, dict) and attested, "Missing producer input hashes")
    for path, expected in attested.items():
        require(Path(path).is_file() and runner.digest(Path(path)) == expected,
                "Attested producer input changed: " + path)
    for relative in HEADERS:
        matches = [digest for path, digest in attested.items() if path.endswith("/" + relative)]
        require(len(matches) == 1 and runner.digest(ROOT / relative) == matches[0],
                "Fixture header ABI differs from attested producer: " + relative)
    objects = sorted((producer / "obj").glob("*.o"))
    require({"engine.o", "channels.o"}.issubset({p.name for p in objects}), "Missing producer objects")
    require(all(str(p.resolve()) in attested for p in objects), "Unattested producer object")
    require(not any(p.stem in {source.stem for source in SOURCES} for p in objects),
            "Private carrier already exists in producer; use a producer without duplicate definitions")
    inputs = {p.resolve() for p in objects}
    responses = runner.checked_responses(producer, inputs)
    inputs.update(p.resolve() for p in SOURCES)
    inputs.update(p.resolve() for p in (ROOT / "Engine").glob("*.h"))
    inputs.update((ROOT / relative).resolve() for relative in HEADERS)
    inputs.update([Path(__file__).resolve(), Path(runner.__file__).resolve(),
                   runner.RESPONSE_HELPER.resolve(), receipt_path])
    inputs.update(Path(p).resolve() for p in attested)
    require(all(p.is_file() for p in inputs), "Missing input")
    require(runner.disjoint(work, ROOT) and runner.disjoint(work, producer) and
            all(runner.disjoint(work, p.parent) for p in inputs), "Output overlaps inputs")
    require(not work.exists() or (work.is_dir() and not any(work.iterdir())), "Output must be new or empty")
    work.mkdir(parents=True, exist_ok=True)
    before = {str(p): runner.digest(p) for p in sorted(inputs)}
    (work / "inputs.json").write_text(json.dumps(dict(ref=args.ref, producer=str(producer),
        producer_attestation=str(receipt_path), inputs=before), indent=2) + "\n")
    env = os.environ.copy()
    for key, leaf in (("HOME", "home"), ("CFFIXED_USER_HOME", "home"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                      ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"), ("BABL_CACHE_DIR", "babl-cache")):
        (work / leaf).mkdir(exist_ok=True)
        env[key] = str(work / leaf)
    copied = {}
    for name, tokens in responses.items():
        copied[name] = work / ("normalized-" + name)
        copied[name].write_text(shlex.join(tokens) + "\n")
    local_objects = [work / (source.stem + ".o") for source in SOURCES]
    commands = [["xcrun", "clang", "-I", str(ROOT / "Engine"), "-I",
        str(ROOT / "Sources/CGlimsEngine/include"), "@" + str(copied["compile.rsp"]),
        "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
        "-Werror=excess-initializers", "-Wno-declaration-after-statement", "-c", str(source), "-o", str(obj)]
        for source, obj in zip(SOURCES, local_objects)]
    binary = work / "lab-layer-storage-tests"
    commands.append(["xcrun", "clang++", "-o", str(binary), *map(str, local_objects), *map(str, objects),
                     "@" + str(copied["objects.rsp"]), "@" + str(copied["link.rsp"])])
    result = 1
    try:
        with (work / "build.log").open("x") as log:
            for command in commands:
                result = runner.bounded_process(command, log, 180, work, env)
                if result:
                    print((work / "build.log").read_text(), end="")
                    return result
        with (work / "run.log").open("x") as log:
            result = runner.bounded_process([str(binary), str(work)], log, args.timeout, work, env)
        raw = (work / "run.log").read_text()
        print(raw, end="")
        if result == 0 and (not re.search(r"^checks=[1-9][0-9]* failures=0$", raw, re.M) or
                re.search(r"^FAIL|CRITICAL|ERROR: AddressSanitizer|runtime error:", raw, re.M)):
            result = 1
            print("Native output contains a failure or omits the success summary", file=sys.stderr)
        return result
    finally:
        changed = [path for path, expected in before.items()
                   if not Path(path).is_file() or runner.digest(Path(path)) != expected]
        if sorted((producer / "obj").glob("*.o")) != objects:
            changed.append("producer object membership")
        (work / "result.json").write_text(json.dumps(dict(ref=args.ref, exit_code=result,
            changed_inputs=changed), indent=2) + "\n")
        require(not changed, "Immutable inputs changed: " + ", ".join(changed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path, required=True)
    parser.add_argument("--producer-inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("Invalid engine ref")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 600:
        parser.error("Timeout must be in (0,600]")
    if args.output:
        return run(args, args.output.resolve())
    with tempfile.TemporaryDirectory(prefix="glims-lab-layer-storage-") as output:
        return run(args, Path(output).resolve())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"test-lab-layer-storage: {error}", file=sys.stderr)
        raise SystemExit(1)
