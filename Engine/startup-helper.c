#include "startup-helper.h"
#include <gio/gio.h>

typedef struct
{
  GSubprocess *child;
  GMainLoop   *loop;
  gboolean     timed_out;
  gboolean     successful;
} StartupHelper;

static gboolean
terminate_helper (gpointer data)
{
  StartupHelper *helper = data;
  helper->timed_out = TRUE;
  g_subprocess_force_exit (helper->child);
  return G_SOURCE_REMOVE;
}

static void
helper_finished (GObject *source, GAsyncResult *result, gpointer data)
{
  StartupHelper *helper = data;
  /* wait_finish completes only after GIO has collected the child's status.
   * Do not cancel the wait on timeout: it must still reap the killed child. */
  helper->successful = g_subprocess_wait_finish (G_SUBPROCESS (source), result, NULL) &&
                       g_subprocess_get_successful (helper->child);
  g_main_loop_quit (helper->loop);
}

gboolean
glims_run_startup_helper (const gchar *directory,
                          const gchar * const *argv,
                          guint timeout_milliseconds)
{
  GSubprocessLauncher *launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_STDOUT_SILENCE);
  g_subprocess_launcher_set_cwd (launcher, directory);
  GSubprocess *child = g_subprocess_launcher_spawnv (launcher, argv, NULL);
  g_object_unref (launcher);
  if (! child) return FALSE;

  /* The engine owns the default context. A private context permits only the
   * child's completion and deadline here, never queued engine/UI work. */
  GMainContext *context = g_main_context_new ();
  GMainLoop *loop = g_main_loop_new (context, FALSE);
  StartupHelper helper = { .child = child, .loop = loop };
  GSource *deadline = g_timeout_source_new (timeout_milliseconds);
  g_source_set_callback (deadline, terminate_helper, &helper, NULL);
  g_source_attach (deadline, context);
  g_main_context_push_thread_default (context);
  g_subprocess_wait_async (child, NULL, helper_finished, &helper);
  g_main_loop_run (loop);
  g_main_context_pop_thread_default (context);
  g_source_destroy (deadline);
  g_source_unref (deadline);
  g_main_loop_unref (loop);
  g_main_context_unref (context);
  g_object_unref (child);
  return helper.successful && ! helper.timed_out;
}
