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


## Deferred overlap correction

Completed review of c895aca identified a separate defect: a physically
released, deferred key could remain in the hold table after a newer key
owned restoration. Pressing that first key again was then ignored. The
3cc2d96 regression observed one failure in 19 state tests. Correction
72c82fd first folds the original baseline into the newer owner, then retires
only physically released deferred holds. Still-held keys remain tracked.
All 19 state tests pass after the correction.

The a367090 actual canvas fixture preserves its earlier 83 checks and adds
nine checks for Hand drag, deferred H release, newer V ownership and a fresh
H press after restoration. All 92 checks pass on each of the four engines
(368 total), with exact native pixels, target state and history unchanged.
The full isolated, leased suite after Main726 integration passes 1,069 tests.
Each process exits zero and releases its desktop lease. The pinned immediate
AX observation reports Finder and no dialog; the other three focused runs
and the unit run report WINDOW_NOT_FOUND, so their immediate AX verification
is incomplete. No later clear observation substitutes for those gaps.

Independent source follow-up verifies the baseline-fold/filter order and
reports no further important finding. The earlier no-finding review is
superseded for this orphaned-key path. Exact runs, source and log hashes are
recorded in /tmp/glims-completion/spring-a367090-all-four-verified.json.
These are temporary signed hosts with immutable API166 adapters. Combined
feature interaction, physical input and final self-contained release remain
separate gates.
