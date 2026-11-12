# Native Brightness/Contrast

The exact native brightness/contrast operation has a dedicated modeless
editor. Percent fields and sliders edit a complete normalized pair, with
inline validation and errors. Apply commits pending field text first;
Cancel restores the original image. Committed effect parameters reopen in
the same editor and preserve their effect identity, position and blend state.
Other custom-config operations retain their gates.

API v1 appends slots 148/149 and a sized pair of owned doubles. A default
native config is installed before first Apply. Changed writes duplicate
all settings before replacing the preview's config; installed configs are
immutable, so old committed/Undo states cannot be changed by the shadow.
Begin refuses an active stroke/preview, and Begin/Edit/Commit require enabled,
unfrozen native Undo with no outer group. A refused Commit remains cancellable.

The adapter uses the real Core point-filter field with ordinary object
ownership and operation notification for this exact operation. All four
pinned native property setters retain an extra reference; no compensating
unrefs or upstream modifications are used. Native Undo/XCF paths still have
that upstream retention limitation. Pre-Undo adapter replacement and Abort
have independent weak-reference finalization checks.

The dedicated harness passes 177 checks on every supported engine, including
independent linear-float RGB/alpha arithmetic, invalid/no-op pairs, source
ownership, new/existing Apply/Cancel/Undo/Redo, base settings and blend/order,
XCF pixels/settings, busy/history guards and public sized marshalling.
The real editor passes 15 checks per engine through actual controls, last-field
Apply, captured-document preview, Cancel, effect editing, Undo/Redo and XCF.
An observed admission failure (four assertions) was fixed before these green
runs. Native and Swift integration source reviews have no important remaining
finding; the panel implementation was reviewed by Root and exercised at runtime.
Full integrated unit/bundle checks and final review remain separate gates.


The expanded reply-order checks first reproduced two submitted-edit failures
and then two actual field-editor failures. A refused pair now immediately
stops being the base of later writes. Shared field-draft preservation keeps
text and selection entered after the last display/submission when a delayed
reply refreshes accepted values. Twenty actual-window checks pass on each
supported engine. The verified Brightness/Contrast bundle passes 1,917
native and 2,457 app checks with the build trees inaccessible.
The unchanged native module retains its177-per-engine evidence.

## Recorder

A committed newly applied Brightness/Contrast adjustment on an explicitly bound
ordinary layer can be recorded. Recorder stores the complete accepted native
brightness and contrast values at Apply, writes version 10 only when such a
successful command is present, and replays by installing the same whole settings
on the chosen rebound layer with one Undo step. Preview updates, Cancel, refused
Apply and unsupported targets (including mask/channel edits and existing-effect
edits) never produce a successful recorded Brightness/Contrast row.
