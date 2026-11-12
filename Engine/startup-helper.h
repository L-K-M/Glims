#ifndef GLIMS_STARTUP_HELPER_H
#define GLIMS_STARTUP_HELPER_H

#include <glib.h>

/* Run the optional preparation child without dispatching engine callbacks.
 * A timed-out child is terminated and reaped before returning FALSE. */
gboolean glims_run_startup_helper (const gchar *directory,
                                    const gchar * const *argv,
                                    guint timeout_milliseconds);

#endif
