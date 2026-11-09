# Ordered item selection (slots 136/137)

API version remains 1. New append-only slots select/read ordered whole item
lists for layers, channels and paths, using facade-owned kinds and IDs.
Layer behavior delegates to the existing writer/getter; the new batch setter
refuses empty layers. Empty channels restore the prior native layer stack;
empty paths clear paths. Active Quick Mask is an attached channel row and
is allowed; selection masks and per-layer masks are refused as channel rows.

Writes validate cardinality before reading arrays, positive unique attached
same-image IDs, kind and readiness before mutation. Nonempty channels refuse
under floating selections; paths remain independent; layers reuse the
existing floating/mask policy. Exact order is verified, including a pure
reorder that native membership equality otherwise ignores. Borrowed selected
lists are copied immediately, never freed. No pixel, Undo or dirty change.

Root corrected the initial implementation's layer duplication/empty policy.
The first harness also miscounted background layers, compared uninitialized
array tails and expected the wrong empty-layer floating status. Refusal
checks now compare all three native selections. Every engine passes 108
selection checks and general totals 1,917 / 1,703 / 1,917 / 1,917.

Swift whole-selection reads now retry count/fill growth instead of returning
a partial list, for both the legacy layer getter and the new getter. Three
attempts bound retries; malformed IDs/counts and allocation counts over one
million refuse. All 793 units pass, including independently simulated growth,
shrink, repeated-growth refusal and malformed buffers.

Independent review of complete critical bodies found no important issue.
Its Quick Mask documentation question is resolved by targeted runtime checks
on every engine; layer-mask refusal and NULL-output capacity reset are also
covered. Channel/path UI mirrors and command admission must be integrated
before exposing multi-item recall; this backend alone does not close that
work.
