#ifndef GLIMS_STROKE_DYNAMICS_FINGERPRINT_H
#define GLIMS_STROKE_DYNAMICS_FINGERPRINT_H

#include "engine-private.h"

/* Engine-thread read of the stroke's actual local dynamics configuration.
 * Return an owned SHA-256 hex string (g_free), or NULL when unsupported.
 * Disabled dynamics need no object. Enabled dynamics must use pressure
 * exclusively for native SIZE; every other output must be disabled. */
gchar *glims_stroke_dynamics_fingerprint (gboolean enabled, GimpDynamics *dynamics);

#endif
