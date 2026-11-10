# Typed XMP Rating controls

Image > Metadata exposes Edit Rating for the registered scalar
`Xmp.xmp.Rating` when the loaded engine permits SET or REMOVE. The form has
these explicit choices:

| Choice | Native values/action |
| --- | --- |
| Not specified | REMOVE, an absent tag |
| Unrated (0) | SET `0` |
| Rejected (-1) | SET `-1` |
| 1 star through 5 stars | SET the corresponding integer text |

A fractional, noncanonical or empty original value is displayed exactly.
It does not select an implicit star value. Apply stays disabled until you
choose a supported value. Cancel leaves the native metadata unchanged.
Removing a tag is distinct from setting zero. A blank local Add Tag row
opens the absent state without first storing an empty value.

The editor captures its owning document and initial state version. Each
Apply obtains a fresh counted descriptor read and requires scalar XmpText,
matching presence/cardinality and the appropriate independent SET or REMOVE
permission. Other document changes invalidate the draft; native errors keep
the chosen draft visible for retry. Accepted writes remain counted through
window close, and late read callbacks cannot reopen an invalidated form.
The existing metadata service owns preservation checks, Undo and XCF save.
No new native writer or container/language-map mutation is introduced.

## Verification status

Eight exact-value tests and eight descriptor/policy tests passed on the
pre-integration product revision. The separate 11-check button-admission
fixture passed on all four engines. The old public-menu fixture first
reproduced the missing Edit Rating control. Current Main165 integration builds
both the app and tests with `-j 2`, and all 1,028 unit tests pass.

The `metadata-rating-edit` fixture uses a launched AppKit host shared with
batch Rasterize. It has 54 expected checks: literal choices, Cancel,
captured A versus actual front B, one-step Undo/Redo, no-op SET/REMOVE,
independent XCF reopen, stale/native-BUSY refusals, late reads and counted
close. A prior foreground run logged all 54 as passing, but its launcher
did not attest process exit or desktop cleanup, so it is not treated as a
verified runtime pass. The corrected foreground runner records all 54 checks passing on every
supported engine (3.2.8, 3.2.0, 3.0.8 and master), with owned process exit 0,
no final dialog and desktop release after each case. It obtains the actual
process ID before waiting for LaunchServices completion; the SDK callback
may report -1 after these synchronous checks finish.

The shared-host batch Rasterize fixture also passes all 51 checks on every
engine, with owned process exit 0 and release. Its immediate external AX
snapshot was incomplete on 3.0.8; that external dialog observation is
unverified. The fixture confirms its own windows/sheets are gone, and the
later master and full-unit final desktop snapshots show no dialog. These
are temporary signed foreground hosts using immutable external slot165
producers, not self-contained release checks. Latest-head hosted CI and
completed independent review remain pending. One attempted LongCat source
review timed out without output; author triage is not independent approval.

For engines that refuse a present empty Rating seed, the fixture requires
the exact native serialization-preservation refusal and unchanged complete
metadata, pixels and history. It then uses supported fractional text for
the remaining scenarios. The actual present-empty form remains unverified
on such an engine; the pure empty-value gate tests remain separate evidence.
