# Private logical Lab layer deletion

This engine-thread command removes one explicit logical root and its UUID
map entry. Map membership order is independent of native stacking order;
remaining identities, raw scalar planes and stacking order are preserved.
Removing the last root leaves a valid empty carrier.

After deletion, surviving selected logical roots retain their order. If
none remain selected, the first surviving root in native stacking order is
selected; an empty carrier selects nothing. Internal scalar children are
never after-targets. One Undo restores the complete original ordered native
selection, including empty or scalar-child selections, together with the
original tree and map. Redo repeats the deletion.

Native removal alone cannot preserve that selection contract. The existing
selection companion is the first record inside the deletion Undo group,
so Undo runs it last, after the removed tree returns. The before/after
vectors, replacement map and parasite are staged before history changes.
The removed tree is held through postvalidation even if native history
retention expires immediately.

Admission requires a strict carrier, exact attached root, idle engine and
enabled/unfrozen Undo without an active group. The caller excludes writes,
validation, nested dispatch and external mutation for the entire call.
Ordinary refusals preserve the image and existing Redo. Unexpected native
or fatal failure after commit begins is reported without claiming rollback
or overriding native history policy.

An independent fixture passes 197 checks per supported engine, 788 total.
It covers ordered plural, source-only, scalar-child and empty selections;
last-root removal; permuted map/root/child order; a real partial selection
mask and Redo branch; repeated Undo/Redo identities; XCF reopening; the
256-root case; and exact recorded state preservation on refusal. Source
review found no important issue. Producer inputs and tested bytes remained
unchanged.

Evidence is under `/tmp/glims-lab-layer-delete`. The pinned run is clean;
older-engine tag-cache/plug-in EOF and master's cached-XML/font/development
diagnostics remain recorded. These optimized native checks do not inject
allocation failures, test immediate history expiry or establish arbitrary
leak freedom. Public adoption, layer controls and installed-app qualification
remain separate work.
