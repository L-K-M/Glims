# Keyboard shortcut override model and store

Scope of this slice (branch `feat/keyboard-shortcut-model`): the **pure value
model** (`Sources/GlimsKit/Shortcuts/KeyboardShortcutModel.swift`) and the
**persistent override store**
(`Sources/GlimsKit/Shortcuts/KeyboardShortcutOverrideStore.swift`), plus pure
XCTest coverage (`Tests/GlimsKitTests/KeyboardShortcutModelTests.swift`,
`Tests/GlimsKitTests/KeyboardShortcutOverrideStoreTests.swift`).

Not in this slice: any UI, menu integration or key-event handling, no engine,
C/header, native, dependency or shared-doc changes. The model never imports
AppKit and never serializes `NSEvent` values.

## Model

- `CommandShortcutEntry`: a command of the **caller-supplied catalog**.
  `id` is a stable identifier — a nonempty, unique string supplied by the
  caller, never a localized title (titles are a UI concern). `base` is the
  optional factory shortcut.
- `KeyboardShortcut`: a `ShortcutKey` plus `ShortcutModifiers`.
- `CommandShortcutOverride`: `.assign(shortcut)` or `.disable`. Removing the
  override entirely (`reset`) is a store operation, not a stored value.
- `KeyboardShortcutCatalog.effectiveShortcuts(overrides:)` resolves the
  **effective full catalog**: defaults plus overrides, disabled commands
  removed.

### Keys

A `ShortcutKey` is stored as Glims's own string:

- a single printable grapheme cluster, punctuation and symbols included;
  letters normalize to lower case ("A" and "a" are the same key — Shift is a
  modifier and distinguishes them). Empty, multi-grapheme, NUL/control,
  format, surrogate, private-use, unassigned and separator scalars are
  rejected.
- an AppKit function-key unicode scalar (0xF700...0xF8FF) mapped to an own
  tag ("f1"..."f35", "upArrow", "delete", "help", ...), so no AppKit constant
  is stored.

### Modifiers

`ShortcutModifiers` is Glims's own `OptionSet` (`command`, `shift`,
`option`, `control`), Codable as its own raw value. Stored values with bits
outside the four known modifiers (or negative) are rejected.

### Override rules

- An override must carry **Command or Control**, so it can never steal the
  canvas, text-editing or single-tool keys, which are plain keys. Factory
  bases may be plain keys.
- macOS reservations (below) are **reserved**: the command that owns one as
  its factory base keeps it, but no other command can claim it through an
  override.
- Conflicts are checked against the **effective full catalog** (defaults +
  overrides, disabled removed). An assignment **never silently unbinds**
  another command; the error names both commands.

### macOS reservations

| Shortcut | System meaning |
|---|---|
| ⌘H, ⌥⌘H | Hide / Hide Others |
| ⌘M, ⌥⌘M | Minimize / Minimize All |
| ⌘Q, ⇧⌘Q, ⌃⌘Q | Quit / Log Out / Lock Screen |
| ⌘Space, ⌥⌘Space | Spotlight / Spotlight search field |
| ⌘\`, ⇧⌘\` | Move focus to next / previous window |
| ⇧⌘3, ⇧⌘4, ⇧⌘5 | Screenshot / selection / options |

## Store

`KeyboardShortcutOverrideStore` owns the `editor.keyboardShortcutOverrides`
UserDefaults key, storing one schema-1 JSON document as `Data`:

```json
{"schemaVersion":1,"overrides":[
  {"command":"edit.undo","override":{"kind":"assign","shortcut":{"key":"u","modifiers":1}}},
  {"command":"tool.paintbrush","override":{"kind":"disable"}}]}
```

- Mutations (`assign`, `disable`, `reset`, `resetAll`) re-read the stored
  bytes, apply the change, validate the prospective set against the catalog
  and write the single encoded document back only if everything
  passes — a failed mutation leaves the stored bytes untouched. `resetAll`
  reads strictly before removing the key, so a corrupt document throws and is
  retained.
- Load is strict at every nesting level: unknown fields, a missing or
  unsupported schema version, wrong types, unknown kinds, invalid keys,
  unknown modifier bits, empty/control command ids and duplicate command ids
  (the overrides are an array precisely so duplicates are detectable) all
  **throw**; nothing is ever silently reset. An absent key is an empty store.
- Storage is one validated UserDefaults `Data` value; the store keeps no
  cache, so externally changed bytes are picked up by the next mutation.

### Catalog evolution (orphans)

When the catalog changes, stored overrides of commands it no longer knows are
**inactive orphans**: they load fine and are retained byte-for-byte by every
mutation — never dropped, never rewritten. They are ignored by
`effectiveShortcuts` until the command is **known again**, at which point the
stored override is revalidated (Command/Control, reservations, conflicts)
**before** it is applied; a conflict then fails the resolution and any
persisting mutation, naming both commands. `reset(_:catalog:)` removes an
orphan explicitly.

## Verification

`swift build` plus the filtered pure tests
(`swift test --filter KeyboardShortcut`) cover normalization, invalid keys,
modifier bits, default conflicts, disabled, reset, reservations, corrupt and
unknown-key documents, version handling, duplicate ids, orphans and failed
mutations preserving the store. Not covered: any UI/menu wiring (out of
scope), and end-to-end key-event delivery.


Reset validation follow-up: restoring a disabled command's default must
check the complete effective catalog too. A regression disabled Command-A,
assigned that key to another command, then reset the original command.
It first failed two assertions because reset persisted the conflict.
Reset and Reset All now require the catalog, and every mutation validates
before writing. All 38 focused model/store tests pass. UserDefaults does
not expose write failures or a crash-durability acknowledgment; those are
not guarantees of this store. No menus or settings UI use it yet.

Typed-modifier follow-up: source review found that typed assignments could
carry unknown bits even though decoding rejected them. Positive unknown
bits and a negative modifier value reproduced six failing assertions across
assignment, unchanged storage and base catalog construction. Both catalog
entry construction and override application now validate the same known-bit
mask. All 39 focused tests pass after the fix.

## Panel and menu integration (branch `feat/menu-shortcut-controls`)

This slice adds the **panel and the menu bridge only** — no native/C, no
plug-in, workspace or dynamic binding claims:

- `Sources/GlimsKit/Shortcuts/MenuShortcutBridge.swift` collects the
  built-in commands from a statically made `MainMenu`: every item created
  by `MainMenu.item(_:_:_:)` carries `builtinIdentifier`, and only marked
  items are collected — plug-in commands, workspaces and the recent list
  are never marked and stay out. A command's stable id is
  `NSStringFromSelector(action)` plus the item's final tag, never a
  localized title. An uppercase factory letter adds Shift in the canonical
  model base ("S" + ⌘ stays "S" + ⌘ on the item, s + ⌘⇧ in the model), so
  Save As… never collides with Save. An unmodified DEL (0x7F) has no model
  base; its factory snapshot still restores the item exactly. Factory
  snapshots keep the original `keyEquivalent`/`modifierMask` in memory
  only — raw AppKit flags are never serialized. Aliases sharing an id
  merge; disagreeing factory bases are a visible conflict, never a silent
  unbind.
- `Sources/GlimsKit/Shortcuts/MenuShortcutManager.swift` attaches **once**,
  from `AppController` after the real `NSApp.mainMenu` is installed
  (`MainMenu.make()` never attaches, applies or rewrites anything global).
  Mutations validate the full catalog and persist through the store
  **first**, then update the actual menu items and the panel — never the
  responder chain or targets. Load errors keep the factory menu and the
  stored bytes and surface when the panel opens; no auto-reset, no startup
  alert. macOS-reserved owners (Hide/Minimize/Quit/…) are read-only: no
  assign, disable or reset via the UI or stored data.
- `Sources/GlimsKit/Shortcuts/KeyboardShortcutsPanelController.swift` is the
  App ▸ Keyboard Shortcuts… panel: a searchable command list with menu
  path labels, a literal character key field, ⌘/⇧/⌥/⌃ checkboxes, a
  function-key picker exposing the model's key tags, and Assign / Disable /
  Reset Selected / Reset All / Close with a persistent error line. No
  global or event key capture. The manager retains one panel.
- `Sources/GlimsKit/EngineSmokeTestMenuShortcuts.swift` drives the panel
  with a private UserDefaults suite and an injected manager as the
  `menu-shortcuts` smoke case and in the default full run; it invokes one
  real NSMenu action and never sends Quit/Hide/Minimize.

Verification: `swift build --build-tests -j 2` plus the filtered pure tests
(`swift test --filter MenuShortcutManagerTests|KeyboardShortcut…`) cover
collection, ids, canonical bases, snapshots, reserved owners, aliases,
conflicts, persist-first ordering, corrupt stores, the single panel and
panel-driven assign/disable/reset. Not covered here: the engine smoke run
(needs a built engine) and any interactive GUI run.

### Controls acceptance

All 621 unit tests pass, including the three new factory-snapshot regressions
that first reproduced four failed assertions. Original snapshots now follow
each menu item's lifetime, preserving reset and corrupt-store recovery across
recollection and replacement managers. The independent source fix review
found no important issue. The real-controls smoke passes 41 checks, including
AppKit dispatch of Command-K and Command-Shift-K to separate safe targets.
The Shift event retains Shift in charactersIgnoringModifiers, matching
[Apple's event contract](https://developer.apple.com/documentation/appkit/nsevent/charactersignoringmodifiers).
No Quit, Hide, Minimize or Open dialog was invoked. Full integrated app smoke
and exact-head CI remain pending.
