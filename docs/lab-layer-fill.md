# Layered Lab fill foundation

This private engine work stages a constant physical D50 Lab color over a
single selected logical root. It composites straight-alpha U8 planes using
the selection's coverage and the requested opacity, and publishes all four
planes in one native Undo group. The stored map and other roots are unchanged.
An empty result and ordinary preflight failures leave pixels and history alone.
Engine shutdown and progress cancellation are checked while staging and before
any plane is published. Progress services the engine's main context; engine
busy ownership blocks ordinary nested mutations. The image, root and planes
are retained across dispatch, then their identities, the selection and Undo
state are rechecked before publication. The caller must prevent direct native
mutation throughout; this private helper does not make that safe.

The public engine operation binds the captured runtime root and durable UUID
before entering this helper. It accepts physical Lab values and engine
procedure cancellation; no app control invokes it yet. In particular, it does
not make layered Lab painting available in the editor. App integration must
provide a color workflow and cancellation/progress UI, and reconcile errors
and close. A brush needs
separate coverage accumulation and a single stroke-wide Undo transaction.

The standalone row tests exercise output staging, aliases, unaligned coverage,
in-place rows, invisible stored colors and invalid late coverage. An independent
rational oracle covers 300 rows, more than 36,000 component comparisons and
3,060 chosen alpha/color rounding-boundary cases. Native fixtures cover each
supported engine, including selection coverage, bounded damage,
Undo/Redo, XCF reopen, cancellation, a stale target and both sides of a
4,096-pixel chunk boundary. A single
native 24 MP diagnostic fill took 0.246 seconds on this Mac; this measures the
engine transaction only, not app interaction or cold-cache latency guarantees.
Independent review and integrated release qualification remain open.
