/* Real adapter transport/stop, with a synthetic GLib worker. No GIMP startup,
 * native operation, GUI, copied private layout, deliberate UAF or signal. */
#include "engine-private.h"
#include "engine-call-drain-shims.h"
#include "core/gimp.h"
#include "plug-in/gimppluginmanager.h"
#include <stdio.h>

#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

#define WAIT_US (10 * G_TIME_SPAN_SECOND)
typedef struct {
  GMutex mutex;
  GCond condition;
  GlimsEngine *engine;
  GMutex *engine_mutex;
  GCond *engine_condition;
  GMainContext *context;
  GMainLoop *loop;
  GThread *worker, *caller, *stopper;
  gboolean worker_ready, worker_failed, worker_exited;
  gboolean caller_waiting, caller_held, release_caller, caller_returned;
  gboolean callback_returned, callback_on_worker;
  guint callback_count;
  GlimsStatus caller_status;
  gboolean stop_finished, abort;
  gboolean probe_requested, probe_attached, probe_fired;
  gboolean probe_saw_held, probe_saw_stop_pending, probe_on_worker;
  GMainContext *probe_context;
  guint probe_id;
  guint mutex_attempts, condition_attempts, free_attempts;
  guint unsafe_mutex, unsafe_condition, unsafe_free;
  gboolean mutex_suppressed, condition_suppressed, free_suppressed;
  guint mutex_releases, condition_releases, engine_releases;
} Fixture;

static Fixture fixture;
static const GlimsEngineAPI *api;
static guint checks, failures;
#define CHECK(condition, title) do { gboolean ok_ = (condition); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", title); if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(condition, title) do { gboolean needed_ = (condition); CHECK (needed_, title); \
  if (!needed_) goto cleanup; } while (0)

/* Every fixture wait uses this independent mutex/condition. No test wait holds
 * the engine mutex, except the normal real transport condition-wait protocol. */
static gboolean
wait_flag (const gboolean *flag)
{
  gint64 deadline = g_get_monotonic_time () + WAIT_US;
  gboolean result;
  g_mutex_lock (&fixture.mutex);
  while (!*flag && !fixture.abort)
    if (!g_cond_wait_until (&fixture.condition, &fixture.mutex, deadline)) break;
  result = *flag;
  g_mutex_unlock (&fixture.mutex);
  return result;
}

static gboolean
wait_outcome (void)
{
  gint64 deadline = g_get_monotonic_time () + WAIT_US;
  g_mutex_lock (&fixture.mutex);
  while (!fixture.probe_fired && !fixture.stop_finished && !fixture.abort)
    if (!g_cond_wait_until (&fixture.condition, &fixture.mutex, deadline)) break;
  gboolean result = fixture.probe_fired || fixture.stop_finished;
  g_mutex_unlock (&fixture.mutex);
  return result;
}

void
glims_test_call_drain_cond_wait (GCond *condition, GMutex *mutex)
{
  gboolean selected = condition == fixture.engine_condition && mutex == fixture.engine_mutex &&
      g_thread_self () == fixture.caller;
  if (selected) {
    g_mutex_lock (&fixture.mutex);
    fixture.caller_waiting = TRUE;
    g_cond_broadcast (&fixture.condition);
    g_mutex_unlock (&fixture.mutex);
  }
  g_cond_wait (condition, mutex);
  if (!selected) return;

  /* A genuine wake has reacquired the engine mutex. Release it and delay the
   * reacquisition, modeling a waiter descheduled before consuming its result.
   * Do not change the real condition-wait contract presented to engine.c. */
  g_mutex_lock (&fixture.mutex);
  gboolean hold = fixture.callback_returned && !fixture.release_caller && !fixture.abort;
  g_mutex_unlock (&fixture.mutex);
  if (!hold) return;
  g_mutex_unlock (mutex);
  g_mutex_lock (&fixture.mutex);
  fixture.caller_held = TRUE;
  g_cond_broadcast (&fixture.condition);
  while (!fixture.release_caller && !fixture.abort)
    g_cond_wait (&fixture.condition, &fixture.mutex);
  g_mutex_unlock (&fixture.mutex);
  g_mutex_lock (mutex);
  g_mutex_lock (&fixture.mutex);
  fixture.caller_held = FALSE;
  g_mutex_unlock (&fixture.mutex);
}

void
glims_test_call_drain_mutex_clear (GMutex *mutex)
{
  if (mutex != fixture.engine_mutex) { g_mutex_clear (mutex); return; }
  g_mutex_lock (&fixture.mutex);
  fixture.mutex_attempts++;
  gboolean unsafe = fixture.caller_held;
  gboolean retain = unsafe || fixture.condition_suppressed;
  if (unsafe) fixture.unsafe_mutex++;
  if (retain) fixture.mutex_suppressed = TRUE;
  else fixture.mutex_releases++;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  if (!retain) g_mutex_clear (mutex);
}

void
glims_test_call_drain_cond_clear (GCond *condition)
{
  if (condition != fixture.engine_condition) { g_cond_clear (condition); return; }
  g_mutex_lock (&fixture.mutex);
  fixture.condition_attempts++;
  gboolean unsafe = fixture.caller_held;
  gboolean retain = unsafe || fixture.mutex_suppressed;
  if (unsafe) fixture.unsafe_condition++;
  if (retain) fixture.condition_suppressed = TRUE;
  else fixture.condition_releases++;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  if (!retain) g_cond_clear (condition);
}

void
glims_test_call_drain_free (gpointer pointer)
{
  if (pointer != fixture.engine) { g_free (pointer); return; }
  g_mutex_lock (&fixture.mutex);
  fixture.free_attempts++;
  /* Retain the block if any prior engine synchronization clear was suppressed,
   * even if the caller's gate was released between those cleanup operations. */
  gboolean unsafe = fixture.caller_held;
  gboolean retain = unsafe || fixture.mutex_suppressed || fixture.condition_suppressed;
  if (unsafe) fixture.unsafe_free++;
  if (retain) fixture.free_suppressed = TRUE;
  else fixture.engine_releases++;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  if (!retain) g_free (pointer);
}

static void
request_probe (GMainContext *context)
{
  /* This is called from a scheduling shim, possibly under admission lock.
   * It only signals an independent scheduler; it never attaches/dispatches
   * test callbacks or waits for anything while that lock may be held. */
  if (g_thread_self () != fixture.stopper) return;
  g_mutex_lock (&fixture.mutex);
  if (!fixture.probe_requested) {
    fixture.probe_context = g_main_context_ref (context ? context : g_main_context_default ());
    fixture.probe_requested = TRUE;
    g_cond_broadcast (&fixture.condition);
  }
  g_mutex_unlock (&fixture.mutex);
}

void
glims_test_call_drain_invoke (GMainContext *context, gint priority, GSourceFunc function,
                              gpointer data, GDestroyNotify notify)
{
  g_main_context_invoke_full (context, priority, function, data, notify);
  request_probe (context);
}

guint
glims_test_call_drain_attach (GSource *source, GMainContext *context)
{
  guint id = g_source_attach (source, context);
  request_probe (context);
  return id;
}

static gboolean
probe (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.probe_fired = TRUE;
  fixture.probe_saw_held = fixture.caller_held && !fixture.release_caller;
  fixture.probe_saw_stop_pending = !fixture.stop_finished && !fixture.worker_exited;
  fixture.probe_on_worker = g_thread_self () == fixture.worker && g_main_context_is_owner (fixture.context);
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return G_SOURCE_REMOVE;
}

static gpointer
schedule_probe (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex);
  while (!fixture.probe_requested && !fixture.abort) g_cond_wait (&fixture.condition, &fixture.mutex);
  GMainContext *context = fixture.probe_context;
  g_mutex_unlock (&fixture.mutex);
  if (!context) return NULL;

  GSource *source = g_idle_source_new ();
  g_source_set_priority (source, G_PRIORITY_LOW);
  g_source_set_callback (source, probe, NULL, NULL);
  guint id = g_source_attach (source, context);
  g_source_unref (source);
  g_mutex_lock (&fixture.mutex);
  fixture.probe_id = id;
  fixture.probe_attached = id != 0;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static gpointer
worker (gpointer unused)
{
  (void) unused;
  gboolean acquired = g_main_context_acquire (fixture.context);
  g_mutex_lock (&fixture.mutex);
  fixture.worker = g_thread_self ();
  fixture.worker_ready = acquired;
  fixture.worker_failed = !acquired;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  if (acquired) {
    g_main_loop_run (fixture.loop);
    g_main_context_release (fixture.context);
  }
  g_mutex_lock (&fixture.mutex);
  fixture.worker_exited = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static GlimsStatus
accepted_noop (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.callback_count++;
  fixture.callback_on_worker = engine == fixture.engine && g_thread_self () == fixture.worker &&
      g_main_context_is_owner (fixture.context);
  /* Keep the RPC in flight until its caller has entered its real wait. This
   * removes the race where a fast no-op completes before it waits at all. */
  gint64 deadline = g_get_monotonic_time () + WAIT_US;
  while (!fixture.caller_waiting && !fixture.abort)
    if (!g_cond_wait_until (&fixture.condition, &fixture.mutex, deadline)) break;
  gboolean waited = fixture.caller_waiting;
  fixture.callback_returned = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return waited ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static gpointer
caller (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.caller = g_thread_self ();
  g_mutex_unlock (&fixture.mutex);
  GlimsStatus status = glims_engine_call (fixture.engine, accepted_noop, NULL);
  g_mutex_lock (&fixture.mutex);
  fixture.caller_status = status;
  fixture.caller_returned = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static gpointer
stopper (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.stopper = g_thread_self ();
  g_mutex_unlock (&fixture.mutex);
  api->stop (fixture.engine);
  g_mutex_lock (&fixture.mutex);
  fixture.stop_finished = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static void
release_caller (void)
{
  g_mutex_lock (&fixture.mutex);
  fixture.release_caller = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
}

int main (void);
int
main (void)
{
  GThread *worker_thread = NULL, *caller_thread = NULL, *stopper_thread = NULL, *scheduler_thread = NULL;
  gboolean completed_path = FALSE;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api) return 2;
  g_mutex_init (&fixture.mutex); g_cond_init (&fixture.condition);
  fixture.engine = g_new0 (GlimsEngine, 1);
  fixture.engine_mutex = &fixture.engine->lock;
  fixture.engine_condition = &fixture.engine->cond;
  g_mutex_init (fixture.engine_mutex); g_cond_init (fixture.engine_condition);
  fixture.context = g_main_context_ref (g_main_context_default ());
  fixture.loop = g_main_loop_new (fixture.context, FALSE);
  fixture.engine->loop = fixture.loop;
  /* Only quit_loop reads these authoritative structs; the manager is empty.
   * They are raw test-owned storage, never passed to GObject/GIMP methods. */
  Gimp *gimp = g_new0 (Gimp, 1);
  GimpPlugInManager *manager = g_new0 (GimpPlugInManager, 1);
  gimp->plug_in_manager = manager; manager->gimp = gimp;
  fixture.engine->gimp = gimp;
  fixture.engine->images = g_hash_table_new (g_direct_hash, g_direct_equal);
  fixture.engine->strokes = g_hash_table_new (g_direct_hash, g_direct_equal);
  fixture.engine->filters = g_hash_table_new (g_direct_hash, g_direct_equal);
  fixture.engine->user_directory = g_strdup ("unused-transport-fixture");
  fixture.engine->cache_directory = g_strdup ("unused-transport-fixture");
  fixture.engine->started = TRUE;
  fixture.caller_status = GLIMS_STATUS_FAILED;
  worker_thread = g_thread_new ("transport-worker", worker, NULL);
  fixture.engine->thread = worker_thread;
  NEED (wait_flag (&fixture.worker_ready), "synthetic worker owns the actual default GLib context without GIMP startup");
  caller_thread = g_thread_new ("accepted-rpc", caller, NULL);
  NEED (wait_flag (&fixture.caller_held), "a genuinely accepted RPC caller is held after real completion wake before consuming its result");
  g_mutex_lock (&fixture.mutex);
  gboolean accepted = fixture.callback_count == 1 && fixture.callback_on_worker && fixture.callback_returned &&
      fixture.caller_waiting && !fixture.caller_returned;
  g_mutex_unlock (&fixture.mutex);
  NEED (accepted, "exactly one real transport callback completed on its worker while its stack caller still requires the control block");
  scheduler_thread = g_thread_new ("lifetime-probe", schedule_probe, NULL);
  stopper_thread = g_thread_new ("transport-stop", stopper, NULL);
  NEED (wait_flag (&fixture.probe_requested), "real stop schedules its lifecycle operation through invoke or explicit source attachment");
  NEED (wait_outcome (), "a low-priority context probe or actual stop completion establishes the outcome without timeout-as-success");
  g_mutex_lock (&fixture.mutex);
  gboolean live_until_ack = fixture.probe_fired && fixture.probe_saw_held && fixture.probe_saw_stop_pending && fixture.probe_on_worker;
  gboolean cleanup_waited = !fixture.unsafe_mutex && !fixture.unsafe_condition && !fixture.unsafe_free;
  printf ("OBS held=%d probe=%d probe_held=%d stop_finished=%d worker_exited=%d unsafe_mutex=%u unsafe_cond=%u unsafe_free=%u\n",
      fixture.caller_held, fixture.probe_fired, fixture.probe_saw_held, fixture.stop_finished, fixture.worker_exited,
      fixture.unsafe_mutex, fixture.unsafe_condition, fixture.unsafe_free);
  g_mutex_unlock (&fixture.mutex);
  CHECK (live_until_ack, "stop keeps its context alive until the accepted external caller acknowledges its result");
  CHECK (cleanup_waited, "stop does not clear caller synchronization or free its control block while that accepted caller is held");
  release_caller ();
  NEED (wait_flag (&fixture.caller_returned), "releasing the waiter lets its real stack RPC return safely");
  NEED (wait_flag (&fixture.stop_finished), "stop then completes without a live caller or synthetic native work");
  completed_path = TRUE;
cleanup:
  release_caller ();
  g_mutex_lock (&fixture.mutex);
  fixture.abort = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  if (caller_thread) g_thread_join (caller_thread);
  if (stopper_thread) g_thread_join (stopper_thread);
  else if (fixture.worker_ready) {
    /* Failed prerequisites still use the real stop once callers have left. */
    api->stop (fixture.engine);
    fixture.stop_finished = TRUE;
  } else if (worker_thread) g_thread_join (worker_thread);
  if (scheduler_thread) g_thread_join (scheduler_thread);
  /* api_stop owns the worker join; never join the same GThread twice. */
  if (fixture.probe_id) {
    GSource *source = g_main_context_find_source_by_id (fixture.context, fixture.probe_id);
    if (source) g_source_destroy (source);
  }
  if (completed_path) {
    CHECK (fixture.caller_status == GLIMS_STATUS_OK && fixture.callback_count == 1 && fixture.callback_on_worker,
           "accepted caller receives its exact successful result once on the real transport");
    CHECK (fixture.worker_exited && fixture.stop_finished && fixture.caller_returned,
           "caller worker and stop lifetimes all drain before fixture destruction");
  }
  /* Old code's unsafe operations were recorded and suppressed. Finish those
   * exact releases now, after the caller joined, rather than provoke a UAF. */
  if (fixture.mutex_suppressed) { g_mutex_clear (fixture.engine_mutex); fixture.mutex_releases++; }
  if (fixture.condition_suppressed) { g_cond_clear (fixture.engine_condition); fixture.condition_releases++; }
  if (fixture.free_suppressed) { g_free (fixture.engine); fixture.engine_releases++; }
  if (!fixture.stop_finished) {
    g_hash_table_unref (fixture.engine->images); g_hash_table_unref (fixture.engine->strokes); g_hash_table_unref (fixture.engine->filters);
    g_free (fixture.engine->user_directory); g_free (fixture.engine->cache_directory);
    g_mutex_clear (fixture.engine_mutex); g_cond_clear (fixture.engine_condition); g_free (fixture.engine);
  }
  if (completed_path) {
    CHECK (fixture.mutex_attempts == 1 && fixture.condition_attempts == 1 && fixture.free_attempts == 1 &&
        fixture.mutex_releases == 1 && fixture.condition_releases == 1 && fixture.engine_releases == 1,
        "tracked control block and synchronization storage are physically released exactly once including safe baseline cleanup");
    CHECK (!fixture.probe_id || !g_main_context_find_source_by_id (fixture.context, fixture.probe_id),
           "no low-priority fixture source survives worker stop");
  }
  if (fixture.probe_context) g_main_context_unref (fixture.probe_context);
  g_main_loop_unref (fixture.loop); g_main_context_unref (fixture.context);
  g_free (manager); g_free (gimp);
  g_cond_clear (&fixture.condition); g_mutex_clear (&fixture.mutex);
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}
