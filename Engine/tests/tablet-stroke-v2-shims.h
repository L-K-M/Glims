/* Test-only forwarders. Only the privately compiled paint.c sees symbol
 * replacement; this header uses the real Core types, not adapter layouts. */
#ifndef GLIMS_TABLET_STROKE_V2_SHIMS_H
#define GLIMS_TABLET_STROKE_V2_SHIMS_H
#include "engine-private.h"
#include "paint/gimppaintcore.h"
#include "paint/gimppaintoptions.h"

gboolean glims_test_tablet_start (GimpPaintCore *, GList *, GimpPaintOptions *,
                                 const GimpCoords *, GError **);
void glims_test_tablet_paint (GimpPaintCore *, GList *, GimpPaintOptions *,
                             GimpPaintState, guint32);
void glims_test_tablet_interpolate (GimpPaintCore *, GList *, GimpPaintOptions *,
                                   const GimpCoords *, guint32);
#endif
