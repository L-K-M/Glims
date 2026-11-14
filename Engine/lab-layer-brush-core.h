#ifndef GLIMS_LAB_LAYER_BRUSH_CORE_H
#define GLIMS_LAB_LAYER_BRUSH_CORE_H

#include "engine-private.h"

/* Private four-plane painter. The caller must admit the logical root, retain
 * the four ordered planes, and own the native start/finish/cancel lifecycle.
 * A failed dab publishes none of that dab; cancel the entire stroke after any
 * error. Options must disable the color applicator; dynamics must be disabled
 * or configured by glims_lab_layer_brush_enable_pressure_size. */
GimpPaintCore *glims_lab_layer_brush_core_new (double lightness, double a,
                                              double b, double opacity);
/* Attach a private linear pressure-to-size dynamics, independent of mutable
 * installed presets. Call before starting the stroke. A caller can disable
 * it with gimp_paint_options_enable_dynamics(options, FALSE); options owns
 * the attached dynamics until replacement or destruction. */
gboolean glims_lab_layer_brush_enable_pressure_size (GimpPaintOptions *options);
const char *glims_lab_layer_brush_core_error (GimpPaintCore *core);
/* Consume the bounds changed since the last call, without changing native
 * Undo bounds. Returns false when there was no new damage. */
gboolean glims_lab_layer_brush_core_take_damage (GimpPaintCore *core, GeglRectangle *damage);

#endif
