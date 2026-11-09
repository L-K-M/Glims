# Resource pixel creation (slot 129)

One bounded native+Swift slice: `resource_create_pixels` builds ONE saved
bitmap resource — a brush or a pattern — from owned straight-alpha RGBA
pixels (a `ClipboardImage`'s buffer) and publishes it to the engine's own
resource catalog. No UI, no clone/rename/delete/gradient creation.

## Facade and API tracking

- Append-only slot **129**, appended after `image_metadata_tag_info`
  (slot 128) at the end of `GlimsEngineAPI`
  (`Sources/CGlimsEngine/include/glims_engine.h`). The table now holds
  **129 function slots**; `api_version` stays `GLIMS_ENGINE_API_VERSION`
  = 1 and `struct_size` grows with the appended pointer, exactly the
  established additive rule: no existing layout, signature or enum value
  changed, no footer entry reordered. `Sources/CGlimsEngine/abi.c`'s
  assert still stands.
- Signature (facade types, no narrowing — the id is a full
  `GlimsResourceID` = `uint64_t`, the byte count a `size_t`, like
  `image_paste_pixels`):

  ```c
  GlimsStatus (*resource_create_pixels) (GlimsEngine *engine, uint32_t kind,
                                         const char *name, int32_t width, int32_t height,
                                         const uint8_t *pixels, size_t byte_count,
                                         uint32_t brush_spacing, GlimsResourceID *outID,
                                         char **error);
  ```

  Task parameter names map as: resourceKind=`kind`, constRGBAbytes=`pixels`,
  exact byteCount=`byte_count`, brushSpacing=`brush_spacing`.
- Adapter: `Engine/resource-create.c` (new, picked up by the
  `Engine/*.c` glob in `scripts/build-adapter.sh`), prototype in
  `Engine/engine-private.h`, bridge `GlimsResourceCreateArgs` +
  `api_resource_create_pixels` appended in `Engine/engine.c`.
- Swift: `EngineSession.createResource(kind:name:pixels:brushSpacing:)`
  plus the pure pre-RPC gate `EngineSession.validateResourceCreation`
  (`Sources/GlimsKit/Engine/EngineSession.swift`), tests in
  `Tests/GlimsKitTests/ResourceCreationInputTests.swift`.

## Contract

All validation happens before any mutation; `outID` is zeroed first and
again on EVERY failure, including missing-output and error paths.

| Input | Rule | Refusal |
|---|---|---|
| `outID` | required | INVALID_ARGUMENT |
| `kind` | BRUSH(1)/PATTERN(2) only; GRADIENT(3) has no pixel conversion; other values unknown | UNSUPPORTED / INVALID_ARGUMENT |
| `name` | nonempty valid UTF-8, no embedded NUL (rejected Swift-side before the bridge; a C string cannot carry one), no control characters (Unicode Cc, = `g_unichar_iscntrl`), ≤ 255 UTF-8 bytes (native 256-byte label incl. NUL) | INVALID_ARGUMENT |
| `width`, `height` | 1 … 10000 each (native bound) | INVALID_ARGUMENT |
| `pixels`, `byte_count` | `pixels` non-NULL and `byte_count` exactly `width*height*4`, checked in overflow-safe 64-bit arithmetic, ≤ the facade's 512 MiB pixel cap | INVALID_ARGUMENT |
| `brush_spacing` | brush: 1 … 1000; pattern: exactly 0 | INVALID_ARGUMENT |
| engine state | no image argument; refuses when `engine->busy > 0` OR any stroke OR any filter session is active (any image) | BUSY |
| name collision | exact-name match against current factory membership, checked before any write (the loader factories run unique-names=TRUE and would silently uniquify) | FAILED, never uniquified |

Success: the resource is persisted to disk, a member of the factory with
the exact requested name, and `outID` is its positive opaque native data
id — usable with `resources()`, `resource_identifiers()`,
`resource_resolve()`, `resource_thumbnail()`,
`stroke_begin_with_brush_resource()` and `fill_pattern()` like any
catalog handle. No image, undo history, user context, global clipboard or
shared native data is changed.

## Native design, with source citations

All citations are against the pinned tree
`_engine/src/GIMP_3_2_8/gimp` (read from the main checkout; this
worktree has no `_engine/`).

1. **Private brush from owned pixels, no private field writes.** The
   straight RGBA source is serialized as a GBR v2 file — big-endian
   7×uint32 header (`header_size`, version=2, width, height, bytes=4,
   `GIMP_BRUSH_MAGIC`, spacing), NUL-terminated UTF-8 name, tightly packed
   `width*height*4` payload (`gimpbrush-header.h:27-44`) — into a private
   seekable `GMemoryInputStream` and loaded with
   `gimp_brush_load_brush()` (`gimpbrush-load.h:31-34`, impl
   `gimpbrush-load.c:119`). For bytes=4 the loader copies RGB into its
   owned `R'G'B' u8` pixmap and alpha into its owned `Y u8` mask
   (`gimpbrush-load.c:389-419`) and takes the spacing from the header
   (`gimpbrush-load.c:441`); the writer recombines without
   premultiplication on save (`gimpbrush-save.c:40-99`). Dimension bound
   enforced by the loader too (`gimpbrush-load.c:180-185`,
   `GIMP_BRUSH_MAX_SIZE` 10000, `gimpbrush-header.h:25`); name bound
   `GIMP_BRUSH_MAX_NAME` 256 incl. NUL (`gimpbrush-header.h:26`) is why
   the facade caps the label at 255 bytes. The `GFile` passed to the
   loader is identity/error context only — never opened by it.
2. **Private pattern.** `g_object_new (GIMP_TYPE_PATTERN, "name", name,
   "mime-type", "image/x-gimp-pat", NULL)` with an owned
   `gimp_temp_buf_new (w, h, babl_format ("R'G'B'A u8"))` whose tightly
   packed storage (`gimptempbuf.c:64-89`, `gegl_malloc(w*h*bpp)` at :84)
   gets a straight copy of the source rows, assigned to the public
   `pattern->mask` field on the new private object only
   (`gimppattern.h:33-38`; finalize unrefs it, `gimppattern.c:107-113`).
   PAT save writes header+name+mask and supports R'G'B'A
   (`gimppattern-save.c`, `GIMP_PATTERN_MAX_SIZE` 10000,
   `gimppattern-header.h:23`). The pattern factory has NULL new_func
   (`gimp-data-factories.c:143-181`), so the lower-level constructor is
   the only route — which is what this slice uses.
3. **No factory convenience calls.** `gimp_data_factory_data_new` /
   `data_duplicate` save unchecked and only `g_critical` on failure
   (`gimpdatafactory.c:494,736`), so they are not used.
4. **Save folder.** `gimp_data_factory_get_save_dir` is static
   (`gimpdatafactory.c:1000-1091`) and cannot be called, so the adapter
   reproduces exactly its verified chooser with the public owned-list
   getters `gimp_data_factory_get_data_path` / `_writable`
   (`gimpdatafactory.c:925-965`): first configured writable-path entry
   that is also in the search path (matched with `gimp_file_compare`,
   `gimp-utils.h:92`) and exists or can be created as a directory
   (`g_file_make_directory_with_parents` + `g_file_query_file_type`).
   No arbitrary HOME fallback, no configuration mutation. Both lists
   are released with `g_list_free_full (…, g_object_unref)`.
5. **Staged, checked save, promote, publish.**
   - Stage: a unique hidden subdirectory `.glims-stage-<uuid>` is created
     in the save folder. The native loader enumerates children with
     `G_FILE_ATTRIBUTE_STANDARD_IS_HIDDEN` and skips hidden entries
     *before* recursing into directories
     (`gimpdataloaderfactory.c:370,385-390`), so the staging directory
     is source-proven to be ignored by the loader.
   - `gimp_data_set_file (data, staging_file, TRUE, TRUE)`
     (`gimpdata.c:863`), then `gimp_data_is_writable` must hold
     (`gimpdata.c:1194`).
   - Checked `gimp_data_save` (`gimpdata.c:614-699`): `g_file_replace`,
     the class save vfunc AND the stream close must both succeed
     (`:639,645,649`) — a vfunc or close failure refuses.
   - Promote: `g_file_move (staging_file, final_file,
     G_FILE_COPY_NO_FALLBACK_FOR_MOVE, …)` to a unique-UUID final name
     with the native extension (`.gbr` `gimpbrush-load.h:21`, `.pat`
     `gimppattern-load.h:21`; loader extension match is case-insensitive
     `gimputils.c gimp_file_has_extension`) — a real rename only, and
     with no OVERWRITE flag an existing target fails instead of being
     replaced.
   - Reassociate with `gimp_data_set_file (data, final_file, TRUE, TRUE)`,
     validate `gimp_data_is_writable` again, then publish:
     `gimp_container_add` (`gimpcontainer.h:92`), verify membership
     (`gimp_container_have`), the exact name (the container must not have
     uniquified), and a positive `gimp_data_get_id` (`gimpdata.c:587`)
     before `*outID` is set.
   - Cleanup deletes ONLY this call's own staging file/dir and, on
     failure only, the final file. No all-or-nothing multi-step
     filesystem transaction or general rollback is promised beyond these
     actual cleanup steps; name-collision, busy and bad-argument
     refusals happen before any file or factory write, so they cannot
     modify existing files or catalog resources.
6. **Ownership.** Every GError path goes through `glims_fail`, which
   consumes the error — local `gerror` variables are transferred with
   `g_steal_pointer`. The GBR `GBytes`/stream, the private
   `GimpContext` (parentless, so the user context is untouched), the
   staging/final `GFile`s and the private data object are all released on
   every path; after publication the container's own reference remains
   and the local one is dropped.

## Swift side

`createResource(kind:name:pixels:brushSpacing:)` validates the typed
inputs through the pure `validateResourceCreation` (same rules as the
table above, with `multipliedReportingOverflow` for the byte count and
`generalCategory == .control` for control characters) BEFORE the RPC,
then passes the `ClipboardImage` buffer via `withUnsafeBytes` only for
the duration of the synchronous engine call — the same engine-worker
convention as `pastePixels`/`newImage`; the engine copies what it needs
before returning. It returns the positive handle, which existing read
APIs (`resources`, `resourceIdentifiers`, `resolveResource`,
`resourceThumbnail`) consume unchanged.

## Acceptance checks

The native adapter and general conformance suites pass on all four supported
engines. The standalone resource harness also passes on every engine,
including creation, exact saved GBR/PAT bytes, caller-buffer ownership,
identifiers/thumbnails, global busy refusals, unchanged image/history and
native clipboard state, and persistence after a fresh engine process.

The original helper draft did not compile natively because its move call
omitted an argument. After that correction, fault injection reproduced nine
failures from a wrong gradient status and deletion of preexisting collision
sentinels. Cleanup now requires successful staging creation or promotion;
gradient creation returns UNSUPPORTED. The configured-folder chooser also
releases its expected mkdir error when the directory already exists.

Independent source review found one more output-contract error: dispatch
without an engine bypassed the implementation's output reset. A real facade
test reproduced that failure; the public bridge now clears the handle before
dispatch. The final four-engine runs include this regression. Swift units
and build checks pass; the PR records current integration counts.

This is a backend and wrapper. Creation controls, duplicate/rename/delete,
selection capture and gradient creation are separate work.

## Documented native test procedure (for Root to run later)

A modular C harness was not added (it could not be compile-checked here,
and an unverifiable test file would be a fake oracle), so the procedure
below is the documented alternative. It drives the facade only, in the
style of `Engine/tests/engine-tests.c` (`glims-engine-tests LIBRARY
WORK_DIR FIXTURES_DIR` with a throwaway `HOME`/`GIMP3_DIRECTORY`):

1. **Source pixel/alpha exactness, brush and pattern.** Create a 3×2
   image via `image_new`/`image_from_pixels` is NOT needed — call
   `resource_create_pixels` directly with a known 3×2 RGBA buffer (e.g.
   pixels `{(255,0,0,255),(0,255,0,128),…}`). Expect OK, `outID > 0`.
   Then `resources(GLIMS_RESOURCE_BRUSH)` contains a row with `outID`
   and the exact name; `resource_identifiers(outID)` returns the same
   name, non-internal; `resource_thumbnail(outID, 512, …)` pixels equal
   the source RGBA (brush thumbnail renders pixmap+mask recombined).
   Repeat with `kind=PATTERN`, `brush_spacing=0`; thumbnail pixels must
   equal the source RGBA exactly. Check `gimp_brush_get_spacing` via a
   stroke or the saved file header equals the requested spacing.
2. **Persistence / reload / identity.** Note the writable data folder
   under WORK_DIR (the engine's `GIMP3_DIRECTORY`). Stop the engine,
   start a fresh one with the same directories, and check
   `resource_resolve(kind, name, collection, internal)` from the
   step-1 identifiers returns a positive id and
   `resource_thumbnail` still returns the exact source pixels (the
   `.gbr`/`.pat` file was loaded from the search path). Also verify the
   final file on disk carries a UUID name with the correct extension and
   that no `.glims-stage-*` directory remains.
3. **Image/history unchanged.** Open an image, read `image_undo_info`
   and `image_layers` before and after a successful create: identical.
   The call takes no image id at all.
4. **Refusals, each with `outID == 0` afterwards and no catalog/file
   change:** duplicate exact name (FAILED); gradient kind (UNSUPPORTED);
   unknown kind 99 (INVALID_ARGUMENT); NULL name, empty name, 256-byte
   name, control-char name (`"a\nb"`), non-UTF-8 bytes (INVALID_ARGUMENT);
   width/height 0 or 10001; `byte_count` off by one; NULL pixels;
   brush spacing 0/1001; pattern spacing 1 (all INVALID_ARGUMENT).
   BUSY: begin a stroke (`stroke_begin`) on an image, then call create —
   expect BUSY with outID 0; also with an open filter session
   (`filter_begin`). Missing `outID` pointer is INVALID_ARGUMENT.
5. **Forced failure injection** (chmod the save folder read-only, or make
   the final name exist): create must refuse, `outID` 0, the factory
   unchanged (`resources` count and names identical), no existing file
   overwritten (mtime/content of a pre-placed file unchanged), and no
   staging leftovers (no `.glims-stage-*` entries, no UUID files added).
6. **Hidden staging is loader-ignored** (source-proven at
   `gimpdataloaderfactory.c:370,385-390`; confirm at runtime by pointing
   a writable path at a folder containing a hidden `.glims-stage-x`
   directory with a valid GBR inside: after a factory refresh it must
   NOT appear in `resources()`).

## Remaining scope and limits

The tests use isolated configured writable folders. They do not establish
atomicity against arbitrary concurrent external filesystem changes or cover
every save/stream-close failure. The checked save precedes publication,
failed collisions preserve preexisting paths, and only paths acquired by
this call are cleanup candidates. Source review and the runtime matrix do
not replace final integrated app/bundle verification.
