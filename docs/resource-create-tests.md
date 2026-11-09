# resource_create_pixels (slot 129) standalone facade tests

Relay source review corrected the stroke/filter call signatures before
handoff. Happy-path callers now overwrite their mutable source buffers
after creation, while thumbnails and saved payloads must retain the
original pixels. The native clipboard is independently observed through
its built-in pattern resource; copying pixels from the fixture image is
not treated as evidence about the global clipboard. Fault counters reset
for each armed call, and the shim permits the configured save-folder mkdir
performed by the native chooser without confusing it with staging.
These corrections have not been compiled or run natively here.

Test-only harness for the pixel-to-resource creation slice documented in
[`resource-pixel-create.md`](resource-pixel-create.md). Four new files, no
production file touched:

| File | Role |
|---|---|
| `Engine/tests/resource-create-tests.c` | Facade-only runner: `dlopen()`s the adapter, uses only `glims_engine.h`, never links engine objects or libgimp. Two phases: `create` and `verify`. |
| `Engine/tests/resource-create-interpose.c` | Deterministic dyld interposer (`DYLD_INSERT_LIBRARIES` shim) with an exported `glims_test_*` control API, in the style of `metadata-error-interpose.c`. |
| `scripts/test-resource-create.py` | Selects an already-built producer, compiles the two sources in a unique temp dir, runs the two phases, cleans up. Never rebuilds the producer. |
| `docs/resource-create-tests.md` | This file. |

## CLI

```
python3 scripts/test-resource-create.py [--ref GIMP_REF] [--adapter-root DIR] [--timeout SECONDS]
```

- `--ref` — engine set name; default is the first `ENGINE_SETS` entry in
  `scripts/engine.env` (the pinned engine).
- `--adapter-root` — adapter output root; default is `$GLIMS_ADAPTER_ROOT`
  or `<repo>/_engine/adapter`. The producer is
  `ADAPTER_ROOT/REF/libglimsengine.dylib` with its own `compile.rsp` /
  `link.rsp`; a missing producer is an error naming `build-adapter.sh`.
  Nothing is ever rebuilt and no producer prefix is hard-coded.
- `--timeout` — per-phase harness timeout, default 900 s.
- `--help` prints usage and exits before compiling, starting or writing
  anything.

The harness itself is invoked explicitly as
`resource-create-tests LIBRARY WORK_DIR create|verify` with `HOME`,
`XDG_CACHE_HOME`, `GIMP3_DIRECTORY` and `DYLD_INSERT_LIBRARIES` all under a
unique temporary work directory; an isolated `gimprc` in the user
directory pins `brush-path-writable` / `pattern-path-writable` to
`${gimp_dir}/brushes` / `${gimp_dir}/patterns` (the source-confirmed
defaults for a fresh `GIMP3_DIRECTORY`, which `Engine/engine.c` sets to
the configured user directory) while keeping `${gimp_data_dir}` in the
search path so the stock catalog stays loaded. The engine starts only
once per process, so the script runs the `create` phase and then the
`verify` phase on the same work directory: `verify` is a real restart and
checks that the saved resources load back and `resource_resolve()` finds
them.

## Scope of the checks

`create` phase (all through the facade only):

- Happy paths for brush and pattern from a tiny independent known RGBA
  buffer (distinct RGB, opaque, partial alpha 128/40/4, fully
  transparent): `GLIMS_STATUS_OK`, positive `outID`, the exact requested
  name (including a non-ASCII UTF-8 label) in `resources()`,
  `resource_identifiers()` name + non-internal + collection,
  `resource_resolve()` round trip returning the same id in-session,
  `resource_thumbnail()` at native 3x2 with pixel-exact source bytes, and
  the durable file in the writable folder parsed natively: GBR v2 (7
  big-endian uint32 fields, `GIMP` magic, spacing, NUL-terminated name,
  exact `width*height*4` payload) or PAT v1 (6 fields, `GPAT` magic,
  exact payload), correct `.gbr` / `.pat` extension and location, and no
  `.glims-stage-*` leftovers.
- The caller's RGBA buffer is byte-identical after every call (the new
  resource owns an independent copy).
- `image_new` plus initial `image_render`, `image_undo_info`,
  `selection_bounds` and `image_copy_pixels` (owned facade copy, released
  with `free_pixels`) snapshots are identical before and after successful
  and refused creations: no image, history, selection or clipboard
  change.
- Refusals, each with a prefilled `outID` that must come back exactly 0:
  missing `outID`, unknown kind 0/99, gradient (expected
  `UNSUPPORTED`), NULL/empty/256-byte/C0/C1/invalid-UTF-8 names, width
  or height 0, negative, or over 10000, byte count off by one either
  way, NULL pixels, brush spacing 0/1001/huge, pattern spacing nonzero,
  and a duplicate exact name (expected `FAILED`, never uniquified) —
  with catalog rows, files and image snapshots unchanged afterwards.
- `BUSY` while a stroke is open and while a filter session is open
  (`outID` 0, no undo step added), then a successful create once idle.
- Meaningful stock-resource baseline guard: `resources()` for brushes
  and patterns is non-empty before anything is created, so every
  "catalog unchanged" comparison is against a real baseline; final counts
  are baseline + created.
- Armed deterministic fault cases (shim armed only after engine start,
  immediately around one `resource_create_pixels` call, disarmed right
  after; hook-fired and exact-path-match are asserted, any miss or
  missing export fails closed):
  - staging collision: a pre-created empty hidden `.glims-stage-<uuid>`
    sentinel directory in the writable brush folder must SURVIVE the
    refused create (`FAILED`, `outID` 0, catalog unchanged, no final
    file). Baseline-RED oracle: the current cleanup deletes this unowned
    directory.
  - final collision (brush `.gbr` and pattern `.pat`): a pre-created
    sentinel `<uuid>.gbr` / `<uuid>.pat` file with unique bytes must
    SURVIVE byte-identical (the native no-overwrite `g_file_move` fails
    — the hook records that it did, with the exact expected src/dst —
    and the call is refused), while the call's own staging directory and
    file are removed and no extra resource files appear. Baseline-RED
    oracle: the current cleanup deletes the pre-existing target.
  - after disarming, a normal create succeeds and the shim replaces no
    uuid (arming is isolated), proving forwarding and cleanup recovery.
- The interposer only ever substitutes `g_uuid_string_random` while
  armed and only records/forwards `g_file_make_directory` /
  `g_file_move`; every armed path must equal the harness-supplied path
  under the work directory (`path_mismatch` must stay 0), so nothing
  outside the isolated config is touched. State is owned copies; no
  pointers into request storage are retained.

`verify` phase (fresh process, same work directory): each resource handed
over via `WORK_DIR/restart.txt` resolves through `resource_resolve()`
to a positive id present in `resources()`, keeps its identifiers, its
thumbnail is still pixel-exact, and its durable file is still on disk
with the same native header and payload; no staging leftovers; a fresh
create still works in the restarted engine.

## Producer assumptions

- `ADAPTER_ROOT/REF/` contains `libglimsengine.dylib`, `compile.rsp` and
  `link.rsp` as written by `scripts/build-adapter.sh` /
  `scripts/adapter-flags.py` (one quoted argument per line).
- The producer's `compile.rsp` carries the glib/gio include paths; its
  `link.rsp` lists absolute `libglib-2.0.dylib`, `libgobject-2.0.dylib`
  and `libgio-2.0.dylib` paths, which are the only libraries the shim
  links. The runner links nothing (dlopen facade, like the conformance
  runner); no libgimp and no engine objects are linked anywhere.
- The writable resource folders are `<user>/brushes` and
  `<user>/patterns` under the configured user directory (source-confirmed
  defaults; additionally pinned by the isolated gimprc). If an engine
  set ever chose a different folder, the interposer's exact-path check
  fails closed instead of writing elsewhere.
- The adapter calls `g_uuid_string_random()`, `g_file_make_directory()`
  and `g_file_move()` directly once per creation, so dyld interposition
  sees exactly the staging mkdir and the staged-to-final move.

## Acceptance results

Root compiled and ran both native phases on every supported engine. The
first run reproduced nine expected failures: wrong gradient status and
staging/final collision sentinel deletions. After the ownership/status fixes,
all checks passed on every engine, including fresh-process persistence.

A later source review found a missing output reset when a NULL engine makes
dispatch return NOT_RUNNING. The added facade check failed once before the
bridge fix. Final general native suites and both harness phases pass on all
four engines with that regression included. Python syntax and help checks
also pass. App controls and final self-contained bundle checks are separate.
