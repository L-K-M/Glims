# Private component operation admission

This is an internal prerequisite for future component documents. No new public
mode, conversion, rendering path or document-creation command is enabled.
The native storage foundation is tracked separately in PR #227.

`facade-operations.def` binds all 179 public function fields in header order.
Its descriptors specify typed image, filter-session, stroke-session, image-free
or all-images ownership. The 170 transported calls enter a common serialized
admission function before invoking the backend, including calls originating on
the engine thread itself. The nine direct lifecycle/version/allocation-release
functions remain explicit exceptions. Public struct layouts and function order
are unchanged.

An internal `component_document` flag is false on ordinary image adoption.
Tests set it only on the engine thread. Future public adoption must first
validate native component storage and manage its lifetime across history and
conversion. This change alone does not infer a mode from metadata or admit
private component files for editing.

The initial policy refuses every ordinary image operation on marked documents.
Close, filter abort, stroke end and procedure cancellation remain available.
Image-free resource/catalog operations continue to work. Ordinary documents
remain editable alongside a marked witness. Arbitrary procedure execution checks
all open images because an explicit image argument cannot bound its effects.
Clone/Heal begin calls capture the source drawable owner independently of the
destination, and continuation checks the destination plus every retained source
in native source options. Captured filter-map inputs are also explicit sources.
No operation is certified scalar-safe merely because a native channel accepts it.

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
not counted as a completed clean review. Final rebuilt adapter/app matrices,
latest CI and integration remain pending.
