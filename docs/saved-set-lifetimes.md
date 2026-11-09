# Fixed saved-set lifetimes

Native fixed item lists watch root containers only. Their removal callback
also parks a weak reference for every removed root, including nonmembers.
A standalone reproduction showed Undo inserting a group into unrelated sets
and nested members remaining as raw addresses after finalization. The
acceptance harness reproduces fourteen membership failures without the fix.

The adapter now captures fixed-set weak identities at image adoption and
when a newly stored set object is introduced. Existing definitions are never
reimported after structural edits. Root and nested container callbacks run
after native bookkeeping; replacement lists contain only original members
still in the current owned tree. Detached originals remain weakly known for
Undo, without retaining them. Finalized members drop out permanently.

Lists are constructed with the public construct-only items property so NULL
means an explicit empty list. Replacements preserve all definition ordering,
including unchanged computed patterns. No native source, private item-list
layout, facade enum or API slot changes. Teardown disconnects the manager
before releasing the image. Internal set-change notifications are emitted
for replacements; no other current engine consumer listens to them. Future
observers must account for these bookkeeping notifications.

The same harness passes on all four engines after the fix, including root
and nested deletion, Undo/Redo/purge, reparenting, identity, exact membership,
ordering, patterns, XCF round trips, explicit empty sets and close. Savepoints
prove one Undo returns structural edits to clean state. The general native
suites pass 1,917 / 1,703 / 1,917 / 1,917 checks. Independent production and
corrected-harness reviews found no verified important remaining issue.

The standalone regression covers layer sets; channel/path definitions use
the same manager but do not yet have dedicated lifetime fixtures. Initial
store checks alone begin in a dirty fixture; structural bookkeeping also has
the stronger Undo-to-clean savepoint checks. This change does not expose a
saved-set command or provide Undo for explicit set definition edits.

The baseline was recompiled with its matching producer checkout headers
(`--producer-checkout`), avoiding mixed private struct definitions when the
adapter adds its manager pointer. It still reproduces the same fourteen
failures; fixed-producer builds use this checkout's matching headers.
