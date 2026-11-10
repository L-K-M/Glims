# Close All documents

File > Close All (Option-Command-W) captures the current document windows in
newest-first order and closes them through the existing save and native-work
drain path. Cancel or a failed Save stops the sequence. Documents adopted
after capture remain open. Close All keeps the app running; a subsequent
Quit joins the current close request and then uses the live document list.
Only an actual Quit request receives AppKit termination replies.

Two menu/validation tests first failed on the old product with three actual
behavior failures, then passed after implementation. An earlier tests-only
compile failed because the fixture omitted the shortcut collector's `from:`
label; that compile failure is separate from the behavior baseline.

All 1,014 unit tests pass with private settings and a desktop lease. The
focused launched-AppKit case passes 26 checks on every engine (3.2.8,
3.2.0, 3.0.8 and master), covering Cancel, Save, Don't Save, failed Save,
reentry, later adoption and held native close work. Each process exits zero,
its final external snapshot shows no dialog, and the desktop lease releases.
These signed temporary hosts use immutable external slot165 producers, not
self-contained release bundles.

A completed independent Glyph source review found no confirmed important
issue. Its author-side verification is not another independent review.
The fixture dispatches the real menu selector explicitly to an ordinary
owner.open owner; actual nil-target responder/keyboard routing, Quit during
Close All and pending file/recovery completion interleavings remain final
workflow gaps. Latest-head hosted CI/review and integration remain pending.
