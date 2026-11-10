#!/usr/bin/env python3
"""Compile/link only the slot167 layer-pick harness against immutable producer inputs.

This driver never rebuilds/relinks adapter sources or runs the harness. Select an
existing private producer containing obj/, compile.rsp, objects.rsp and link.rsp.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/layer-pick-tests.c"

# Exact source sets reviewed for this oracle, not broad future version ranges.
REVIEWED_CORE_PROFILES = {'GIMP_3_2_8': {'commit': '7addd2b77efb798bbdc4d2fb082e786a48478ced',
                'pick_sha256': '841143310670d5edbdd147d0b793ad101f546c05886edaedd8087bb83475892d',
                'version': (3, 2, 8),
                'low_threshold': False},
 'GIMP_3_2_0': {'commit': 'edbd1ea7384e63efa8fe326dd79ffe4fbe6722db',
                'pick_sha256': '841143310670d5edbdd147d0b793ad101f546c05886edaedd8087bb83475892d',
                'version': (3, 2, 0),
                'low_threshold': False},
 'GIMP_3_0_8': {'commit': '6ac8031c9555667e080fef0324fca9f28a02e5ab',
                'pick_sha256': '38b709bea1ad7d46ec50ac3f74be3e194e23c7104d4d10948e2f4ca72d3e5e35',
                'version': (3, 0, 8),
                'low_threshold': False},
 'master': {'commit': '5374deeec14a0366df4b17b6e5c6f9aff63db2ca',
            'pick_sha256': 'ac4827d8662d1a2f3f60a99388308ee1aad2c3ae8a3b81e3f95c55b159040f10',
            'version': (3, 3, 1),
            'low_threshold': True}}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def resolve_response_token(token: str) -> Path | None:
    if token.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        return None
    if token.startswith("@"):
        nested = Path(token[1:])
        return nested if nested.is_absolute() else ROOT / nested
    if token.startswith("-"):
        return None
    candidate = Path(token)
    if candidate.suffix in {".o", ".a", ".dylib"}:
        return candidate
    return None


def response_inputs(path: Path, seen: set[Path]) -> None:
    path = path.resolve()
    if path in seen:
        return
    require(path.is_file(), f"missing response input: {path}")
    seen.add(path)
    for token in shlex.split(path.read_text()):
        if token.startswith("@"):
            nested = resolve_response_token(token)
            if nested is not None:
                response_inputs(nested, seen)
            continue
        candidate = resolve_response_token(token)
        if candidate is not None:
            require(candidate.is_absolute() and candidate.is_file(),
                    f"producer link inputs must be existing absolute paths: {candidate}")
            seen.add(candidate.resolve())


def reviewed_core_profile(engine_set: str, source_root: Path | None) -> dict:
    profile = dict(REVIEWED_CORE_PROFILES[engine_set])
    source_root = (source_root or ROOT / "_engine/src" / engine_set / "gimp").resolve()
    source = source_root / "app/core/gimpimage-pick-item.c"
    require(source.is_file(), f"missing reviewed Core pick source: {source}")
    commit = subprocess.check_output(["git", "-C", str(source_root), "rev-parse", "HEAD"],
                                     text=True, stdin=subprocess.DEVNULL).strip()
    require(commit == profile["commit"], f"unreviewed Core source commit for {engine_set}: {commit}")
    require(digest(source) == profile["pick_sha256"], f"Core pick source hash changed for {engine_set}")
    committed = subprocess.check_output(["git", "-C", str(source_root), "show",
                                         "HEAD:app/core/gimpimage-pick-item.c"], stdin=subprocess.DEVNULL)
    require(hashlib.sha256(committed).hexdigest() == profile["pick_sha256"],
            f"committed Core pick source does not match reviewed profile for {engine_set}")
    profile.update(engine_set=engine_set, source_root=str(source_root), pick_source=str(source))
    return profile


def build(producer: Path, output: Path, engine_set: str, gimp_source: Path | None = None) -> None:
    producer, output = producer.resolve(), output.resolve()
    profile = reviewed_core_profile(engine_set, gimp_source)
    require(producer.is_dir(), f"missing producer: {producer}")
    require(output != producer and not output.is_relative_to(producer) and not producer.is_relative_to(output),
            "test output and producer trees must be disjoint")
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), "output must be new or empty")
    objects = sorted((producer / "obj").glob("*.o"))
    require({"engine", "image"}.issubset({p.stem for p in objects}), "producer lacks required API/image objects")
    responses = {name: producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")}
    inputs = set(objects)
    for path in responses.values():
        response_inputs(path, inputs)
    inputs.update({HARNESS, ROOT / "Engine/engine-private.h", ROOT / "Engine/engine.c", ROOT / "Engine/layer-pick.c",
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h", Path(__file__).resolve()})
    inputs.add(Path(profile["pick_source"]))
    inputs = {path.resolve() for path in inputs}
    require(all(path.is_file() for path in inputs), "a declared immutable input is missing")
    source_roots = {ROOT / "Engine", ROOT / "Sources/CGlimsEngine", ROOT / "scripts",
                    Path(profile["source_root"])}
    protected_dirs = {path.parent for path in inputs} | source_roots
    require(not any(output == path or output.is_relative_to(path) or path.is_relative_to(output)
                    for path in protected_dirs), "output must be disjoint from all declared input directories")
    before = {str(p): digest(p) for p in sorted(inputs)}
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"producer": str(producer), "source": str(HARNESS), "inputs": before,
                "reviewed_core_profile": profile}
    (output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    obj = output / "layer-pick-tests.o"
    binary = output / "layer-pick-tests"
    major, minor, micro = profile["version"]
    profile_flags = [f"-DGLIMS_PICK_EXPECTED_MAJOR={major}", f"-DGLIMS_PICK_EXPECTED_MINOR={minor}",
                     f"-DGLIMS_PICK_EXPECTED_MICRO={micro}",
                     f"-DGLIMS_PICK_EXPECTED_LOW_THRESHOLD={int(profile['low_threshold'])}"]
    commands = [
        # The new facade header must win even when old producer response
        # paths name a different checkout. Its include guard then prevents
        # accidentally compiling the baseline test against the old166 shape.
        ["xcrun", "clang", "-I", str(ROOT / "Sources/CGlimsEngine/include"), "-I", str(ROOT / "Engine"),
         "-include", str(ROOT / "Sources/CGlimsEngine/include/glims_engine.h"), f"@{responses['compile.rsp']}",
         *profile_flags, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-c", str(HARNESS), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         f"@{responses['objects.rsp']}", f"@{responses['link.rsp']}"]
    ]
    try:
        for command in commands:
            print("==>", shlex.join(command), flush=True)
            subprocess.run(command, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
    finally:
        after = {path: digest(Path(path)) if Path(path).is_file() else None for path in before}
        changed = [path for path, value in before.items() if after[path] != value]
        try:
            require(reviewed_core_profile(engine_set, Path(profile["source_root"])) == profile,
                    "reviewed Core profile changed during compile/link")
        except (RuntimeError, subprocess.CalledProcessError) as error:
            changed.append(f"reviewed Core profile: {error}")
        (output / "inputs-after.json").write_text(json.dumps({"inputs": after, "changed": changed}, indent=2) + "\n")
        if changed:
            message = "Immutable producer/source inputs changed: " + ", ".join(changed)
            if sys.exc_info()[0] is None:
                raise RuntimeError(message)
            print(message, file=sys.stderr)
    print(f"Built {binary}; NOT EXECUTED. Frozen inputs: {output / 'inputs.json'}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("build", help="compile/link only; never execute")
    command.add_argument("--producer", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    command.add_argument("--engine-set", choices=REVIEWED_CORE_PROFILES, required=True,
                         help="explicit reviewed native Core threshold/source profile")
    command.add_argument("--gimp-source", type=Path,
                         help="exact local Core checkout (default: _engine/src/ENGINE_SET/gimp)")
    args = parser.parse_args()
    build(args.producer, args.out, args.engine_set, args.gimp_source)


if __name__ == "__main__":
    main()
