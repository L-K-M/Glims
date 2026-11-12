#ifndef GLIMS_LAB_BRUSH_CORE_H
#define GLIMS_LAB_BRUSH_CORE_H

#include "engine-private.h"
#include "lab-samples.h"

/* Private physical painter. The caller owns typed target admission and the
 * native start/finish/cancel lifecycle. Options must disable the color
 * applicator and dynamics. Samples always derive from the stroke-start
 * native Undo buffer; generated coverage is accumulated separately. */
GimpPaintCore * glims_lab_brush_core_new (GlimsLabRole role,
                                         GlimsLabFormat format,
                                         double value, double opacity);
/* A failed dab publishes no partial dab. The caller must cancel the entire
 * stroke before returning failure, including any earlier successful dabs. */
const char * glims_lab_brush_core_error (GimpPaintCore *core);

#endif
