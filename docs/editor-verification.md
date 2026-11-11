# Editor verification, 2026-11-11

The implementation merged in [#198](https://github.com/L-K-M/Glims/pull/198)
opens, edits, saves and exports real images through the bundled native engine.
It includes the finite editor scope in [the completion ledger](completion.md);
it does not promise every GIMP feature. The implementation revision is
`9490d733fc548fcd2434259de5250fd4d144ae8e`; merge `e6a924b` has identical
production, dependency, script, test and resource inputs. The final Help
follow-up corrects obsolete mask and Preferences descriptions; executable
behavior is unchanged.

## Automated checks

| Check | Result |
| --- | --- |
| Combined AppKit unit suite | 1,249 tests, zero failures |
| Ordinary editor workflow, GIMP 3.2.8 | 3,298 checks, exit 0 |
| Ordinary editor workflow, GIMP 3.2.0 | 3,298 checks, exit 0 |
| Ordinary editor workflow, GIMP 3.0.8 | 3,272 applicable checks, exit 0 |
| Ordinary editor workflow, master | 3,298 checks, exit 0 |
| Native conformance, four engines | 7,454 checks, zero failures |
| Codec conformance, four engines | 136 checks, zero failures |
| Dedicated fractional sampling, four engines | 480 checks, zero failures |
| Actual wide-gamut picker workflows, four engines | 48 checks, zero failures |
| Standalone pinned release app | 1,917 native and 3,298 editor checks |

The standalone check removes the engine override and denies reads and writes
to the engine, dependency and Swift build trees. It checks the bundled
adapter and ordinary editor workflows. Fresh canonical adapters rebuilt from
merged Main pass native and codec checks on all four engines too.

The status fixture reproduced minimum-window overflow before fixing it. The
color-menu regression reproduced seven failures before the foreground and
background commands were added. Independent per-slice, integration and menu
follow-up source reviews found no important issues. Source review and runtime
execution are separate evidence. Optional LongCat copy-audit and SWE-2 startup
diagnosis invocations timed out without completed reports; neither counts as approval.

All four GIMP, GEGL and babl source trees remained unchanged. Rigi is pinned to
merged `3f277226df3b5b66c5198d4cb4acd64fc14fe544`, with its own 154 tests,
gallery smoke, release build and CI passing before adoption.

## Ordinary app checks

The release app launched through Launch Services with a private test home and
no engine override. The on-screen checks established:

- The swatch opened the modeless color editor. Entering `0.123456789` displayed
  that Float value and Percent `12.3456789` without byte quantization.
- A pointer stroke changed real image pixels. The native Save panel wrote a
  33,052-byte XCF; after Quit, the normal Open panel reopened its painted stroke.
- Export wrote a valid 1600 × 1200 PNG. The XCF stayed unchanged and clean.
- Classic Light, Neutral Gray and Dark changed the chrome and controls; labels
  and values remained readable. Classic Light was restored before quitting.
- The dirty Quit prompt named the saved XCF correctly. Only an unsaved extra
  test mark was discarded; the saved file was preserved.

A passive WindowServer observer used no AX queries or input during startup.
One isolated fresh-home launch reached its document after 58.5 seconds; a
restart reusing its engine/cache directories did so after 1.2 seconds.
Timing starts after the Launch Services process handshake and is not a
performance guarantee. An earlier delayed observation did not establish an
input-dependent startup failure. The repeat reached the editor automatically.

Physical Undo/Redo dispatch was not established by the desktop automation
pass. Native and real AppKit Undo/Redo workflows pass in the separate ordinary
and standalone suites. Every test app exited, its dialogs were resolved, and
the desktop was released.

## Qualification limits

This verifies a working local development app. Notarization is excluded by
the user’s instruction.
Remaining public distribution gates include complete binary-bound dependency
sources and historical patches, license/source packaging, Developer ID
signing and update qualification. Partial source archives and an
Apple Development signature do not close those gates.

Spoken VoiceOver, system Full Keyboard Access and physical calibrated-display
accuracy remain hardware/manual qualification work. HDR presentation, custom
LUT controls and paper/black simulation are not implemented promises. No
Wacom hardware or physical monitor accuracy claim follows from synthetic
input, pixel or accessibility-label tests.
