# Native Lab channel editing

The candidate adds a coherent first Lab workflow: New Image offers D50 Lab
at U8, U16 or physical float precision when the engine supplies creation,
typed axis metadata and physical Fill. Channels selects exactly one captured
L*, a* or b* axis. Edit > Fill accepts physical values and opacity, preserves
the other planes, and creates one Undo step for a changed edit. Save, Save a
Copy, reopen, Undo/Redo and recovery use the native XCF document path.

The additive facade operation `image_fill_lab` captures the current axis ID,
canonical role and UUID. Both admission and final publication validate that
identity. Existing component-edit staging supplies selection snapshots,
bounded rows, cancellation, exact Undo and damage notification. The private
row kernel preserves zero-weight bytes, blends physical binary64 values,
then quantizes once through the Lab codec. See `lab-fill.md` for the numeric
contract; this is not a Photoshop numeric-equivalence claim.

Lab documents never expose an ordinary RGB/ink paint target. Unsupported
paint, filter, layer, clipboard, export and Recorder commands remain refused
at UI and service boundaries. Hand and Zoom remain available. Retargeting an
ordinary document restores its ordinary controls. Lab Brush, composited Lab
layers, conversion and external interchange remain unfinished.

Recovery transfers ownership of the validated native Lab image because its
native duplicate operation is unavailable. A recovered document stays
unsaved even when its opened XCF reports clean; only successful native Save
assigns a new save destination and clears that state. This explicit recovered
state also protects ordinary recovered documents across later reloads.

Qualification so far: all four engines pass 1,143 native Fill checks and 306
policy checks, with 1,314 existing ink-edit regression checks per engine.
The pure kernel passes 2,998 optimized and sanitized checks each. The initial
full Swift suite passed 1,577 tests after correcting ordinary palette
visibility. Independent native, workflow and UI-gating reviews are clear
after the shared exclusive-edit unsaved-accounting correction. The real
three-precision Lab UI fixture covers creation, axis selection, invalid and
stale Fill drafts, Cancel, one Undo, Redo, XCF reopening, tool restoration and
Close-during-Fill save confirmation. A six-point inset keeps complete native
radio controls inside the palette. Recovery and integrated latest-source UI,
unit, bundle and launch qualification are still running.
