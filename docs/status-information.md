# Status information chooser

Each document has a status-strip chooser for Dimensions, Working profile,
Precision, Canvas cache and Last tile. It reads only the owning document and
canvas caches. Changing the choice does not start engine work or change the
image, dirty state or Undo.

Canvas cache counts retained tile pixel payload, including row padding:
`CGImage.bytesPerRow × height`. It is not total image, engine or process
memory. Last tile measures monotonic elapsed time for the last successful
render accepted into the current canvas generation, including time waiting
for that native read. Before a tile succeeds, or after a generation change,
it is unavailable. Stale and failed results never publish a new duration.
Cache eviction, zoom, image size, ICC/proof and backing changes keep the
measurements consistent with the retained tiles.

In a narrow window during progress, the optional readout temporarily gives
way to progress and Cancel. It returns with the same selected choice when
progress finishes or the window grows. Messages and zoom remain in Rigi's
existing status strip. Every choice has an accessible label and help text.

## Verification

The actual window fixture covers all five menu actions, two independent
windows/precisions, exact native tile payload, measured timing, a held stale
render superseded by another generation, native state preservation and close
drain. Its strengthened minimum-width check exposed a 450-point status strip
inside a 360-point window. The corrected window keeps both at 360 points and
restores the readout after progress. All 27 focused checks pass on the pinned
engine. Independent source review found no important metrics/lifetime issue;
its narrow-layout concern was reproduced and fixed.

Six model tests cover cached values, row padding, binary byte units,
monotonic elapsed time and invalid/unavailable timing. Full unit, other-engine
combined workflows, latest-head CI and final packaging remain pending at this
checkpoint. No physical display or spoken accessibility result is implied.
