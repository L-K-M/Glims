# Temporary hardware eraser (source candidate)

A matching tablet device in eraser proximity borrows Eraser for its next pointer
press. The user's selected tool is never replaced. Space takes Hand first,
Command takes Move next, then hardware eraser precedes the selected tool.
Option keeps the existing paint color-sampling behavior. Tool and brush remain
captured for the accepted drag, so a proximity flip/leave, brush edit or later
explicit tool choice cannot change the stroke in progress.

The first canvas installs one passive app-lifetime local event monitor. It
tracks device IDs for standalone tablet-proximity events and SDK-documented
mouse events with tablet-proximity subtype, behind exact type/subtype guards.
Device IDs use checked conversion. Proximity-only properties are never read
from tablet-point packets. Enter/leave updates are idempotent per device;
application deactivation clears them without restoring an old selected tool.
There is no document/window retention and no global OS setting change.

The existing mouse events with tablet-point subtype remain the only stroke
producer. Standalone tablet points may be queried for device matching but are
not dispatched again as paint. Mouse proximity-metadata packets are ignored
by canvas down/drag/up handlers; the monitor still returns the original event.
This avoids treating proximity as paint or feeding both representations twice.
Coalescing, extra axes, the facade and native adapter are unchanged.

Verification source, not executed: eight literal pure-policy tests and focused
`GLIMS_SMOKE_CASE=tablet-eraser-proximity` through the launched AppKit smoke
host (predicted21 successful checks). The fixture posts real synthetic public
CGEvent/NSEvent proximity packets through the passive monitor, independently
configures a native eraser on a separate RGBA red layer, and compares all raw
and merged pixels, one Undo, exact Undo/Redo. It also checks missing/nonmatching
IDs, ordinary mouse, both proximity forms, flip/leave during a drag, later
explicit tool choice, field typing, Space/Command/Option and synthetic app
deactivation. CGEvent device, coordinate and pressure admission is checked;
packet construction or routing failures must fail the fixture rather than
pretend the behavior passed.

No compiler, tests, native/app or GUI run has been performed for this candidate.
Actual synthetic-event routing, all-four engine behavior, combined Spring/menu
integration, physical tablet/driver behavior and independent review remain
Root-owned acceptance gates. No real hardware or richer-axis support is claimed.
