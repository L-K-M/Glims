# Recording native ink edits

Recorder captures successful native ink Fill, Clear, Invert and Levels Apply
as owned semantic commands. Preview Begin, rendering and Cancel create no
rows. A refused admission creates no reservation; accepted work reserves its
row before busy observers can Stop, Start or Close the document. A new
recording epoch cannot receive an earlier epoch's completion.

Scalar edits capture the explicit channel behind accepted input. Levels
retains the original channel and authoritative identity with its Begin token,
then records the final accepted settings at Apply. Native failure remains a
failure. If identity metadata is unavailable on an older engine, the live edit
can still succeed but the recording reports a failure instead of promising
replay.

## Saved values and binding

Recording version 11 adds `editInk` and `applyInkLevels`, with strict finite
numeric ranges, canonical Clear/Invert values and exact Boolean clamps.
Reversed or equal Levels endpoints remain valid. Successful commands require
an explicit ink binding to a channel-kind symbol, carrying a validated mode,
canonical CMYK role and document-scoped plane UUID. Contradictory identities
for the same symbol refuse. Unknown fields, wrong types, unsupported versions
and mismatched commands/bindings refuse the whole file. Versions 1–10 retain
their existing rules; unsuccessful rows are never converted to successes.

Load requires explicit destination choices. A CMYK Cyan command can bind only
to canonical Cyan, regardless of either channel's name. A Multichannel command
requires an explicit choice of a Multichannel ink. Installation captures the
destination's own UUID; it never treats equal UUIDs in unrelated images as
permission. The binding picker narrows its suggestions using cached mode and
canonical order, and the service revalidates native identity before accepting.
Batch name/path matching refuses ink recordings.

Replay requires the bound ink to be the sole selected ink. Both cached and
fresh native admission check the target; the command never silently switches
selection. Native operations apply to the current selection mask, with
destination precision/rounding. These are numeric ink operations, not an
appearance match across different profiles. Each changed command makes one
Undo step. A failed step schedules no later command; earlier successful steps
are not rolled back as one transaction. Recording ink-selection changes and
automatic Batch ink binding remain separate work.

## Verification

Twenty focused pure tests cover literal v11 files, strict malformed cases,
version anchors, identity consistency, conversion/snapshot preservation and
Batch refusal. Independent file and runtime reviews found no important issue.

The document-service fixture passes 329 checks on each of GIMP 3.2.8, 3.0.8,
3.2.0 and master. It covers both modes in U8/U16/float, disk Save/Load, explicit
cross-document rebinding with different UUIDs, an independent scalar Fill
oracle, exact per-step Undo/Redo, wrong CMYK roles, stale cached selections,
failed-step stopping and XCF reopen with a retained UUID/new native ID. The
fixture initially attempted confirmation before queued XCF setup events were
delivered; an explicit main-queue barrier now establishes that checkpoint.

All 1,570 unit tests pass. The four-engine UI matrix exposed a development
adapter path defect: removing its build worktree broke Python and Script-Fu
plug-in discovery on the subsequent master run. Adapter builds now resolve
shared engine/dependency trees to physical paths before embedding runtime
paths or writing link response files. The original menu assertion is retained;
the rebuilt adapter and affected full run are being checked again.

The focused `recorder-ink-bindings` fixture drives real CMYK and Multichannel
Load sheets, including duplicate display names, an explicit non-first ink,
Cancel/reopen and pixel/history/selection preservation. It compiles; runtime
qualification, combined bundle and launch results are tracked in the
integration PR. This slice does not complete Recorder coverage or Photoshop 4
parity.
