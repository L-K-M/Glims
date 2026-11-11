#!/usr/bin/env python3
"""Build the pinned gzip identity oracle without changing its producer.

Only the harness and a private copy of image.c are compiled. That copy
redirects its two native load calls to fixture-owned alias switches.
Run the result with test-foreign-xcf-effect-fields.py run.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import runpy
import shlex
import subprocess


ROOT = Path(__file__).resolve().parent.parent
EXISTING = ROOT / "scripts/test-foreign-xcf-effect-fields.py"
HARNESS = ROOT / "Engine/tests/foreign-xcf-gzip-identity-tests.c"
BINARY_NAME = "foreign-xcf-gzip-identity-tests"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--producer", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--adapter-source-root", type=Path, default=ROOT,
                        help="matching frozen adapter tree (use the old tree for baseline)")
    args = parser.parse_args()

    existing = runpy.run_path(str(EXISTING))
    digest = existing["digest"]
    producer = args.producer.resolve()
    out = args.out.resolve()
    adapter = args.adapter_source_root.resolve()
    image = adapter / "Engine/image.c"
    image_object = producer / "obj/image.o"
    responses = [producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")]
    objects = sorted((producer / "obj").glob("*.o"))
    if image_object not in objects or not all(path.is_file() for path in [image, *responses]):
        parser.error("the pinned producer needs obj/image.o and all response files, with matching image.c")
    if out.is_relative_to(producer) or producer.is_relative_to(out):
        parser.error("output must not overlap the producer")
    if out.is_relative_to(ROOT) or out.is_relative_to(adapter):
        parser.error("output must be outside both source trees")
    core_objects = [Path(value) for value in shlex.split(responses[1].read_text())]
    if not core_objects or any(not path.is_absolute() or not path.is_file() for path in core_objects):
        parser.error("objects.rsp must list existing absolute native objects")
    linked_files = [Path(value) for value in shlex.split(responses[2].read_text())
                    if Path(value).is_absolute()]
    if any(not path.is_file() for path in linked_files):
        parser.error("link.rsp refers to a missing native input")
    includes = [tree / "Sources/CGlimsEngine/include" for tree in (ROOT, adapter)]
    inputs = sorted(set([
        *objects, *core_objects, *linked_files, *responses, image, HARNESS, existing["HARNESS"],
        EXISTING, Path(__file__).resolve(), *(directory / "glims_engine.h" for directory in includes),
        *(ROOT / "Engine").glob("*.h"), *(adapter / "Engine").glob("*.h"),
    ]))
    before = {str(path): digest(path) for path in inputs}

    out.mkdir(parents=True, mode=0o700, exist_ok=True)
    if any(out.iterdir()):
        parser.error("output must be empty")
    harness_object = out / "harness.o"
    shimmed_image = out / "image.o"
    binary = out / BINARY_NAME
    common = ["xcrun", "clang", f"@{responses[0]}", "-std=c11", "-O2"]
    commands = [
        [*common, "-I", str(includes[0]), "-I", str(ROOT / "Engine"),
         "-Wall", "-Wextra", "-Werror", "-c", str(HARNESS), "-o", str(harness_object)],
        [*common, "-I", str(includes[1]), "-I", str(adapter / "Engine"),
         "-Dfile_open_image=glims_test_file_open_image", "-Dxcf_load_stream=glims_test_xcf_load_stream",
         "-c", str(image), "-o", str(shimmed_image)],
        ["xcrun", "clang++", "-o", str(binary), str(harness_object), str(shimmed_image),
         *(str(path) for path in objects if path != image_object), f"@{responses[1]}", f"@{responses[2]}"],
    ]
    try:
        for command in commands:
            print(shlex.join(command), flush=True)
            subprocess.run(command, cwd=ROOT, check=True)
    finally:
        if sorted((producer / "obj").glob("*.o")) != objects or any(
                not path.is_file() or digest(path) != before[str(path)] for path in inputs):
            raise SystemExit("immutable producer/source inputs changed")
    (out / "build.json").write_text(json.dumps({
        "producer": str(producer), "ref": existing["PINNED_REF"], "commands": commands,
        "adapter_source_root": str(adapter), "source_sha256": digest(HARNESS),
        "binary_sha256": digest(binary), "inputs_sha256": before,
    }, indent=2, sort_keys=True) + "\n")
    print(f"Built {binary}. The producer and source inputs are unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
