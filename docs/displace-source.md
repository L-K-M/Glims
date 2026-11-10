# Displace with two source maps

Filter > Displace lets you choose a horizontal or radial map and a vertical
or angular map. Both choices start empty. A zero axis amount disables that
axis. Preview uses snapshots of the chosen drawables, and Apply merges the
result into the original target as one Undo. Cancel changes no pixels.
Rasterizing a text, link or vector source remains a separate explicit action;
after it completes, start Displace again to choose fresh maps.

The source chooser retains its original document and layer even if another
window becomes active. Deleted choices stay visible as unavailable until
replaced. Counted preview admission and close retire late callbacks and abort
any preview that finishes starting after its owner closes. The other four
captured-source filters keep their existing chooser and callback routes.

Native facade 169 checks both sources and the target before copying either
map. The shared source-snapshot budget applies to the sum of the maps. When
the same drawable is chosen twice, the operation retains one shared snapshot.
The existing scalar, enum and boolean form edits the resulting preview.

The native tests pass 226 checks on each supported engine (904 total), plus
7,454 general conformance checks. The previous facade reports the intended
missing entry among 15 setup and reference checks. Independent source review
checks lifetime, aliasing, admission and unchanged earlier slots.

The tests-only `2411238` app runs ten checks and fails only the missing enabled
menu item; dependent scenarios are explicitly not run. At `5b369fc`, the
unchanged 58-check actual interface fixture passes on all four engines
(232 total). It compares literal nearest-sampling pixel oracles, including
separate axes, swapped maps and transparent map pixels. It also covers
Cancel, Apply/Undo/Redo, retargeting, close and explicit Rasterize consent.
Each run exits and releases the desktop with an immediate no-dialog snapshot.
Three old unit assertions expected Displace to remain unavailable; the
updated catalog assertions retain an unhandled auxiliary operation control,
and the full isolated suite passes 1,059 tests.

These runs used signed test hosts and immutable external adapters. The
combined build retains captured Text creation and the newer layer-pick
harness. Its combined runtime and hosted CI gates remain open. Oilify, final
self-contained bundles and the full release checks are separate work.
