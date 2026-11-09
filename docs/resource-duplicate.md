# Saved-resource duplication (slot 131)

One bounded native+Swift slice: `resource_duplicate` copies ONE current
brush, pattern or gradient of the engine's own resource catalogs through
the engine's per-class native copy, saves the private duplicate into the
engine's configured writable data folder under its native subclass
extension, and publishes it to the factory of the source's own kind. No
UI, no rename/delete/create-default, no gradient-from-pixels, no catalog
management milestone.

## Facade and API tracking

- Append-only slot **131**, appended after `adjustment_layer_new`
  (slot 130) at the end of `GlimsEngineAPI`
  (`Sources/CGlimsEngine/include/glims_engine.h`). `api_version` stays
  `GLIMS_ENGINE_API_VERSION` = 1; `struct_size` grows with the appended
  pointer. No existing layout, signature, prefix or order changed;
  `Sources/CGlimsEngine/abi.c`'s assert still stands.
- Signature (facade types only; both handles are full `uint64_t`, never
  narrowed through a 32-bit marshal field):

  ```c
  GlimsStatus (*resource_duplicate) (GlimsEngine *engine, GlimsResourceID sourceID,
                                     const char *name, GlimsResourceID *outID,
                                     char **error);
  ```

- Adapter: new `Engine/resource-duplicate.c` (picked up by the
  `Engine/*.c` glob in `scripts/build-adapter.sh`), prototypes in
  `Engine/engine-private.h`, bridge `GlimsResourceDuplicateArgs` +
  `api_resource_duplicate` appended in `Engine/engine.c` (the bridge
  zeroes `outID` before dispatch, so an engine-null NOT_RUNNING also
  clears a prefilled handle). `Engine/resource.c` now exposes two
  narrow private helpers reused here: `glims_lookup_resource_data()`
  (the generic `lookup_resource()` admission) and
  `glims_factory_for_resource()`.
- Shared persistence: `Engine/resource-create.c` was refactored
  minimally — `glims_valid_resource_name`, `glims_resource_name_taken`,
  and the checked pipeline `glims_resource_staging_begin` +
  `glims_resource_save_and_publish` + `glims_resource_staging_cleanup`
  are now non-static and shared; `glims_resource_create_pixels` calls
  them with its unchanged kind-based `.gbr`/`.pat` extension, identical
  observable behavior (same operation order: early collision check →
  save-folder choice → staging mkdir → build → checked save → promote
  → publish).
- Swift: `EngineSession.duplicateResource(_:name:)` over the new slot,
  with the pre-RPC label gate `EngineSession.validateResourceName(_:)`
  (extracted from `validateResourceCreation`, same messages), tests in
  `Tests/GlimsKitTests/ResourceDuplicateInputTests.swift`.

## Contract

All validation happens before any mutation; `outID` is zeroed first
(bridge) and again on EVERY failure, including missing-output and
engine-null dispatch.

| Input | Rule | Refusal |
|---|---|---|
| `outID` | required | INVALID_ARGUMENT |
| `name` | identical to fixed `resource_create_pixels`: nonempty valid UTF-8, no embedded NUL, no Unicode Cc controls, ≤ 255 UTF-8 bytes | INVALID_ARGUMENT |
| `sourceID` | resolved once per call via the shared typed admission: 0, high bits, or above the native gint id maximum never reach the native table | INVALID_ARGUMENT |
| `sourceID` | validly shaped but stale, foreign, or no longer in this engine's current factory of its kind | NOT_FOUND |
| engine state | no image argument; refuses `busy > 0` OR any stroke OR any filter session (any image) — the fixed create admission | BUSY |
| capability | `gimp_data_is_duplicatable(source)` must hold, the private copy must be saveable (`gimp_data_is_writable`), and an empty native pipe (`n_brushes < 1`, would crash the native pipe copy) is refused | UNSUPPORTED, actionable message, outID 0 |
| name collision | exact-name match against the current factory membership of the source's own kind, checked before any filesystem mutation | FAILED, never uniquified |

The source's writability is NOT required: a built-in read-only
(internal) resource is duplicatable when the native capability check
allows it. Success: the duplicate is persisted (checked save), a
member of its kind's factory with the exact requested name, and
`outID` is its positive handle, distinct from `sourceID`, usable with
`resources()`, `resource_identifiers()`, `resource_resolve()`,
`resource_thumbnail()` and the brush/pattern/gradient consumers. The
source is never renamed, saved, deleted or dirtied; no image, undo
history, selection, user/global context or native clipboard is read or
changed.

## Native design, with source citations

Citations verified against `_engine/src/GIMP_3_2_8/gimp` and
signature/source-checked identical in `GIMP_3_2_0`, `GIMP_3_0_8` and
`master` (same declarations in `gimpdata.h`; same class vfunc
assignments in `gimpbrush.c`, `gimpbrushgenerated.c`, `gimpbrushpipe.c`,
`gimpbrushclipboard.c`, `gimppattern.c`, `gimpgradient.c`,
`gimppatternclipboard.c`; same `gimp_data_duplicate` body).

1. **Private owned copy.** `gimp_data_duplicate(source)`
   (`gimpdata.c:1284-1312`) runs the class `duplicate`/`copy` vfunc and
   then clears name and file and sets `writable = (class->save != NULL)`.
   Transfer full; NULL when not duplicatable. Per class:
   - bitmap brush: `gimp_brush_copy` deep-copies the owned mask/pixmap
     TempBufs (`gimpbrush.c:444-460`) — no shared mutable payload;
   - generated (parametric) brush: `gimp_brush_generated_copy` copies
     shape/radius/spikes/hardness/aspect/angle (`gimpbrushgenerated.c:287`);
   - pipe brush: `gimp_brush_pipe_copy` duplicates each child into owned
     objects and copies rank/stride/select/index/params
     (`gimpbrushpipe.c:171-228`); an `n_brushes < 1` pipe would deref
     NULL at `pipe->current = pipe->brushes[0]`, so the adapter refuses
     it before duplicating (the loader itself requires `n_brushes >= 1`,
     `gimpbrushpipe-load.c:107`);
   - clipboard brush/pattern: their `duplicate` vfuncs produce a plain
     bitmap `GimpBrush` / `GimpPattern` via `gimp_data_copy`
     (`gimpbrushclipboard.c:176`, `gimppatternclipboard.c:156`) — the
     signal-bound clipboard objects are only read, never written;
   - pattern: `gimp_pattern_copy` deep-copies the mask TempBuf
     (`gimppattern.c:218-227`);
   - gradient: `gimp_gradient_copy` deep-copies every segment struct
     and both colors (`gimpgradient.c:268-310`) — stop types, including
     the dynamic FG/BG types, are preserved verbatim, so the duplicate's
     FG/BG semantics stay native and are never flattened.
   In every case the source is only read.
2. **No factory convenience call.** `gimp_data_factory_data_duplicate`
   saves unchecked and publishes despite a failed save
   (`gimpdatafactory.c`), so it is not used.
3. **Name.** `gimp_object_set_name` copies the requested label into the
   private duplicate and marks it dirty (`gimpobject.c:220-236`,
   `gimpdata.c:346-354`), so the checked save persists the requested
   name inside the file.
4. **Persistence.** Reuses the fixed pixel-create pipeline verbatim
   (see `docs/resource-pixel-create.md` §5): configured
   writable/search save folder (`gimp_data_factory_get_data_path` /
   `_writable`, reproducing the static `gimp_data_factory_get_save_dir`
   chooser, no HOME fallback), unique OWNED hidden staging dir
   `.glims-stage-<uuid>` (loader-ignored, `gimpdataloaderfactory.c`),
   `gimp_data_set_file` + `gimp_data_is_writable`, checked
   `gimp_data_save` (vfunc AND stream close, `gimpdata.c:614-699`),
   no-overwrite no-fallback `g_file_move` to a UUID final name, reassoc,
   exact-name/current-factory membership verified publication. The
   extension is `gimp_data_get_extension(copy)` — the duplicated
   subclass's own (`.gbr`/`.vbr`/`.gih`/`.pat`/`.ggr`,
   `gimpbrush-load.h:21`, `gimpbrushgenerated-load.h:23`,
   `gimpbrushpipe-load.h:21`, `gimppattern-load.h:21`,
   `gimpgradient-load.h:21`), exactly what its save vfunc writes and its
   loader matches.
5. **Cleanup ownership.** Only this call's actually-created staging
   dir/files and — on failure only — the actually-promoted final file
   are deleted (`glims_resource_staging_cleanup`); preexisting sentinel
   paths always survive. No multi-step transaction is promised. All
   GError paths go through `glims_fail` (consumes the GError); the
   owned duplicate reference is released on every path, with the
   container's own reference remaining after publication.

## Swift side

`duplicateResource(_:name:)` validates the label through the pure
`validateResourceName` (nonempty UTF-8, no NUL, ≤ 255 UTF-8 bytes, no
Cc controls — `generalCategory == .control`) BEFORE the RPC, passes the
`UInt64` handles through unchanged, and throws INVALID/NOT_FOUND/BUSY/
UNSUPPORTED/FAILED with the facade status. The returned positive handle
is consumed by the existing read APIs unchanged. Call off the main
thread, like the other catalog work.

## Tests (source, for Root to run)

- `Engine/tests/resource-duplicate-tests.c` + `scripts/test-resource-duplicate.py`
  (facade-only dlopen runner, `--ref`/`--adapter-root`, producer's own
  `compile.rsp`/`link.rsp`, never libgimp, isolated
  HOME/XDG_CACHE_HOME/GIMP3_DIRECTORY, phases `duplicate`/`verify` on one
  work dir; reuses `Engine/tests/resource-create-interpose.c` unchanged
  through DYLD_INSERT_LIBRARIES). Oracles, all against the public facade:
  - duplicate of a pixel-created brush, pixel-created pattern, file-backed
    stock brush, internal read-only parametric brush, file-backed stock
    pattern, file-backed stock gradient and internal read-only gradient →
    distinct new id, exact requested name, correct kind, identity
    roundtrip + `resource_resolve`, thumbnail byte-equality with the
    source under the SAME per-call FG/BG colors (gradients keep native
    dynamic FG/BG), exactly one durable file with the native subclass
    extension (GBR payload/name/spacing exactness for the pixel brush;
    GGR `Name:` header for gradients), no staging leftovers, source
    identity/thumbnail/catalog row unchanged;
  - refusals with outID 0: missing outID, NULL/empty/256-byte/control/
    invalid-UTF-8 names, id 0 / all-high-bits / 1<<40 / sign-bit
    (INVALID_ARGUMENT), G_MAXINT and a stale-looking in-range id
    (NOT_FOUND), exact same-kind collisions (FAILED, catalog+folder
    unchanged), cross-kind name reuse (OK);
  - BUSY during an open stroke and during an open filter session, no
    undo step added;
  - image render/undo/selection and the native clipboard pattern
    unchanged across the whole battery;
  - armed deterministic fault cases (reused shim): staging-dir collision
    and final-file collision sentinels survive with their bytes intact,
    own staging removed, FAILED + outID 0, catalog unchanged, no path
    outside WORK_DIR touched, shim inert while disarmed;
  - restart phase: fresh engine on the same directories resolves every
    handed-off duplicate by identity, catalog row + thumbnail hash +
    durable file (with native header) all match.
- `Tests/GlimsKitTests/ResourceDuplicateInputTests.swift`: pure
  validation tests of `validateResourceName` and its identity with the
  create path's label rules.

## Initial helper checks and coverage limits (runtime results below)

- The helper initially left native execution to Root; only `swift build -j 2`, `swift build -j 2 --build-tests`
  and `python3 scripts/test-resource-duplicate.py --help` + AST parse
  were run by that helper. Root subsequently executed the matrix below.
- The UNSUPPORTED capability refusal is implemented
  (`gimp_data_is_duplicatable` false / copy not writable / empty pipe)
  but is not exercisable through the facade with the shipped catalogs:
  every class resident in the three loader factories implements
  `copy`/`duplicate` (MyPaint brushes live in a separate factory and
  resolve NOT_FOUND here). The empty-pipe guard is likewise defensive
  (the native loader requires `n_brushes >= 1`).
- Source "dirty" state and source file bytes are not exposed through
  the facade; the original facade-only tests verify source identity, thumbnail and catalog
  membership instead. Ownership uncertainty: none found — every class
  copy produces owned payloads (`gimp_temp_buf_copy`,
  `gegl_color_duplicate`, per-child `gimp_data_duplicate`); the only
  internal pointer share is a duplicated pipe's mask/pixmap aliasing its
  own owned first child, which stays inside the new private object.
- A zero-segment gradient copies and saves without crashing (the GGR
  writer emits `0` segments), but no stock catalog entry has one; not
  exercised.


## Root acceptance, 2026-11-09

Compilation alone did not establish persistence. Primary loader contracts
showed two missing gates: generated-brush VBR and gradient GGR loaders strip
surrounding ASCII whitespace from names, and PAT stores only raw component
bytes without precision/transfer/profile metadata. The new independent
Core-linked harness reproduced 60 failures against b080628, with no GLib
criticals after synthetic sources received proper internal identifiers.

The private copy now refuses VBR/GGR edge-whitespace names with
INVALID_ARGUMENT before staging, and refuses patterns whose Babl format is
not exactly the PAT loader's Y'/Y'A/R'G'B'/R'G'B'A u8 encodings with
UNSUPPORTED. It preserves the source instead of silently normalizing pixels.
The general bitmap/pipe/pattern name policy is unchanged. Native save success
alone is no longer treated as a sufficient format-roundtrip guarantee.

Each of the four engines passes 261 existing duplication/fault/restart
checks, 177 new persistence checks, and all 149 creation regression checks
through the extracted shared persistence helper. General conformance passes
1,917 / 1,703 / 1,917 / 1,917 checks. New evidence uses an actual generated
brush and verifies reloaded parameters and mask pixels, a real gradient,
four canonical and six noncanonical PAT formats, exact refusal statuses,
zero output handles, and source/catalog/folder preservation. Existing tests
whose names say stock can also choose created resources; the new generated
fixture establishes the parametric case explicitly. Directory snapshots prove
no lasting writes, not the absence of transient I/O. The source-specific
format gates were also reviewed directly against each native loader.

These backend runs do not exercise the forthcoming Duplicate controls, and
are separate from a final combined editor/bundle validation.
