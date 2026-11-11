/* Private adapter test only. All wrappers forward to real native Core. */
#ifndef GLIMS_TABLET_V2_UI_TELEMETRY_H
#define GLIMS_TABLET_V2_UI_TELEMETRY_H
#include "engine-private.h"
#include "paint/gimppaintcore.h"
#include "paint/gimppaintoptions.h"
gboolean glims_test_tablet_ui_start (GimpPaintCore *, GList *, GimpPaintOptions *,
                                    const GimpCoords *, GError **);
void glims_test_tablet_ui_paint (GimpPaintCore *, GList *, GimpPaintOptions *,
                                GimpPaintState, guint32);
void glims_test_tablet_ui_interpolate (GimpPaintCore *, GList *, GimpPaintOptions *,
                                      const GimpCoords *, guint32);
#endif
