# Temporary hardware eraser

A matching tablet device in eraser proximity borrows Eraser for its next pointer
press. The user's selected tool is never replaced. Space takes Hand first,
Command takes Move next, then hardware eraser precedes the selected tool.
Option keeps the existing paint color-sampling behavior. Tool and brush remain
captured for the accepted drag, so a proximity flip/leave, brush edit or later
explicit tool choice cannot change the stroke in progress.

The first canvas installs one passive app-lifetime local event monitor. It
tracks device IDs for standalone tablet-proximity events and SDK-documented
mouse events with tablet-proximity subtype, behind exact type/subtype guards.
Tracking enter/exit and cursor-update events are excluded before reading the
mouse-only subtype property. Device IDs use checked conversion. Proximity-only
properties are never read from tablet-point packets. Enter/leave updates are
idempotent per device;
application deactivation clears them without restoring an old selected tool.
There is no document/window retention and no global OS setting change.

The existing mouse events with tablet-point subtype remain the only stroke
producer. Standalone tablet points may be queried for device matching but are
not dispatched again as paint. Mouse proximity-metadata packets are ignored
by canvas down/drag/up handlers; the monitor still returns the original event.
This avoids treating proximity as paint or feeding both representations twice.
Coalescing, extra axes, the facade and native adapter are unchanged.

Verification at production commit `ca815e1` (2026-11-10): the launched AppKit
`GLIMS_SMOKE_CASE=tablet-eraser-proximity` case passed all 21 checks on each of
the four engine sets. The fixture posts synthetic public CGEvent/NSEvent
proximity packets through the passive monitor, independently configures a
native eraser on a separate RGBA red layer, and compares all raw and merged
pixels, one Undo and exact Undo/Redo. It also verifies missing/nonmatching IDs,
ordinary mouse, both proximity forms, flip/leave during a drag, later explicit
tool choice, field typing, Space/Command/Option and synthetic app deactivation.
Packet construction and routing have explicit admission checks.

| Engine | Saved run | Focused result | Recorded exit |
| --- | --- | --- | --- |
| GIMP 3.2.8 | `tablet-eraser-ca815-ui.WG8U8y` | 21 checks, 0 failures | 0 |
| GIMP 3.2.0 | `tablet-eraser-ca815-ui.ajMSu0` | 21 checks, 0 failures | 0 |
| GIMP 3.0.8 | `tablet-eraser-ca815-ui.mdghCs` | 21 checks, 0 failures | 0 |
| master | `tablet-eraser-ca815-ui.Clz8bP` | 21 checks, 0 failures | 0 |

The private full-unit run `tablet-ca815-full-units.lJ3l2a` passed 1,059 tests,
including all nine tablet policy/event-guard tests, and exited 0. These are
saved Root-run results; the documentation/receipt aggregation did not execute
new tests. The original source freeze at `074cdd4` remains historical evidence,
not a current execution claim.

That original revision passed eight policy tests but its first focused launch
stopped after one successful check without a final result or exit receipt. A
separate diagnostic attempt timed out and recorded forced termination (143).
Its unified log identified `NSInternalInconsistencyException` from reading
`NSEvent.subtype` on a tracking event in the passive monitor. `ca815e1` excludes
those event types in both the monitor mask and classifier and adds a real
enter/exit-event regression. The initial source review did not catch this
fault; it does not approve the corrected revision. The separate correction
review and the successful runtime evidence retain their own scopes.

Every focused run has an exit-0 receipt, desktop-release acknowledgment and a
successful immediate post-run AX capture reporting no frontmost dialog. The
full-unit run also has exit-0 and release receipts, but its immediate AX capture
failed with `WINDOW_NOT_FOUND` for PID 60647. A successful follow-up desktop
capture is not established by these receipts. Nonempty launcher/engine
messages are preserved, including the sandbox-extension warning, GIMP 3.2.0
`g_file_test` assertions, GIMP 3.0.8 wire EOF warnings and master's missing
cached-XML diagnostics; this evidence is not a clean-stderr claim.

The saved logs, launch/engine bindings, source and receipt hashes are aggregated
in `/tmp/glims-completion/tablet-ca815-verified-evidence.json`. The original `074cdd4`
logs and source freeze are retained there separately. Physical tablet/driver
behavior, combined Spring/menu/screen integration, latest-head CI, publication
review and merge remain open. No real hardware or richer-axis support is
claimed, and the full-unit immediate AX gap remains explicit.
