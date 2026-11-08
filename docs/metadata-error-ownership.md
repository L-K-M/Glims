# Metadata error ownership

`glims_fail` consumes its `GError`. Five metadata read/write failure paths
then cleared their caller's dangling pointer again. A forced native setter
failure reproduced an abort on the old adapter. Those calls now transfer
the pointer with `g_steal_pointer`, leaving subsequent cleanup safe.

`python3 scripts/test-metadata-error.py ADAPTER_LIBRARY` builds a test-only
injection library and facade client in a temporary directory. It injects a
unique setter failure and counts both clear/free calls while retaining the
injected error until explicit cleanup. Counting only `g_error_free` cannot
observe GLib's internal call from `g_clear_error`; the initial probe exposed
that test-harness gap. The measured baseline reports two releases and fails;
the fixed adapter reports one. The tests also check error propagation,
readable unchanged history, original values and a subsequent successful edit.
The injection applies only to the child test process and is never bundled.

All four native suites pass on the fixed production code: 1,876 / 1,662 /
1,876 / 1,876 checks. The final nine fault checks pass on each engine.
Independent source review verified all five transfers; its minor history
oracle gap was fixed by checking both history-query return statuses.

A separate conformance failure was diagnosed as BUSY (status 4) when
reopening a linked XCF after its source changed. Multiple live links reload
that file independently, so one blue composite does not mean every reload
has released the engine. The fixture now retries only that documented
admission status for at most ten seconds; other failures stay failures.
