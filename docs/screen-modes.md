# Per-document screen modes

Windowed, Full Screen with Menu and Full Screen Bare are available in
View > Screen Mode and the Tools palette. Plain F cycles these modes while
the canvas owns keyboard input; text fields retain ordinary text entry.
An idle Escape returns an owned full-screen document to Windowed. Mode
changes refuse during an active canvas interaction, guide drag or stroke,
a sheet, closing or a native full-screen transition. Palette controls retain
their captured document.

The two owned modes expand the existing document window in place. Menu
mode reserves the menu strip, including the screen's safe top inset, and
keeps the menu visible; Bare fills the screen and auto-hides the menu.
Both auto-hide the Dock. They preserve the user's palette visibility.
Windowed restores the saved frame, style, collection behavior, movement
settings and focus policy. Presentation options belong to the active main
document and require an owned window snapshot; a palette or a native
full-screen callback cannot acquire that policy. Later external presentation
changes are retained as the restoration baseline.

Native green-button full screen remains AppKit-owned and separate from
these in-place modes. The fixture exercises actual `toggleFullScreen`
entry/exit callbacks and restoration. Rigi revision
`13ec06a508025a71234f708efd1e36aef85a88c4` supplies explicit borderless
document key/main eligibility; its default policy remains unchanged.
Because an untitled window has no title-bar close button, the document's
content responder routes normal nil-target File > Close through the existing
save/cancel/busy delegate flow while an owned snapshot exists. Windowed and
native windows retain the normal `window.performClose` fallback.

Validation uses production `f6fc288`, fixture `2197e71` and committed
dependency pin `cb0ee58`. The focused host completes real AppKit launch and
pumps native events. Its current 77 checks supersede the earlier 34/48-check
scope. They cover all three controls/modes, document ownership, frames and
presentation, visible menu policy, field-editor F, idle Escape, native
full-screen coexistence, synthetic cleared-style callback timing, close
admission and native pixel/Undo preservation. Both owned modes additionally
exercise real field editors and installed File menu validation, a known
native red edit, actual Cancel/Don't Save controls, exact pixel/history
preservation on Cancel and one close completion after native image draining.
A clean titled field-editor Close verifies the normal fallback.

| Recorded run | Result |
| --- | --- |
| GIMP 3.2.8 | 77 checks, zero failures |
| GIMP 3.2.0 | 77 checks, zero failures |
| GIMP 3.0.8 | 77 checks, zero failures |
| Reviewed master engine set | 77 checks, zero failures |
| Full XCTest run | 1,025 tests, zero failures |

All five recorded processes exited zero and released the desktop. Each
immediate post-run screen/AX observation succeeded, reported Finder with
`is_dialog=false`, and had no observation warnings. These are observations,
not a complete process/window inventory or a full accessibility audit.
The fixture separately verifies that all its native images close and no
owned dialog or palette remains. Local aggregate evidence and artifact
hashes are in `/tmp/glims-completion/screen-mode-publication-evidence.json`;
the unit log is `screen-2197e71-field-close-units.04ZxCo/tests.log` there.
The pinned focused run is `screen-2197e71-field-close-ui.iaNDIn`.

Earlier failures remain evidence: the native-Space approach failed its
visible-menu assertion in the 26-check run `screen-modes-ui.RNMygQ`.
The separate external pixel-capture handshake timed out in
`screen-modes-ui.3JOncr`; a later capture outside the owned desktop lease
was not accepted as proof. That implementation was replaced by the owned
modes. The `deafa3c` Close diagnostic dispatched to a bare NSWindow with
style2 and no close button but never began closing; its timeout and
incomplete-scenario failures remain in `screen-owner-close-diag-ui.5xIPCg`.
The content-responder correction and expanded 77-check runs address that
observed route, rather than treating dispatch success as closure.

This is a focused AppKit event/control result, not physical keyboard, mouse,
trackpad or green-button testing. Multi-display movement/hot-plug, additional
notched-display configurations, screen-reader behavior, all appearance and
layout combinations, and final combined self-contained release validation
remain outside it. The dirty cases cover Cancel/Don't Save; existing file
safety tests cover Save failure and busy gates, without new screen-mode
coverage claims for those workflows. Hosted CI, completed PR review and
integration at the final combined revision remain pending. No engine API,
image-pixel operation or native source patch is added by screen modes.
