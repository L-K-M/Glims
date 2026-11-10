# Live canvas tool hints

The idle status explains the selected tool and its current modifier behavior.
It updates while the pointer is stationary, uses the captured tool during a
gesture, and keeps progress, engine activity and errors above contextual hints.
Hint refreshes use a separate callback and do not clear a latched refusal.

Keyboard focus is a lifetime boundary for held modifier state. Releases may
go to a text field in the same key window. The canvas clears stale state on
accepted resignation and reads current physical modifiers on reacquisition;
pointer events still carry their own modifier flags.

## Verification

Old Main passed 15 of the initial 39 checks and failed 24 missing-hint checks.
Independent review then found the same-window lost-release case. Tests-only
`67beeea` observed 51 checks with six failures: stale hint, paint admission and
independent native pixels/Undo for each of Option and Command. The production
focus fix `e26533b` passes the unchanged 51-check fixture on all four supported
engines. Seven pure policy methods and the full isolated, leased suite of
1,022 tests pass. Independent source follow-up found no further important
finding in that correction; the earlier provider review missed the defect.

Every app run exited and released the desktop. The 3.0.8 immediate AX read
was incomplete; the other three and the later full-unit snapshot were clear.
These temporary signed hosts use external API165 adapters. This is synthetic
AppKit/event-method coverage, not physical keyboard/tablet or final bundled
release proof. Spring integration must compose both first-responder cleanup
hooks, with one super call. CI/review and final integration remain gates.
