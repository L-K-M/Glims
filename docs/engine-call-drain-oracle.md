# Accepted RPC caller lifetime oracle

This fixture tests the real `glims_engine_call` and facade `stop` transport
without starting GIMP, running a plug-in or presenting any GUI. Root observed
the accepted-caller failure before the fix and reran the unchanged fixture
afterward. The separate 5037 ms and 10146 ms full-engine shutdown outliers
remain unlocalized; this change does not claim to explain or fix them. The
5037 ms binary repeated in 202 ms before this fix. The `<5000` assertion stays.

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

Scheduling wrappers cover both old `g_main_context_invoke_full` and current
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
remain. Root's actual old baseline completed **13 checks with two lifetime
failures**; its admission and safe-cleanup controls passed. The same frozen
fixture with production fix `4d39894` completed **13/0**, observing a live
worker probe while the caller was held, stop still pending and all three
unsafe-cleanup counts zero. Both runs had empty stderr. The original C,
shim header and driver are byte-identical to `33bbc06`.

The independent [queued-admission fixture](engine-call-admission-oracle.md)
then passed **20/0** with current private producer
`.build/call-drain-adapters/GIMP_3_2_8`. It witnessed registered counts one
and two, `stopping` under the real mutex, A's original OK, and NOT_RUNNING
for queued B and late C with zero callback executions; C attached no source.
The original 13-check baseline and GREEN used the older immutable foreign-field
producer; the separate 20-check run used the current call-drain producer.

Full native conformance subsequently passed on all four supported engines:

| Engine | Checks | Failures |
| --- | ---: | ---: |
| GIMP 3.2.8 | 1,917 | 0 |
| GIMP 3.2.0 | 1,917 | 0 |
| GIMP 3.0.8 | 1,703 | 0 |
| master | 1,917 | 0 |

The unchanged running-plug-in stop assertion passed in each run. The 3.0.8 log
retains its cache-queue warning and two leaked GeglBuffers; earlier context
and batch logs already contain cache-queue/leak diagnostics (three buffers).
Master retains cached-XML cleanup warnings. Passing checks do not establish
a clean resource audit, and this slice does not resolve those diagnostics.

## Current ownership contract

External callers register and attach their source under the existing engine
mutex. Ordinary RPC priority remains G_PRIORITY_DEFAULT. Closing admission
refuses unstarted registered calls with NOT_RUNNING. Running calls retain
their native results and acknowledge from their caller thread after consuming
the result; dispatch completion alone does not end the caller's lifetime.

The sole external stop owner closes admission, dispatches high-priority native
plug-in cancellation while keeping the outer context alive, waits for caller
acknowledgements, then dispatches final quit and joins before freeing storage.
Direct internal engine-thread continuations keep their existing behavior.
Public event callbacks remain forbidden from calling back into the engine.

The owner must prevent fresh raw-pointer lifetime entry racing stop and invoke
stop once from an external thread. The late-C oracle deliberately keeps the
engine alive with A while checking closed admission; it grants no post-free
handle guarantee. Stale handles after stop/free, concurrent stop owners and
arbitrary entrants suspended before registration remain outside this contract.
No global handle registry was added.

## Isolated validation commands

Choose an already built immutable GIMP 3.2.8 producer, for example the current
private call-drain prefix:

```sh
python3 -I scripts/test-engine-call-drain.py build \
  --producer .build/call-drain-adapters/GIMP_3_2_8 \
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
bounded process-group cleanup.

Local retained evidence is under `/tmp/glims-completion`: old13
`engine-call-drain-red-work-current`, GREEN13
`engine-call-drain-green-work-4d39894`, GREEN20
`engine-call-admission-work-current`, and the four
`engine-call-drain-general-<ref>-20261110` directories. Their build/run
manifests, binary/input/log hashes and exact results were checked without
rerunning any engine. The original source-freeze document hash is historical:
this document was intentionally updated with runtime evidence; executable
fixture inputs remain unchanged. Independent review is in progress, with CI,
PR and integration pending.

## Main165 integration and driver interruption regression

After integrating merged batch Rasterize, fresh private slot165 producers
pass all four conformance suites: 1,917 checks each on 3.2.8, 3.2.0 and
master, and 1,703 on 3.0.8. The reported final running-plug-in stop samples
were 57, 92, 51 and 113 ms respectively. These new samples do not explain
the retained earlier outliers.

Completed review found a Python test-driver cleanup gap: a second signal
could escape cleanup, and a signal while Popen returned could precede child
ownership. Eight deterministic fake-child cases first failed on both old
drivers. The corrected drivers install nonraising TERM and INT handlers
before spawning, record cancellation, retain ownership through bounded
TERM/KILL/reaping and always restore both dispositions. All eight now pass,
as do all 62 current packaging tests. The original native C fixtures are
byte-identical. Fresh private linkage against the slot165 producer passes
the 13-check drain and 20-check admission oracles. Driver/source hashes are
bound to their new manifests; older manifests and producer bytes remain
preserved. Latest-head hosted CI and review remain pending after this fix.
