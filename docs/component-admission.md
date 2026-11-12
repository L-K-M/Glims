# Component operation admission

Multichannel documents are adopted only after the complete native storage layout
validates. The factory, XCF loader and duplicate-image path share that admission.
Damaged known metadata refuses without publishing an ordinary grayscale image.
The storage foundation merged in PR #227; public editor work is in PR #229.

`facade-operations.def` binds all 180 public function fields in header order.
Its descriptors specify typed image, filter-session, stroke-session, image-free
or all-images ownership. The 171 transported calls enter a common serialized
admission function before invoking the backend, including calls originating on
the engine thread itself. The nine direct lifecycle/version/allocation-release
functions remain explicit exceptions. Slot 180 appends document creation;
existing public function order remains unchanged.

An internal `component_document` flag is set from validated storage at adoption.
Marked-image calls with COMPONENT policy revalidate at each operation boundary.
The allowlist covers reads needed by document presentation, XCF save/copy,
history and Undo/Redo, duplication, shape/selection-mask operations, channel
selection and attributes, the derived renderer and three scalar paint cores.
Channel commands additionally restrict their individual subcommands: structural
channel changes and returning to a layer target remain unavailable.

Every operation still classified ORDINARY refuses marked documents.
Close, filter abort, stroke end and procedure cancellation remain available.
Image-free resource/catalog operations continue to work. Ordinary documents
remain editable alongside a marked witness. Arbitrary procedure execution checks
all open images because an explicit image argument cannot bound its effects.
Clone/Heal begin calls capture the source drawable owner independently of the
destination, and continuation checks the destination plus every retained source
in native source options. Captured filter-map inputs are also explicit sources.
Component stroke continuations require a validated component core and a target
that still belongs to its original native planes. No operation is certified
scalar-safe merely because a native channel accepts it. New component routes
must have independent numeric and persistence tests before joining the allowlist.

The metadata read wrappers clear their documented owned outputs before admission.
Layer duplication uses an invocation receipt so an admission refusal clears
valid output vectors, while an admitted backend can capture overlapping input
first and preserve any documented partial-result prefix on late failure.
The receipt stays on the synchronously acknowledged call's stack.

`check-facade-policy.py` compares the manifest with every public header member,
checks wrapper operation identity and typed target/source capture, and rejects
raw transport bypasses. Its mutation tests demonstrate missing entries, a wrong
operation ID, image-free spoofing, source omissions and bypasses failing the gate.
This supplements runtime tests; source parsing is not semantic proof of all
future edits.

The pinned fixture passed 204 initial checks. Direct review found missing output
resets and a live cross-image source continuation gap; five added assertions
reproduced them. The corrected pinned fixture passes 214 checks, including real
queued/inline refusals, exact witness pixels/Undo, destination-file preservation,
overlapping arrays, live sessions and cleanup. Follow-up direct review closed
both findings. The single independent helper timed out without a verdict; it is
not counted as a completed clean review. Rebuilt adapter conformance, all
214 admission checks and full app checks pass on all four engines. Latest
native CI passes; PR #228 merged at `3965d22`. That foundation alone activated
no public mode. The subsequent public editor has separate qualification in the
current plan and its own native/window fixtures.
