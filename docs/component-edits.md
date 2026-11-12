# Native ink Fill, Clear and Invert

These commands operate on one
explicitly selected authoritative CMYK or Multichannel ink plane. They do not
convert through RGB or enable generic layer filters on an ink document.

## Numeric contract

Intensity zero is full ink; one is paper. Fill supplies an intensity and opacity
in [0,1]. Clear fills with paper at full opacity. Invert proposes `1 - intensity`,
including finite extended float values without clipping. Selection coverage
blends the proposal once:

`result = original + coverage × opacity × (proposal - original)`

An empty native selection mask means no active selection, so the whole channel
is affected. A zero mask weight preserves the original bytes. U8/U16 results
round to the nearest integer, half upward. Full coverage uses the exact proposal
to avoid subtraction cancellation for extreme finite float values. Affected
nonfinite source samples or invalid mask weights refuse before publication;
unaffected samples are not sanitized. Zero opacity is a successful no-op.

The additive slot183 requires the explicit nonzero channel ID to match the sole
selected validated ink. Other images, stale or changed targets, locked pixels,
damaged component storage and active edits refuse. Existing ordinary Fill,
pattern, Clear and filter routes retain their default-deny component policy.

## Ownership and Undo

The engine owns a copy-on-write candidate and selection snapshot before servicing
nested calls. Calculation uses bounded scalar rows in the existing GEGL cache.
The busy gate holds throughout staging, publication and cleanup. Read RPCs and
Cancel can run at cooperative checkpoints; polling is not a bound on a single
blocking native operation. Cancellation and shutdown discard the candidate
before publication.

After final cancellation and target checks, a native Undo snapshot precedes one
copy of the changed region into the original buffer. That buffer keeps its
identity so the preview receives local damage. A byte-identical result creates
no Undo entry. Other ink bytes, UUIDs, profile, visibility, names, precision and
native file identity remain unchanged.

The UI captures the Fill sheet's target and resolves selection pixels when the
queued operation executes. Accepted edits drain before Close; later submissions
refuse. Recorder coverage must be reported explicitly until these commands have
their own replay schema. Accepted edits reserve their Recorder entry before busy
observers can stop or restart recording; late completion cannot enter a new epoch.

## Qualification

The independent native fixture passes 1,314 checks on each of the four engine
sets, covering both ink modes and all three precisions, weighted selections,
exact raw Undo/Redo, preserved other planes and metadata, locks and invalid
inputs. A separate 39-check control fixture passes on each set: cancellation
before publication, busy/read ownership, shutdown, projection events and retry.
The scalar kernel passes 828 optimized and sanitized checks. An independent
197,397-check integer/extreme-float probe passes. Two numeric regressions were
observed before correction: huge-float half-mask Invert cancellation and integer
half-up Fill rounding. Final source review found no remaining important issue.

The pinned actual-window fixture passes 246 checks: invalid/cancelled/retargeted
Fill sheets, admitted Fill/Clear/Delete/linear Invert, exact display Undo/Redo,
unsupported filter gating, Recorder Stop/restart isolation and accepted Close
drain. The Recorder observer regression produced six failures before its fix.
All 1,526 Swift tests pass. Artifact-only PNG capture adds two visual checks to
the final packaged run. All-engine UI, standalone package/startup and latest CI
qualification remain in progress. This does not complete ink-mode adjustment
coverage, Recorder replay support or Photoshop 4 parity.
