/* Forced into only the private engine.c compilation. The harness is compiled
 * without symbol defines and its implementations call the real GLib functions. */
#ifndef GLIMS_TEST_CALL_DRAIN_SHIMS_H
#define GLIMS_TEST_CALL_DRAIN_SHIMS_H
#include <glib.h>
void  glims_test_call_drain_cond_wait (GCond *condition, GMutex *mutex);
void  glims_test_call_drain_mutex_clear (GMutex *mutex);
void  glims_test_call_drain_cond_clear (GCond *condition);
void  glims_test_call_drain_free (gpointer pointer);
void  glims_test_call_drain_invoke (GMainContext *context, gint priority,
                                   GSourceFunc function, gpointer data,
                                   GDestroyNotify notify);
guint glims_test_call_drain_attach (GSource *source, GMainContext *context);
#endif
