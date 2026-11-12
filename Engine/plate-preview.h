/* A derived ink preview. Native component planes remain authoritative. */
#ifndef GLIMS_PLATE_PREVIEW_H
#define GLIMS_PLATE_PREVIEW_H
#include "plate-storage.h"

typedef struct _GlimsPlatePreview GlimsPlatePreview;
void glims_plate_preview_free (GlimsPlatePreview *preview);
gboolean glims_plate_preview_succeeded (GlimsPlatePreview *preview);
/* Engine thread. Revalidates storage and replaces stale graph identities.
 * The borrowed buffer contains straight linear sRGB RGBA. Caller must validate
 * its requested level-0 region before any scaled or single-pixel read, using
 * the ordinary projection validation helper. No document mutation. */
GlimsStatus glims_plate_preview_prepare (GimpImage *image,
                                        GlimsPlatePreview **preview,
                                        GeglBuffer **buffer);
#endif
