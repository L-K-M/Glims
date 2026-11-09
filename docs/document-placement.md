# Initial document placement

New and opened documents choose their first frame after the current palette
arrangement is visible. The placement policy finds the largest usable
rectangle inside the selected screen's visible area, leaving six points
around visible Rigi palette windows. The initial document fits inside that
rectangle; later documents cascade within it and wrap when needed. Palette
frames are preserved. Hidden palettes and palettes on other screens do not
consume space. If a custom workspace occupies every usable rectangle, the
document stays usable within the visible screen instead of becoming tiny.

The initial Fit Image runs after placement and window layout, so it uses
the final viewport. Actual Pixels remains the person's alternative initial
view preference. This changes window presentation only.

Six geometry tests cover a 1440-point screen whose former centered window
overlapped both palette columns, a screen with a negative origin, off-screen
palettes, no palettes, cascade overflow, a crowded workspace and a palette
above the document. All 816 integrated unit tests pass. Each of the four
engines passes 15 real AppController.open checks: two document windows,
visible palette avoidance, final-viewport fitting, unchanged palette frames,
complete native composite bytes, native dirty/info/history preservation and
close drain. The integrated pinned app suite passes 2,121 checks. Independent
source review found no important issue; its minor weak native-state oracle
was replaced with full native reads and byte comparison before the final
runtime checks. Hosted CI is the remaining merge gate.

Physical multi-display testing remains unavailable; negative origins and
screen clipping have deterministic geometry coverage.
