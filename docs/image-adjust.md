# Image adjustment menu

Image > Adjust exposes the loaded native Threshold, Invert Perceptual and
Invert Linear controls. They use the existing modeless preview lifecycle:
Cancel restores the input, Apply adds one native Undo step, and committed
effects survive XCF reopening. The existing Filter > Color entries remain.

Native and plug-in entries share the static Adjust submenu. Refreshing
either catalog removes only its own generated content, including nested
plug-in categories, while preserving unrelated commands and submenu identity.
Unavailable operations are omitted from Adjust without lifting config or
auxiliary-input gates elsewhere.

Six new menu tests reproduced four refresh defects in the initial draft.
The corrected source passes 915 unit tests and 27 actual-window checks on
each supported engine. The latter independently check threshold samples,
sRGB encoded inversion, linear-light inversion and unchanged alpha, plus
captured-document preview, Cancel, one Undo/Redo and XCF pixels. Independent
source review found no important issue. A first nested plug-in category may
lack a dividing separator until native refresh; this cosmetic detail is
deferred. Additional Adjust placements and final integrated release checks
remain separate work.

## Exposure (2026-11-10 candidate)

Image > Adjust > Exposure… now routes the loaded `gegl:exposure` operation
through its existing generic native preview. Exposure and Black level keep
their current controls; Filter > Color retains its existing entry. Missing or
unsupported operations remain omitted from Adjust.

Before adding this placement, the focused `exposure-adjust` actual-menu case
ran all 29 checks: only the missing Adjust item failed. The other 28 passed,
including independent linear-RGB exposure and alpha math, a separate native
pixel reference, actual field and Apply/Cancel actions, existing-effect edits,
last-field Apply, Undo/Redo, XCF, two-document ownership and admission guards.
The same fixture and oracles are unchanged. Fresh integration source
`ddcabd4` passes all 29 checks on each of 3.2.8, 3.2.0, 3.0.8 and master
with immutable external API165 producers, plus 1,012 unit tests in a private
leased run. Each owned app exited0; all four final AX snapshots reported no
dialog and released the desktop. These temporary signed shells are not
self-contained release bundles. The earlier unleased unit invocation is
not desktop evidence; the proper private leased repeat is the reported run.

Four completed review rounds through `21790a9` cover the byte-identical
catalog and dedicated fixture. The later `2713769` reviewer integration timed
out before publishing; that failure is not approval. The latest Main merge
adds only collector scripts/tests/docs. Required latest-head CI and final
combined release acceptance remain separate gates. Verification paths and
hashes are in `/tmp/glims-completion/exposure-main165-all-four-results.json`.
