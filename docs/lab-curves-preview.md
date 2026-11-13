# Lab Curves preview ownership

Facade slots 203–206 capture one selected physical Lab axis by native handle,
role and durable UUID. The snapshot owns a private duplicate of all three axes,
the selection and document metadata. Returned preview images are separately
owned copies. A caller may edit or close them without changing the baseline or
the single calculated-image cache.

Apply uses the existing staged component transaction. It first compares every
axis, mask and relevant metadata against the captured source, validates the
axis identity and lock state, and calculates into private storage. It checks
the target again before publication. A changed result creates one Undo step;
an identity result leaves history untouched. Success consumes the token.
Failure and cancellation retain it for retry or explicit cleanup. End refuses
while a cooperative operation owns the engine. Closing an idle image frees its
snapshot. Ink and Lab snapshots share one engine-wide, non-repeating token
counter while retaining separate mode admission and numerical calculations.

The Swift transport checks the appended table extent and all four function
pointers, sends an exact 256-double normalized table, and keeps Lab settings
and captured roles distinct from ink settings. The caller must close a returned
preview image. This change provides transport and native ownership; it does
not yet expose a Lab Curves panel or record Lab Curves actions.

Verification on the pinned engine covers 819 checks: U8/U16/float, all three
roles, fractional selections, independently calculated physical sample values,
identity history, returned-copy mutation, cache isolation, wrong or expired
tokens, malformed requests, late invalid samples, changed source/selection,
busy ownership, cancellation, retargeting and exact Undo/Redo. The token test
first reproduced four failures in the initial separate-counter implementation.
All 1,677 Swift tests pass, including five transport tests with truncated API
tables and controlled callbacks. Four-engine regression execution and
independent review are tracked in the PR; this is not release qualification.

Run the native fixture against a separately built adapter producer:

```sh
python3 -I scripts/test-lab-curves-snapshot.py \
  --adapter-root /absolute/adapter-root --ref GIMP_3_2_8 \
  --output /new/evidence-directory
```

The runner records hashes for the adapter objects, facade/private headers and
both fixture sources, and refuses if an input changes while the test runs.
