# Layered Lab brush facts

This private Recorder foundation fingerprints the effective, registered
brush mask, sRGB color and alpha, opacity, geometry, hard-edge setting and
size-only pressure dynamics for one layered Lab stroke. It captures the
resource identity for later resolution. Logical root IDs, UUIDs and selection
are deliberately not part of the fingerprint: a future Recorder binding must
capture and validate them separately before replay.

The helper refuses unregistered or unsupported brushes, nonfinite settings,
nonidentity symmetry, floating selections, non-normal mode, an RGB applicator,
expansion, jitter, smoothing, view-locked geometry, nonconstant application or
unsupported dynamics. It returns no partial owned strings on failure. It is
private and unused by the app or public API; it does not yet make layered Lab
strokes recordable or replayable. The native fixture exercises identity,
settings, pressure, invalid options and failure ownership on four engines.
Future work must add same-call facts capture, stale-target and expected-hash
guards before the first dab, and the Recorder binding, file and replay paths.
