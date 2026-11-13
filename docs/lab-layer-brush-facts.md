# Layered Lab brush facts

This private Recorder foundation fingerprints the effective, registered
brush mask, sRGB color and alpha, opacity, geometry, hard-edge setting and
size-only pressure dynamics and GIMP, GEGL, Babl and Little CMS versions for
one layered Lab stroke. It captures the
resource identity for later resolution. Logical root IDs, UUIDs and selection
are deliberately not part of the fingerprint: a future Recorder binding must
capture and validate them separately before replay.

The helper refuses unregistered or unsupported brushes, nonfinite settings,
nonidentity symmetry, floating selections, non-normal mode, an RGB applicator,
expansion, jitter, smoothing, view-locked geometry, nonconstant application or
unsupported dynamics. It returns no partial owned strings on failure. The
native fixture exercises identity, settings, pressure, invalid options and
failure ownership on four engines.

The capture API candidate returns those facts from the same native begin call
and checks an expected fingerprint before the first dab. A live stroke with
an unrecordable brush can still paint with no facts; a guarded replay requires
an explicitly resolved resource and matching fingerprint. Normal captured
root identity, reentrant retarget rejection, cancellation and V2 sample rules
still apply. The app does not use this entry yet: Recorder target/selection
binding, file representation and replay remain to be implemented.
