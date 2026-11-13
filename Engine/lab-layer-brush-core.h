#ifndef GLIMS_LAB_LAYER_BRUSH_CORE_H
#define GLIMS_LAB_LAYER_BRUSH_CORE_H

#include "engine-private.h"

/* Private four-plane painter. The caller must admit the logical root, retain
 * the four ordered planes, and own the native start/finish/cancel lifecycle.
 * A failed dab publishes none of that dab; cancel the entire stroke after any
 * error. Options must disable the color applicator and brush dynamics. */
GimpPaintCore *glims_lab_layer_brush_core_new (double lightness, double a,
                                              double b, double opacity);
const char *glims_lab_layer_brush_core_error (GimpPaintCore *core);

#endif
