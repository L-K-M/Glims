# Creating text over a floating selection

A new text editor captures its original document, window and complete
floating state when it opens, including an inactive state. Apply uses that
expectation once. It never substitutes a newer floating selection or the
front document. Starting another editor while a target command is pending
refuses until reconciliation; callbacks from finished editors cannot apply
a newer one. Existing text editing and deletion keep their behavior.

The native action prepares and lays out text before anchoring, checks the
captured state and pixel locks again, then anchors and inserts in one Text
Undo group. Ordinary representable off-canvas placement remains valid.
Unsafe integer/extent arithmetic refuses before mutation. A failure after
native mutation is reported and reconciled; Undo grouping is not rollback.

Escape applies typed text, as before. An empty new editor submits nothing.
Closing finishes text before the existing save prompt: cancelling that
prompt retains an already applied edit. This feature adds no Text Cancel
shortcut or silent legacy-adapter fallback.

## Verification

At frontend cd68bcb the unchanged51-check fixture passes on all four engines
(204 checks), plus1,050 unit tests. The tests-only old frontend executes all
51 with18 failures, preserving the actual baseline. Checks include a real
Paste Into/editor, independent Anchor plus legacy Text reference, one Text
Undo/Redo, A while B is front, stale active/inactive expectations, empty and
invalid submissions, pending admission and actual close/drain behavior.

Native168 production b44da3b passes170 focused checks per engine (680) and
7,454 general checks across all four. Old167 reports the expected missing
function failure. Native references cover additional layer/mask/channel
attachments beyond the ordinary-layer interface fixture. Independent
native and frontend source reviews report no confirmed important finding.

The safe Main merge only updates two other smoke fixtures; production,
these acceptance fixtures and native producers remain unchanged. Physical
input, genuine layout-NULL/late-failure injection and final combined release
remain unverified. Matching168-or-newer adapters are required by the existing
full-table loader contract.
