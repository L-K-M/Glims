# Private logical Lab layer duplication

The private engine-thread command duplicates one explicit logical root in a
validated U8 layered Lab carrier. The new root is inserted directly above
its source and selected. Its L/a/b/alpha samples, visibility and opacity are
copied, while all five persistent identities are regenerated. The new map
entry is appended independently of native root and child order.

## Mutation and ownership

The caller excludes concurrent native writes, validation, nested dispatch
and external mutation. Admission requires an idle engine, no active strokes
or filters, enabled and unfrozen Undo, no existing Undo group, a complete
supported carrier and fewer than 256 logical layers.

The copy is staged as a detached native group. Its four roles are resolved
by their old UUIDs, checked for separate buffers, then assigned fresh UUIDs.
Identity parasites use persistent and undoable flags without parent
propagation. The complete replacement map is encoded and allocated before
starting Undo. Final admission and an exact native insertion preflight also
precede history mutation.

One native Undo group records insertion, the map replacement and a final
selection companion. The companion runs first on Undo so an empty original
selection is restored before native removal can choose a fallback. Undo
restores the old tree, map and ordered layer selection; Redo retains the
same copied native objects and identities. The returned root is borrowed
from the image and cannot be retained across subsequent edits or Undo.

Ordinary refusals leave the image and its existing Redo history unchanged.
Unexpected native failure after the commit begins is reported explicitly;
the command does not promise recovery from fatal allocation failures or
forbidden external mutation, and does not rewrite native Undo stacks.

## Verification

An independent fixture passes 120 checks on each supported engine, 480
checks in the final matrix. It uses distinct literal sample bytes, permuted
root and child order, a hidden source with partial opacity, a nonempty
partial selection mask and an existing Redo branch. It verifies fresh
identities, exact one-step Undo, repeated Redo identity, restoration of
ordered plural and empty selection, native XCF reopening and independent mutations
of all four copied planes. Refusals compare complete recorded native state,
including raw samples, map, selection, history and dirty counters.

The attested producer objects and source inputs remained unchanged. The
pinned run has no compiler or runtime warnings. Older-engine tag-cache and
plug-in EOF messages, and master's font/development and cached-XML cleanup
messages, remain in the raw logs. Independent source review found no
important issue under the documented caller contract.

The initial 109-check matrix missed empty selection on a nonempty carrier.
Review identified the native fallback; an independent 120-check run failed
two assertions before the companion fix. The final matrix and repeated
source review close that defect. Earlier runs remain separate evidence.

Evidence is under `/tmp/glims-lab-layer-duplicate`. The fixture does not
inject allocation failures or independently exercise active stroke/filter
handles. These optimized native runs are not sanitizer or leak-freedom
proofs. This module does not yet enable public layered editing or change
the installed app.
