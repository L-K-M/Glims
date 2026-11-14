# Layered Lab brush core (private candidate)

This private core uses GIMP's brush geometry and stages each dab across the
four physical Lab and alpha planes. It derives each dab from the native
stroke-start buffers and accumulated coverage, applies a captured image
selection, and publishes the four staged planes only after the entire dab
validates. Native paint-core finish groups the plane changes into one Undo;
the caller must cancel the whole stroke after any error.

The caller is responsible for admitting the logical root, checking its durable
identity and locks, keeping the ordered planes stable for every input packet,
and owning native start, finish and cancellation. The core itself does not
expose a canvas tool, Recorder support, or tablet pressure dynamics.

## Captured stroke API (candidate)

The follow-up adds typed begin and cancel calls for a solely selected logical
root, identified by both its current handle and document-scoped UUID. It
converts bounded sRGB to D50 Lab and accepts V2 stroke packets. Continuation
and end revalidate the root and plane identities; a changed target cancels and
restores the full stroke. Native painting runs under a reentrancy guard, and
closing a document with an active typed stroke guards its rollback. A changed
stroke has one native Undo step; cancellation and no-op strokes preserve
history. Changed dabs invalidate their bounded canvas area; cancellation
invalidates the restored stroke bounds. This candidate does not enable the canvas tool or Recorder, and its
brush dynamics are disabled, including pressure effects. Engine compatibility,
review and full application qualification remain required.

The native fixture uses real brush masks and independent plane snapshots. It
checks selection-weighted physical color, interpolation, other-layer
preservation, Undo/Redo, cancellation, zero opacity, reordered targets and a
nonfinite mask. The fixture must be run against each supported engine with
`scripts/test-lab-layer-brush-core.py` before integrating this core. Full app
performance and behavior have not been qualified.

On this Mac, a separate native observation on an initially transparent,
sparse 24 MP carrier measured three runs of 64 small hard dabs at 4.51–5.39 ms
total; stroke start took 0.81–1.25 ms and finish 0.40–0.46 ms. The fixture
checks actual first and last pixels and Undo. These are isolated engine timings
without UI, display rendering, tablet input, or a populated large image; they
are not an interactive performance guarantee. The benchmark is available as
`scripts/bench-lab-layer-brush-core.py`.
