#ifndef GLIMS_PLATE_CMYK_PREVIEW_H
#define GLIMS_PLATE_CMYK_PREVIEW_H
#include "plate-storage.h"
#include <cairo.h>
#include "gegl/gimptilehandlervalidate.h"

GimpTileHandlerValidate *glims_plate_cmyk_preview_new (const GlimsPlateStorage *storage);
/* Engine thread, before region validation. Failed reads invalidate all derived
 * pixels on the next read so cached failure placeholders cannot escape. */
void glims_plate_cmyk_preview_prepare (GimpTileHandlerValidate *validate,
                                       const GeglRectangle *extent);
gboolean glims_plate_cmyk_preview_succeeded (GimpTileHandlerValidate *validate);
#endif
