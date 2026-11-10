# Queued and late RPC admission during stop

This separate synthetic native fixture tests real adapter transport admission
and stop at the existing two-phase implementation. It preserves the original
13-check caller-lifetime oracle and production sources exactly. It does not
start GIMP, load a plug-in, execute a native image operation or present GUI.
Initial compilation is specified against an immutable GIMP 3.2.8 producer.

The fixture uses the authoritative private engine/Gimp/empty-manager types
and a real default GLib context, loop and worker. Test-owned raw Gimp storage
is read only for its empty plug-in manager; it is never passed to a GObject
or native lifecycle method. Only a private copy of `Engine/engine.c` gets the
test scheduling symbol replacement. All actual transport and stop behavior
comes from that production source.

The complete successful path contains **20 check sites**:

1. A registers, executes exactly once on the worker and holds that callback
   on an independent condition outside the engine mutex. It does not iterate
   a nested context. The fixture reads its count of one under the real lock.
2. B attaches a genuine transport source while A holds the worker. The
   scheduling wrapper calls real `g_source_attach`, then signals B's actual
   attachment. A real locked read must find exactly two registered callers;
   B must not have executed or returned.
3. The sole stop owner attaches its private lifecycle control. While A still
   guarantees engine lifetime, the real lock must witness `stopping == TRUE`
   and the same two callers. The worker is still held in A, so it cannot yet
   dispatch the cancel control or B.
4. C begins only now. It must return NOT_RUNNING before A is released, with
   zero callback executions and zero source attachments. The real locked
   registration count must remain two. The count is witnessed before and
   after C; the test does not fabricate an internal admission event.
5. Release A. It must retain its original OK and one execution. B must return
   NOT_RUNNING with zero executions. C must remain NOT_RUNNING with zero
   executions/attachments. All caller, stop and worker threads must drain,
   and every observed transport source must have been removed.

Fixture-lock sections never acquire the engine lock, avoiding inversion with
the attach wrapper called under admission lock. No engine fields are read or
new requests submitted after A's release, except controlled cleanup of an
engine whose stop never started. There is no post-free request or stale-handle
probe. The separate 13-check fixture remains the independent control-block
destruction oracle; this fixture needs no condition-wait, clear or free shim.

Every completion deadline is checked and fails on timeout. Cleanup preserves
A's lifetime hold until a delayed C that has not attached leaves initial
entry. If broken admission queues that C during failure cleanup, the isolated
driver's process watchdog fails and terminates the process rather than free
storage under an unresolved caller. Timeout never counts as passing refusal.

## Deferred isolated commands

```sh
python3 -I scripts/test-engine-call-admission.py build \
  --producer .build/call-drain-adapters/GIMP_3_2_8 \
  --out /tmp/glims-engine-call-admission-build

python3 -I scripts/test-engine-call-admission.py run \
  --binary /tmp/glims-engine-call-admission-build/engine-call-admission-tests \
  --work /tmp/glims-engine-call-admission-work --timeout 60
```

The driver compiles only the new harness and a private transport object with
`g_source_attach` redirected to `glims_test_call_admission_attach`, excludes
the immutable producer's `engine.o`, hashes all response/object and declared
source/header inputs before/after, and writes `build.json`. The producer
library is never rebuilt or relinked. Running is a separate explicit command
with private HOME/cache/config/data/state/runtime/GIMP/tmp directories and
bounded process-group cleanup.

Root's actual run at `870e57b` passed **20 checks with zero failures**, using
the current private `.build/call-drain-adapters/GIMP_3_2_8` producer, not the
older foreign-field producer. Recorded results are A=OK, B/C=NOT_RUNNING,
executions 1/0/0, attachments 1/1/0 and four removed transport sources. Stderr
was empty. Build/input/binary hashes and the retained output in
`/tmp/glims-completion/engine-call-admission-work-current` were verified.
The C/shim/driver still match their source freeze; this document's historical
freeze hash changes intentionally for the evidence update. Independent review,
CI and PR integration remain pending.
