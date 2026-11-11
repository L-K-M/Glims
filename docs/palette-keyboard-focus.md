# Explicit keyboard entry into palettes

Window menu palette commands now make the requested utility panel key and
enter its preferred responder or AppKit key-view loop. The document remains
the main window. Opening a document still shows its automatic palette layout
without transferring keyboard focus.

Glims uses Rigi's explicit `focusPanel()` API for all seven palette commands.
Automatic layout keeps `showPanel()`. Attached popovers close before a focus
transfer, and closing a palette cancels unfinished focus requests.

On 2026-11-11, the old application reproduced the Window > Recorder failure:
the real menu action dispatched and raised the panel, but the document stayed
key. The fixed normal application host passes 12 checks on each of the four
engines. Recorder becomes key with a usable Record/Stop button or table;
a real Tab event stays inside its panel; Layers and Tool Options accept
keyboard entry. Document pixels, Undo and main-window identity stay unchanged,
and owned panels, rendering and native image close during teardown.

Rigi's new API passes 143 native unit tests, Gallery smoke and a release
build. The consumer passes 1,220 unit tests before the separate filter-badge
AX integration. Local results are ephemeral under `/tmp/glims-completion/`,
with prefixes `text-restore-focused` and `palette-keyboard-23e6-full-units`.
The tests do not change the Mac's Full Keyboard Access preference and do not
establish a complete spoken VoiceOver or appearance audit.
