#ifndef GLIMS_PLATE_LAB_PREVIEW_H
#define GLIMS_PLATE_LAB_PREVIEW_H

#include "plate-storage.h"
#include <cairo.h>
#include "gegl/gimptilehandlervalidate.h"

/* Owns refs to three exact-format native planes and an immutable transform.
 * Requires validated D50 Lab storage with all axes visible and no profile.
 * Conversion runs at level zero; only the derived linear RGB is mipmapped. */
GimpTileHandlerValidate *glims_plate_lab_preview_new (const GlimsPlateStorage *storage);
/* Engine thread, before region validation. Failed reads invalidate all derived
 * pixels on the next read so cached failure placeholders cannot escape. */
void glims_plate_lab_preview_prepare (GimpTileHandlerValidate *validate,
                                      const GeglRectangle *extent);
gboolean glims_plate_lab_preview_succeeded (GimpTileHandlerValidate *validate);

#endif
