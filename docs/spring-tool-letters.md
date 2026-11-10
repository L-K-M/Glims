# Spring-loaded tool letters

Canvas letters keep their normal tap-to-select behavior. Shift+letter cycles
within the existing tool group. Holding a tool letter for at least 300 ms,
or using it for an interaction, makes that selection temporary. Release
restores the previous tool after the captured stroke or compound interaction
finishes. Repeats do not cycle; a newer explicit tool choice remains authoritative.
Text fields and the Text overlay retain ordinary typing.

The spring owner tracks accepted interaction cleanup independently from
restoration eligibility. This matters when an explicit same-tool choice
invalidates restoration before focus is lost: the accepted stroke must still
finish, while the explicit selection remains selected. Ordinary interactions
are not canceled merely because a temporary tool key was pressed later.

## Verification

The tests-only `6a191ba` fixture observed 76 checks with two failures on the
prior implementation: a stroke remained active after focus loss, blocking a
fresh stroke. The production-only correction `eef8fea` passes the unchanged
18 state tests. Its complete actual interface fixture passes 83 checks on
each supported engine (3.2.8, 3.2.0, 3.0.8 and master), including accepted
stroke cleanup, overlapping keys, compound interactions and Text focus.
The full isolated, leased suite passes 1,033 tests. Every run exited, released
the desktop and recorded a dialog-free final accessibility snapshot.

Independent source follow-up confirmed the focus-cleanup correction and found
no further important finding in the changed path. An earlier source review
missed that defect; it is not treated as approval of the failed implementation.
The native runs use temporary signed hosts and external immutable API165
adapters. They do not establish a self-contained release, physical keyboard
or tablet delivery. Current CI/review and integration remain required.
