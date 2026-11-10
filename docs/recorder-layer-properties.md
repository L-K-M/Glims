# Recording layer properties

Recorder captures accepted layer name, visibility, opacity and blend-mode
changes, including the Layers palette's opacity control. A command owns its
values. A separate same-document runtime binding identifies the explicit
layer; replay checks ownership again before writing and never follows the
front document or a later layer selection.

Both property write routes preserve their existing input counts,
reconciliation and completion callbacks. Stop retains already accepted
work. Clearing or starting a new recording fences late settlements by
epoch; failure is visible and cannot become a successful macro. Replay
keeps normal native setter Undo behavior rather than adding a macro-wide
transaction. This does not record other layer operations or painting.

## Verification at 48b79dc

The tests-only baseline uses the actual labelled opacity field: its native
edit succeeds, but no command is captured. Eight checks execute with the
one intended missing-capture failure. The unchanged full fixture then
passes 36 checks on each engine. It compares independent native property,
pixel and Undo results; verifies A while B is front, immutable mixed values,
explicit layer selection, Stop/epoch/cancel, native errors, deleted/foreign
target refusal and close/completion draining.

The existing capture, replay and palette fixtures remain unchanged and
also pass on all four engines: 712 focused checks total including the new
family. The isolated full suite passes 1,050 tests. All runs exit0 and
release the desktop; individual post-run AX receipts are retained without
claiming a comprehensive accessibility audit. Independent source review
reports no confirmed important finding.

These runs use signed temporary interface hosts and immutable external166
adapters. Durable files/reopen binding, additional command families,
current hosted CI/review and final combined release remain separate work.
