# Native layer picking

The facade's read-only layer query delegates to the engine's own layer hit
test. It preserves native layer ordering, visibility, masks, groups and
floating-selection behavior. A successful miss returns zero. It never
selects, anchors, edits, dirties or adds Undo history.

Coordinates must be finite. Fractions truncate toward zero, as the native
Move input does, with checked integer conversion and checked subtraction of
every traversed layer offset. Safe off-canvas coordinates remain valid;
unsafe arithmetic, stale images and busy engine access refuse explicitly.
The result is reset before admission, including failure paths.

## Verification at 8898afd

The focused native fixture passes 156 checks on each supported engine
(624 total). It compares the facade with direct Core calls and independent
literal scenes, and checks pixels, hierarchy, selection, floating state and
history remain unchanged. The old166 producer runs 48 setup/Core checks
with its one expected missing-slot failure. All four general conformance
runs pass: 1,917 / 1,917 / 1,703 / 1,917 checks.

Reviewed stable source revisions use a strict .25 effective-opacity pick
threshold; the reviewed development revision uses .001. The build driver
binds those expectations to exact source commits and hashes. These are
source-specific expectations, not promises about future engine versions.

Raw unmasked quarter-alpha and its adjacent float controls remain exact.
A repeated development-engine experiment observed two failures in eight
processes when an older fixture assumed a converted white mask was exactly
1: the mask was 1.0000000361224048, and effective opacity was exactly
.25 times that value. The corrected assertion checks that native equation
without epsilon or clamping; its masked boundary expectation uses the
independent converted mask. Direct Core comparisons and all unmasked
boundary controls remain. An earlier legacy three-assertion outlier lacked
numeric capture; its original cause remains unproven and is retained.

Independent source review covers the query, checked arithmetic and the
fixture correction. Swift Move/selection integration, hosted CI/current
feedback and the final combined self-contained release remain separate
work. This native query alone does not implement new canvas gestures.
