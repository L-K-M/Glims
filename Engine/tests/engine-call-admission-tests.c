/* Independent queued/late admission contract. Real transport and stop with
 * authoritative synthetic GLib/GIMP storage, no GIMP startup or GUI. */
#include "engine-private.h"
#include "engine-call-admission-shims.h"
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
  GMainContext *context;
  GMainLoop *loop;
  GThread *worker, *first, *queued, *late, *stopper;
  gboolean worker_ready, worker_exited;
  gboolean first_entered, release_first, abort;
  gboolean first_returned, queued_returned, late_returned, stop_finished;
  gboolean queued_attached, stop_attached;
  gboolean first_on_worker;
  guint first_executions, queued_executions, late_executions;
  guint first_attachments, queued_attachments, late_attachments;
  GlimsStatus first_status, queued_status, late_status;
  guint sources[16], source_count;
  gboolean invalid_source;
} Fixture;

static Fixture fixture;
static const GlimsEngineAPI *api;
static guint checks, failures;
#define CHECK(condition, title) do { gboolean ok_ = (condition); checks++; \
  printf ("%s %s\n", ok_ ? "ok  " : "FAIL", title); if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(condition, title) do { gboolean needed_ = (condition); CHECK (needed_, title); \
  if (!needed_) goto cleanup; } while (0)

static gboolean
wait_flag (const gboolean *flag)
{
  gint64 deadline = g_get_monotonic_time () + WAIT_US;
  g_mutex_lock (&fixture.mutex);
  while (!*flag && !fixture.abort)
    if (!g_cond_wait_until (&fixture.condition, &fixture.mutex, deadline)) break;
  gboolean result = *flag;
  g_mutex_unlock (&fixture.mutex);
  return result;
}

/* This wrapper may run under admission lock. It performs the real attach and
 * only signals an independent fixture condition; it dispatches no callback.
 * Fixture-lock sections never acquire the engine mutex, preventing inversion. */
guint
glims_test_call_admission_attach (GSource *source, GMainContext *context)
{
  guint id = g_source_attach (source, context);
  GThread *thread = g_thread_self ();
  g_mutex_lock (&fixture.mutex);
  if (!id || fixture.source_count == G_N_ELEMENTS (fixture.sources)) fixture.invalid_source = TRUE;
  else fixture.sources[fixture.source_count++] = id;
  if (thread == fixture.first) fixture.first_attachments++;
  if (thread == fixture.queued) { fixture.queued_attachments++; fixture.queued_attached = id != 0; }
  if (thread == fixture.late) fixture.late_attachments++;
  if (thread == fixture.stopper && id) fixture.stop_attached = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return id;
}

static gboolean
first_is_held (void)
{
  g_mutex_lock (&fixture.mutex);
  gboolean held = fixture.first_entered && !fixture.release_first && !fixture.first_returned;
  g_mutex_unlock (&fixture.mutex);
  return held;
}

/* Called only while A guarantees lifetime, with no fixture mutex held. */
static gboolean
admission_is (gboolean stopping, guint callers)
{
  g_mutex_lock (fixture.engine_mutex);
  gboolean result = fixture.engine->stopping == stopping && fixture.engine->registered_callers == callers;
  printf ("OBS stopping=%d registered_callers=%u expected_stopping=%d expected_callers=%u\n",
      fixture.engine->stopping, fixture.engine->registered_callers, stopping, callers);
  g_mutex_unlock (fixture.engine_mutex);
  return result;
}

static gpointer
worker (gpointer unused)
{
  (void) unused;
  gboolean acquired = g_main_context_acquire (fixture.context);
  g_mutex_lock (&fixture.mutex);
  fixture.worker = g_thread_self ();
  fixture.worker_ready = acquired;
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
hold_first (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.first_executions++;
  fixture.first_on_worker = engine == fixture.engine && g_thread_self () == fixture.worker &&
      g_main_context_is_owner (fixture.context);
  fixture.first_entered = TRUE;
  g_cond_broadcast (&fixture.condition);
  /* No engine mutex and no nested context iteration: B really remains queued.
   * The external driver bounds failure cleanup if its controller disappears. */
  while (!fixture.release_first && !fixture.abort) g_cond_wait (&fixture.condition, &fixture.mutex);
  g_mutex_unlock (&fixture.mutex);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
queued_callback (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.queued_executions++;
  g_mutex_unlock (&fixture.mutex);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
late_callback (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  g_mutex_lock (&fixture.mutex);
  fixture.late_executions++;
  g_mutex_unlock (&fixture.mutex);
  return GLIMS_STATUS_OK;
}

static gpointer
first_caller (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex); fixture.first = g_thread_self (); g_mutex_unlock (&fixture.mutex);
  GlimsStatus status = glims_engine_call (fixture.engine, hold_first, NULL);
  g_mutex_lock (&fixture.mutex);
  fixture.first_status = status; fixture.first_returned = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static gpointer
queued_caller (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex); fixture.queued = g_thread_self (); g_mutex_unlock (&fixture.mutex);
  GlimsStatus status = glims_engine_call (fixture.engine, queued_callback, NULL);
  g_mutex_lock (&fixture.mutex);
  fixture.queued_status = status; fixture.queued_returned = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static gpointer
late_caller (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex); fixture.late = g_thread_self (); g_mutex_unlock (&fixture.mutex);
  GlimsStatus status = glims_engine_call (fixture.engine, late_callback, NULL);
  g_mutex_lock (&fixture.mutex);
  fixture.late_status = status; fixture.late_returned = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static gpointer
stopper (gpointer unused)
{
  (void) unused;
  g_mutex_lock (&fixture.mutex); fixture.stopper = g_thread_self (); g_mutex_unlock (&fixture.mutex);
  api->stop (fixture.engine);
  g_mutex_lock (&fixture.mutex);
  fixture.stop_finished = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  return NULL;
}

static void
release_first (void)
{
  g_mutex_lock (&fixture.mutex);
  fixture.release_first = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
}

int main (void);
int
main (void)
{
  GThread *worker_thread = NULL, *first_thread = NULL, *queued_thread = NULL, *late_thread = NULL, *stop_thread = NULL;
  gboolean complete_path = FALSE;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api) return 2;
  g_mutex_init (&fixture.mutex); g_cond_init (&fixture.condition);
  fixture.engine = g_new0 (GlimsEngine, 1);
  fixture.engine_mutex = &fixture.engine->lock;
  g_mutex_init (&fixture.engine->lock); g_cond_init (&fixture.engine->cond);
  fixture.context = g_main_context_ref (g_main_context_default ());
  fixture.loop = g_main_loop_new (fixture.context, FALSE);
  fixture.engine->loop = fixture.loop;
  Gimp *gimp = g_new0 (Gimp, 1);
  GimpPlugInManager *manager = g_new0 (GimpPlugInManager, 1);
  gimp->plug_in_manager = manager; manager->gimp = gimp;
  fixture.engine->gimp = gimp;
  fixture.engine->images = g_hash_table_new (g_direct_hash, g_direct_equal);
  fixture.engine->strokes = g_hash_table_new (g_direct_hash, g_direct_equal);
  fixture.engine->filters = g_hash_table_new (g_direct_hash, g_direct_equal);
  fixture.engine->user_directory = g_strdup ("unused-admission-fixture");
  fixture.engine->cache_directory = g_strdup ("unused-admission-fixture");
  fixture.engine->started = TRUE;
  fixture.first_status = fixture.queued_status = fixture.late_status = GLIMS_STATUS_FAILED;
  worker_thread = g_thread_new ("admission-worker", worker, NULL);
  fixture.engine->thread = worker_thread;
  NEED (wait_flag (&fixture.worker_ready), "synthetic worker owns the real GLib context without native startup");
  first_thread = g_thread_new ("running-caller-A", first_caller, NULL);
  NEED (wait_flag (&fixture.first_entered), "first registered callback executes and holds the worker outside the engine mutex");
  NEED (first_is_held () && admission_is (FALSE, 1), "A's actual registration and live callback guarantee engine lifetime before stop");
  queued_thread = g_thread_new ("queued-caller-B", queued_caller, NULL);
  NEED (wait_flag (&fixture.queued_attached), "B attaches a real queued transport source while A holds the worker");
  NEED (first_is_held () && admission_is (FALSE, 2), "the real engine mutex witnesses exactly two registered external callers before stop");
  g_mutex_lock (&fixture.mutex);
  gboolean queued_unstarted = fixture.queued_executions == 0 && !fixture.queued_returned && fixture.queued_attachments == 1;
  g_mutex_unlock (&fixture.mutex);
  CHECK (queued_unstarted, "B is genuinely queued and its callback has not executed or returned");
  stop_thread = g_thread_new ("admission-stop", stopper, NULL);
  NEED (wait_flag (&fixture.stop_attached), "real stop attaches its first private lifecycle control while A still holds the worker");
  NEED (first_is_held () && admission_is (TRUE, 2), "stopping is witnessed under the real lock with A and queued B still registered");
  late_thread = g_thread_new ("late-caller-C", late_caller, NULL);
  NEED (wait_flag (&fixture.late_returned), "late C returns before A is released rather than waiting for a queued dispatch");
  g_mutex_lock (&fixture.mutex);
  gboolean late_refused = fixture.late_status == GLIMS_STATUS_NOT_RUNNING && fixture.late_executions == 0;
  gboolean late_not_attached = fixture.late_attachments == 0;
  g_mutex_unlock (&fixture.mutex);
  CHECK (late_refused, "late C receives NOT_RUNNING without executing its callback while the engine is known alive");
  CHECK (late_not_attached, "late C attaches no source after stop closes admission");
  NEED (first_is_held () && admission_is (TRUE, 2), "late rejection leaves the registration count at two while A still guarantees lifetime");
  release_first ();
  /* No engine dereference or new request follows this lifetime release. */
  NEED (wait_flag (&fixture.first_returned), "A finishes after its explicit release");
  NEED (wait_flag (&fixture.queued_returned), "B receives its terminal queued-call result");
  NEED (wait_flag (&fixture.stop_finished), "stop waits for accepted callers and finishes cleanly");
  complete_path = TRUE;
cleanup:
  /* If C missed its deadline before attaching, it may be descheduled before
   * initial transport entry. Keep A's lifetime hold until that thread leaves;
   * releasing A first could turn a failed prerequisite into a stale entry.
   * A broken C that queues meanwhile can leave this failure cleanup waiting;
   * the driver's process watchdog then fails it without freeing live storage. */
  if (late_thread) {
    g_mutex_lock (&fixture.mutex);
    gboolean late_may_enter = !fixture.late_returned && fixture.late_attachments == 0;
    g_mutex_unlock (&fixture.mutex);
    if (late_may_enter) { g_thread_join (late_thread); late_thread = NULL; }
  }
  release_first ();
  g_mutex_lock (&fixture.mutex);
  fixture.abort = TRUE;
  g_cond_broadcast (&fixture.condition);
  g_mutex_unlock (&fixture.mutex);
  if (first_thread) g_thread_join (first_thread);
  if (queued_thread) g_thread_join (queued_thread);
  if (late_thread) g_thread_join (late_thread);
  if (stop_thread) g_thread_join (stop_thread);
  else if (fixture.worker_ready) {
    api->stop (fixture.engine);
    fixture.stop_finished = TRUE;
  } else if (worker_thread) g_thread_join (worker_thread);
  if (complete_path) {
    CHECK (fixture.first_status == GLIMS_STATUS_OK && fixture.first_executions == 1 && fixture.first_on_worker && fixture.first_attachments == 1,
           "A preserves its original successful result and exactly one callback execution on the worker");
    CHECK (fixture.queued_status == GLIMS_STATUS_NOT_RUNNING && fixture.queued_executions == 0 && fixture.queued_attachments == 1,
           "registered queued B returns NOT_RUNNING and never executes its callback");
    CHECK (fixture.late_status == GLIMS_STATUS_NOT_RUNNING && fixture.late_executions == 0 && fixture.late_attachments == 0,
           "late C remains refused without callback execution or transport attachment");
    CHECK (fixture.first_returned && fixture.queued_returned && fixture.late_returned && fixture.worker_exited && fixture.stop_finished,
           "all caller worker and stop threads drain before fixture-owned state is released");
  }
  gboolean no_sources = !fixture.invalid_source;
  for (guint i = 0; i < fixture.source_count; i++) {
    GSource *source = g_main_context_find_source_by_id (fixture.context, fixture.sources[i]);
    if (source) { no_sources = FALSE; g_source_destroy (source); }
  }
  if (complete_path) CHECK (no_sources, "every observed real transport source is removed without leftover callbacks");
  if (!fixture.stop_finished) {
    g_hash_table_unref (fixture.engine->images); g_hash_table_unref (fixture.engine->strokes); g_hash_table_unref (fixture.engine->filters);
    g_free (fixture.engine->user_directory); g_free (fixture.engine->cache_directory);
    g_mutex_clear (&fixture.engine->lock); g_cond_clear (&fixture.engine->cond); g_free (fixture.engine);
  }
  printf ("OBS A_status=%d B_status=%d C_status=%d executions=%u,%u,%u attachments=%u,%u,%u sources=%u\n",
      fixture.first_status, fixture.queued_status, fixture.late_status,
      fixture.first_executions, fixture.queued_executions, fixture.late_executions,
      fixture.first_attachments, fixture.queued_attachments, fixture.late_attachments, fixture.source_count);
  g_main_loop_unref (fixture.loop); g_main_context_unref (fixture.context);
  g_free (manager); g_free (gimp);
  g_cond_clear (&fixture.condition); g_mutex_clear (&fixture.mutex);
  printf ("%s: %u checks, %u failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}
