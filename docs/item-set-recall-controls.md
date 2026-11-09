# Channel and path saved-set recall

View → Saved Sets recalls nonempty layer, channel and path sets by their
current runtime token. The accepted command captures its document, token
and kind, resolves the current members on the worker, writes the whole
ordered selection and checks exact readback. Labels and cached table rows
never serve as command identities. Stale, foreign and wrong-kind tokens
leave selections unchanged.

Channel and layer recall use the counted paint-target command lifecycle;
path recall preserves the drawable target. Explicit stroke finalization
also works without a window callback. Accepted work, completion and close
drain use the document's existing serial queue. Floating selections refuse
layer/channel recall; path recall keeps the floating target.

With several channels selected, there is no single paint target. Single
target paint/fill/cut/copy/filter/transform routes refuse rather than pick
a channel. Return to Layers and explicit row actions remain available.
With several paths selected, there is no active path; Path-tool clicks,
Delete/Return/Escape and arrow keys consume no edit. In particular arrows
cannot fall through to moving the paint layer or floating selection.
Picking one row resolves a batch to that row. Selected rows remain visible
in both palettes without introducing a new multi-selection gesture.

The Saved Sets panel uses separate selection and action rows in a bounded
520 × 390 content area. A real release-window check reproduced clipped
buttons in its former six-button row. Geometry checks now require all six
buttons and the scrollable list to fit inside the visible panel.

## Evidence

All 798 unit tests pass. Before the row-display additions, the full pinned
app suite passes 2,104 checks; all four engines pass 59 focused recall and
69 Saved Sets controls checks. The regressions first reproduced all four
arrow directions changing paint-layer history and three clipped controls
or list checks, then passed after repair. The recall module also checks
floating arrows, a headless active stroke, fresh ordering, stale and foreign
tokens, quiet ambiguous edits, restoration by one row pick and exactly-once
completion through close. Final row-display checks, independent review and
exact-head CI are recorded with the PR when complete.

Batch image editing and broader channel/path selection gestures remain
separate work. These controls refuse ambiguous single-target operations.
