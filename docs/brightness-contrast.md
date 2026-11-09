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
