# Accepted RPC caller lifetime oracle

This fixture tests the real `glims_engine_call` and facade `stop` transport
without starting GIMP, running a plug-in or presenting any GUI. It does not
explain the earlier 5037 ms shutdown sample. The unchanged binary repeated
that full-engine shutdown in 202 ms; the existing `<5000` assertion stays.

`Engine/tests/engine-call-drain-tests.c` constructs one synthetic engine with
the authoritative private types, a real default GLib context/loop/thread,
three empty owned tables, and test-owned `Gimp`/empty plug-in-manager storage.
The synthetic worker runs only that loop. It never calls native initialization,
shutdown or a GObject method on those raw test-owned structs. Actual stop
reads the empty manager and uses the actual adapter transport and cleanup.

One real no-op RPC waits until its designated caller enters the real engine
condition wait. After a genuine wake, the narrow test wait shim unlocks that
engine mutex, parks the caller on an independent fixture gate, then reacquires
the engine mutex before returning to transport code. This models a delayed
waiter before mutex reacquisition while preserving its stack call and result.
No private call layout is copied or inspected.

A second real thread calls facade stop. The private transport compilation
redirects only condition-wait, mutex/condition clear, final free and source
scheduling symbols to the test implementations declared in
`Engine/tests/engine-call-drain-shims.h`. Every unrelated call/free passes
through to the real function. Destruction of this engine's control storage
while the designated caller is held is recorded and suppressed. The fixture
releases and joins that caller before performing the suppressed releases
exactly once. Old code can therefore fail honestly without a use-after-free,
signal or crash report.

Scheduling wrappers cover both old `g_main_context_invoke_full` and proposed
explicit `g_source_attach` dispatch. They signal a separate scheduler thread
after stop schedules its first lifecycle operation. That thread attaches a
low-priority idle probe outside the production admission-lock execution.
The fixture waits for either that probe or actual stop completion, with a
bounded watchdog. Timeout is always a failed prerequisite, never success.

Old stop quits its context and finishes cleanup while the caller is held;
the probe does not run and unsafe cleanup attempts are recorded. A two-phase
stop that preserves the context until caller acknowledgement lets the probe
execute on the worker while the caller is held and stop is pending. After
the caller is released, both transport and stop must finish, every tracked
resource must be physically released exactly once, and no probe source may
remain. There are **13 check sites** on the complete path. The intended old
baseline has two failed lifetime assertions and passing admission/cleanup
controls. These counts and outcomes are source expectations, not runtime
evidence until independently compiled and run.

Only already registered RPC callers are covered. The owner must prevent new
raw-pointer entry after stop begins and invoke stop only once from an external
thread. This does not test stale handles after stop/free, concurrent stop
owners, reentry from native event callbacks, or arbitrary new entry racing
the control block's initial lifetime registration. No global handle registry
or production implementation is part of this tests-only slice.

## Isolated validation commands

Root chooses an already built immutable Main/API164 GIMP 3.2.8 producer:

```sh
python3 -I scripts/test-engine-call-drain.py build \
  --producer /absolute/immutable-main164/GIMP_3_2_8 \
  --out /tmp/glims-engine-call-drain-build

python3 -I scripts/test-engine-call-drain.py run \
  --binary /tmp/glims-engine-call-drain-build/engine-call-drain-tests \
  --work /tmp/glims-engine-call-drain-work --timeout 60
```

The driver compiles only the fixture and a private `Engine/engine.c` object
with the six symbol replacements, links the producer objects **excluding
`engine.o`**, and never relinks a producer library. Initialization-only engine
path defines contain explicit unused literals; no native prefix is changed.
It hashes all producer response/object inputs and declared source/header
inputs before and after, retains build commands and binary hash in
`build.json`, and executes only through the separate `run` command. Runtime
uses private HOME/cache/config/data/state/runtime/GIMP/tmp directories and
bounded process-group cleanup. This slice has not compiled or run either
command; Root must first witness the old baseline before authorizing a fix.
