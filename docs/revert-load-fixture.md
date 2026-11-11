# Closing during Revert

The full bundled workflow on Main `5c55b8f` failed three assertions in its
Revert-close fixture. The diagnostic source `371188b` reproduced them: its
400 ms input-queue delay finished before Recorder consent completed. The
real reload then finished successfully before the test's next polling turn.
The test consequently requested Close on the already replaced controller.

Source `76cd9cf` changes only `EngineSmokeTest.swift`. A fixture-owned hold
is queued inside the real Revert handler, after consent and the pending-load
flag, before forwarding the handler. The test observes the hold, requests
Close, observes close intent, and explicitly releases the input queue.
Expiration remains a permanent failure even if cleanup later releases it.
The original pending, close, no-duplicate-adoption, source-preservation and
cleanup assertions remain. Two hold-ordering assertions are added.

The ordinary focused case passes 23 checks on each of GIMP 3.2.8, 3.2.0,
3.0.8 and master, totaling 92. Its trace records Close waiting while the
hold is active, explicit release without expiration, refusal to adopt a
replacement for the closing document, and successful removal. The 3.2.8
case uses the bundled engine with native and Swift build trees denied;
the other cases use their explicit source adapters. Independent source
review found no important issue.

The ordinary full bundled workflow passes 3,233 checks with native and
Swift build trees denied and no forbidden-path/load diagnostics. These
runs use a temporary signed app containing the current debug executable
and the unchanged API173 engine/resources from the earlier assembled
candidate. They establish this fixture and its integrated workflows;
they are not a final release-build or public-distribution claim. Each
owned application exited, the desktop showed no dialogs, and the lease
was released after each bounded run.
