#ifndef GLIMS_BRUSH_FINGERPRINT_H
#define GLIMS_BRUSH_FINGERPRINT_H

#include "engine-private.h"

/* An owned, lowercase SHA-256 hex digest (g_free), or NULL for a brush
 * outside the supported subset. Call on the engine thread with a live
 * brush whose data stays stable for the call. This identifies brush
 * content; paint options and engine behavior are separate replay inputs. */
gchar *glims_brush_fingerprint (GimpBrush *brush);

#endif
