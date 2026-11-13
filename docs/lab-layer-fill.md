# Layered Lab fill foundation

This private engine work stages a constant physical D50 Lab color over a
single selected logical root. It composites straight-alpha U8 planes using
the selection's coverage and the requested opacity, and publishes all four
planes in one native Undo group. The stored map and other roots are unchanged.
An empty result and ordinary preflight failures leave pixels and history alone.
Engine shutdown is checked while staging, before any plane is published. The
caller must serialize access and prevent nested native mutation throughout.

There is no public ABI entry, app control, brush integration, user-facing
progress or user cancellation in this slice. In particular, it does not make
layered Lab painting available in the editor. A future public operation must
bind the captured logical root and its identity across queued work, provide
safe cancellation and progress, and reconcile errors and close. A brush needs
separate coverage accumulation and a single stroke-wide Undo transaction.

The standalone row tests exercise output staging, aliases, unaligned coverage,
in-place rows, invisible stored colors and invalid late coverage. An independent
rational oracle covers 300 rows, more than 36,000 component comparisons and
3,060 chosen alpha/color rounding-boundary cases. Native fixtures pass 65
checks on each supported engine, including selection coverage, bounded damage,
Undo/Redo, XCF reopen and both sides of a 4,096-pixel chunk boundary. A single
native 24 MP diagnostic fill took 0.246 seconds on this Mac; this measures the
engine transaction only, not app interaction or cold-cache latency guarantees.
Independent review and integrated release qualification remain open.
