# Exclusive edits and unsaved close decisions

An exclusive image edit can finish native work before its main-thread cache
refresh runs. A close decision queued by the initial busy notification runs
at the first idle boundary, ahead of that refresh. Previously, a clean
CMYK or Multichannel document could still report no unsaved changes there.

`ImageDocument.enqueueExclusive` now counts image-changing work as pending
input before `EngineActivity.perform` notifies observers. Its original work
and input holds remain until `whenReadyForSynchronousRead` reconciles native
dirty state. A failed read conservatively retains unsaved state. Rejected
admission releases both counts. A second activity may defer reconciliation
without dropping the accepted edit's unsaved indication.

The focused `exclusive-edit-close` engine smoke case creates no windows or
sheets. It exercises actual native Fill in clean CMYK and Multichannel
documents, observes the busy and first-idle close boundaries, and repeats
with an earlier idle action starting a second activity. Pixel changes and
one Undo step prove the edit ran; Recorder stays off, and owned documents
close after all work drains.

Build with `swift build`, then use an existing adapter and disposable settings:

```sh
witness_root=$(mktemp -d /tmp/glims-exclusive-close.XXXXXX) || exit 1
mkdir -p "$witness_root"/{home,cache,config,data,user,tmp,babl}
env HOME="$witness_root/home" CFFIXED_USER_HOME="$witness_root/home" \
  XDG_CACHE_HOME="$witness_root/cache" XDG_CONFIG_HOME="$witness_root/config" \
  XDG_DATA_HOME="$witness_root/data" GIMP3_DIRECTORY="$witness_root/user" \
  TMPDIR="$witness_root/tmp" BABL_CACHE_DIR="$witness_root/babl" \
  GLIMS_ENGINE_LIBRARY=/absolute/path/to/libglimsengine.dylib \
  GLIMS_SMOKE_CASE=exclusive-edit-close .build/debug/Glims --engine-smoke-test
```

This service regression covers unsaved accounting at the close-decision
boundary. Actual Save/Discard dialog behavior remains part of UI qualification.

The unpatched main implementation reproduced ten failed unsaved-state
assertions. The correction passes all 36 checks on each of GIMP_3_2_8,
GIMP_3_0_8, GIMP_3_2_0 and master. The production function is byte-identical
to the independently reviewed correction used in the Lab candidate, whose
actual Fill/Close/Cancel save-prompt witness also passed. Full installed-app
qualification remains separate.
