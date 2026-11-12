# Converted Lab copies

Image > Create Lab Copy creates a separate document from an RGB canvas.
In a Lab document the command becomes Create Linear RGB Copy. The original
stays open with its layers, selections, metadata and history unchanged.
The confirmation describes the copy's pixel-only scope before starting work.
The new document requires its own Save even though its construction has no
Undo steps.

This candidate copies the full canvas and resolution. RGB layers contribute
their merged visible appearance; a selection does not crop or attenuate the
copy. Lab conversion reads all three authoritative channels regardless of
preview visibility. Other metadata, paths, saved selections and editable
layer structure stay in the original and are not copied.

## Color contract

The first route accepts 8-bit, 16-bit and 32-bit float RGB using the effective
standard sRGB or linear-sRGB profile. It requires an opaque canvas. Custom
profiles must first be converted to sRGB using the existing profile command.
Native linked-layer objects, including frozen ones, must be replaced with
ordinary pixel layers: a queued file update can otherwise modify them while
conversion services cancellation. Hidden and nested linked layers also refuse.

Lab output stores physical D50 L*, a*, b* as 32-bit floats. The reverse route
accepts all three supported native Lab precisions and produces one opaque
32-bit linear-RGB layer with the builtin linear-sRGB interpretation. The
native engine omits redundant builtin ICC bytes; this is an effective-profile
contract, not an embedded-profile claim. Finite extended values are retained
when representable. There is no silent gamut clipping or alpha flattening.
Unsupported modes, nonfinite samples and unrepresentable output refuse.

## Ownership and admission

Facade slot 197 has an owned, size-checked settings prefix and returns a fresh
image only after conversion finishes. Input settings may be unaligned, and
future tails are ignored. It accepts only merged-canvas content and float
output. Private component preparation constructs the candidate without
publishing a handle. All source references survive nested progress dispatch;
cancellation or failure destroys the partial candidate and returns no image.

Active engine work, strokes, filter previews and incomplete Undo operations
block conversion. Floating selections and Quick Mask must be resolved first.
The app rechecks cached admission after callbacks, counts accepted source
reads through Close, and treats result adoption as a file operation through
Quit. The original does not acquire an Undo step or an unsaved-change marker.

## Current evidence and remaining work

The independent native fixture passes 412 checks on GIMP 3.2.8, 3.2.0 and
master, and 392 on 3.0.8, which has no linked-layer class. All four engines
also pass the 314-check admission suite and general conformance. Checks cover
raw values in both directions and all three precisions, fixed LCMS/literal
numeric bounds, 300×144 DPI with empty result history, source preservation,
row/chunk boundaries, late invalid samples, linked-layer refusals, XCF
persistence, cancellation and reentrant command refusal. The private math
has independent optimized and sanitizer coverage in `lab-transform.md`.

The complete Swift suite passes 1,608 tests. Its transport and file-state
suites include exact
legacy-prefix guarding, complete request fields, error-string ownership and
persistent Save requirements. An actual-window lifecycle regression first
reproduced six failures when result cleanup returned BUSY. After the fix,
the unchanged 32-check fixture passes on all four engines: it checks result retirement,
Close All/Quit waiting, canceled Quit, owner deallocation and callback reentry.
The app retains each discarded result and its pending-operation count through
BUSY retries. Independent review found no remaining important cleanup issue.

The extended actual-menu fixture passes 58 checks on the pinned engine. It
uses the real Image item and AppKit responder chain for Create/Cancel in both
directions, confirms separate unsaved copies and source preservation, and
refuses stale activity/closed-source confirmations. Actual Close/Cancel
proves the new copy requires Save; no external Save panel is automated here.
All-engine menu and final standalone qualification remain in progress.
The earlier lifecycle runs retain two upstream EOF warnings on 3.0.8 and two
pre-startup filename-null criticals on 3.2.0; the pinned run is clean.
Allocation/Stop fault injection, private native leak accounting, and several
live-session admission cases are not tested by the native fixture. No app
bundle, installation or complete mode-conversion parity is claimed here.
