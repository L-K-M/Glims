# Saved-set management controls

View ▸ Saved Sets… opens a document-owned nonmodal panel for fixed layer,
channel and path sets. Rows show display labels and live member counts;
opaque current tokens identify every command. New/Replace capture the
native selection after accepted input drains, including an explicit empty
selection. Rename accepts a full new draft and never seeds it from a
possibly truncated display label. Delete removes the addressed definition.

Management uses counted, off-main work; accepted completions remain counted
through global idle delivery and close. The panel invalidates when its host
closes. Current layer sets can be recalled; channel/path recall remains
disabled with a product-facing reason until batch selection is implemented.

Initial recall trusted cached member IDs. Root reproduced two failures with
an expired token whose layers still existed. Recall now resolves current
members on the worker through slot 134, then uses native exact selection
and verifies readback in the existing counted target-command route. Painting
is gated until target reconciliation; there is no optimistic cached recall.
The expired token now refuses without changing selection and reports the
error in its captured panel.

All 776 unit tests pass; all four engines pass 62 focused control checks.
The pinned full app suite passes 1,953 checks. Root corrected two test-only
absolute Undo-count assumptions and seven always-non-nil Result assertions.
An unrelated full-suite watched-link fixture needed a bounded BUSY wait
before closing its replacement source, matching the document close policy;
other errors still fail immediately and the deadline remains enforced.

Independent review of committed c317479 found the known stale recall and
no additional important issue. Root's recall/copy/test fixes were reviewed
directly and executed after that review; no separate independent approval
of those deltas is claimed. Channel/path batch recall, broader batch edits
and final combined bundle/CI validation remain separate work.
