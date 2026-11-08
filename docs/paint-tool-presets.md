# Paint tool presets: value model and persistent CRUD store

Scope of this slice (branch `feat/tool-preset-model`): the **value model**
(`Sources/GlimsKit/Tools/PaintToolPreset.swift`) and the **persistent CRUD
store** (`Sources/GlimsKit/Tools/PaintToolPresetStore.swift`), plus focused
compile-only tests (`Tests/GlimsKitTests/PaintToolPresetTests.swift`).

Not in this slice: any UI, and any behavior that applies a preset to
`ToolState` or to a stroke. No engine, C/header, native, dependency, Rigi
or shared-doc changes.

## Value model

A preset is an owned, named, UUID-identified **immutable** value
(`PaintToolPreset`, all fields `let`; rename/replace build a new value with
the same UUID). It belongs to exactly one paint-tool `ToolID`
(`tool.paintTool != nil`; the engine paint tool behind it is derived from
the tool, so `EngineSession.Brush.Tool` is not stored separately).

Captured stable `EngineSession.Brush` settings (`PaintToolPreset.Settings`):
`size`, `opacity`, `pressureSize`, `hardness`, `rate`, `flow`, `exposure`,
`tones`, `antiErase`. `hardness`/`rate`/`flow`/`exposure` stay optional, nil
meaning "the engine's default", exactly as in `Brush`. Additionally:

- `brushResource`: an optional typed wrapper around
  `EngineSession.ResourceIdentity`. The identity itself carries no resource
  kind, so `PaintToolPreset.BrushResource` pins a `kind` tag to `brush`;
  the identity is meant to be resolved with
  `EngineSession.resolveResource(_:kind: .brush)`. A persisted kind tag
  other than `"brush"` is rejected, never reinterpreted. No session
  `ResourceID` handle is ever stored. The identity keeps the NULL/empty
  collection distinction (`ResourceIdentityTests`).
- `foregroundColor`: an optional, deliberate, explicit schema field
  (`PaintToolPreset.SRGBColor`) holding the foreground color as sRGB
  components.

Deliberately **not** captured (transient or session-local):

- `EngineSession.Brush.Source` / `ToolState.cloneSource`: the clone/heal
  source point is a native drawable id plus coordinates in that image.
  **Limitation:** a clone/heal preset does not restore its source point;
  applying a preset leaves the current source point unchanged.
  This is documented here rather than pretending it is restored.
- Session `ResourceID` handles, native drawable IDs, transient target
  coordinates.

Persisted tags are Glims's own strings (`"paintbrush"`, `"shadows"`, …),
never the engine's raw enum numbers (`glims_engine.h` values never cross
into storage).

## Accepted limits and their sources

| Field | Accepted | Source |
|---|---|---|
| `size` | finite, `1 <= size <= 10000` px | native `gimppaintoptions.c` brush-size GParamSpec minimum 1 and `GIMP_BRUSH_MAX_SIZE` 10000, checked on all supported engines |
| `opacity`, `hardness`, sRGB components | finite, `0...1` | `glims_engine.h` (`opacity 0...1`, `hardness 0...1`, `red/green/blue` "sRGB, 0...1"); `Engine/paint.c` clamps opacity to `0...1`; UI sliders 0...100% |
| `rate`, `flow`, `exposure` | finite, `0...100` (or nil) | `glims_engine.h` ("0 ... 100"); UI sliders `0...100` |
| name | trimmed, nonempty, ≤ 64 characters | this store's own rule (`PaintToolPresetLimits.maxNameLength`) |

All numeric validation also requires finite values (no NaN/infinity).

## Persistence schema (version 1)

One UserDefaults key, `editor.paintToolPresets`, holding one JSON document:

```json
{
  "schemaVersion": 1,
  "presets": [
    {
      "id": "UUID",
      "tool": "paintbrush",
      "name": "Soft",
      "settings": {"size": 12, "opacity": 1, "pressureSize": true,
                   "hardness": 0.5, "rate": 50, "flow": 10, "exposure": 50,
                   "tones": "midtones", "antiErase": false},
      "brushResource": {"kind": "brush",
                        "identity": {"name": "2. Hardness 025", "isInternal": false}},
      "foregroundColor": {"red": 0.25, "green": 0.5, "blue": 0.75}
    }
  ]
}
```

Optional fields (`hardness`, `rate`, `flow`, `exposure`, `brushResource`,
`foregroundColor`, and the identity's `collection`) persist as **absent
keys** when nil, the same convention as `ResourceIdentity.collection`; an
explicit JSON `null` decodes to nil. Encoding uses sorted keys; the preset
array order is the stored order.

Like `BrushSelectionStore`, the store is pure value storage: tests inject a
suite's `UserDefaults`, the app uses `PaintToolPresetStore.shared`.

## Store semantics

- **Order:** deterministic creation order; create appends, rename/replace
  keep the position, delete removes.
- **Identity:** every preset keeps its UUID across rename, replace and
  delete; snapshots are immutable values (no mutable aliases).
- **Names:** stored trimmed; must be nonempty after trimming and at most 64
  characters. **Duplicates:** a name must be unique within one tool (exact
  match on the stored trimmed name); the same name on a different tool is
  allowed. Violations throw `duplicateName`.
- **Errors:** every failure throws an actionable `PaintToolPresetError`
  (unknown tool tag, non-paint tool, unknown tone tag, empty/overlong/
  duplicate name, unknown preset UUID, non-finite or out-of-range field,
  invalid resource kind/identity, unsupported/missing schema version,
  malformed document). Unknown/malformed `tool` tags and non-paint `ToolID`s
  are rejected at both creation and decoding.

## Compatibility, corruption and atomicity policy

- **Unknown fields:** reject them at every object boundary, including
  resource identities and nested settings. The original bytes stay intact;
  a compatible reader is required. This prevents both dropped fields and
  numeric precision loss during a rewrite. Extensions require a new schema.
- **Unknown schema / corrupt data:** a stored document whose
  `schemaVersion` is missing or not 1, or whose bytes are unreadable,
  makes `load()` and every mutation **throw** — never silently reset to an
  empty collection, and never clobber the stored bytes.
- **Atomicity:** each mutation re-reads the stored bytes (so externally
  changed data is picked up while it is readable), validates the new
  document in memory, encodes it, and only then writes the single key. Any
  load, validation or encoding failure throws **before** the write, so the
  previously stored bytes and the snapshot they decode to are untouched.
  The store owns its key exclusively; a document it cannot read (e.g. a
  future schema written by a newer version) makes mutations fail rather
  than overwrite.

## Verification status

Compiled in this slice: `swift build -j 2 --build-tests` (see the commit).
**Not run here:** `swift test` and any other runtime/unit execution, engine
or adapter builds, smoke tests, GUI runs — root owns serialized test
execution. The tests are compile-checked only; their runtime results were
not observed in this slice.

Root acceptance reproduced 26 storage failures before correction: unfamiliar
fields could be dropped, a wrong-typed defaults value could be overwritten,
reset deleted unreadable data, and duplicate preset identifiers/names were
accepted. Strict schema-one decoding now rejects every unknown object key,
including nested identities, and all mutations (including reset) validate
the original document first. Duplicate identifiers and per-tool names are
validated on load as well as mutation. Numeric limits use native 1–10,000 px
brush size rather than the Tool Options slider's smaller offered range.

Runtime verification: the two new storage regressions failed with 26
assertions before correction. All 17 focused model/store tests now pass,
including exact byte preservation for unfamiliar fields at every nesting
level, duplicate UUIDs and names, wrong-typed defaults, corrupt data and
reset. These are pure tests; no preset application or on-screen controls
are claimed by this slice. UI work is separate.
