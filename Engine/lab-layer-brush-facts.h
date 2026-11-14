#ifndef GLIMS_LAB_LAYER_BRUSH_FACTS_H
#define GLIMS_LAB_LAYER_BRUSH_FACTS_H

#include "engine-private.h"

/* Engine-thread capture of effective brush identity, mask and settings.
 * The caller owns a zeroed facts struct with a full struct_size. On success
 * the returned strings are owned by the caller; failure leaves it untouched.
 * The logical target and selection are bound separately by the Recorder. */
gboolean glims_lab_layer_brush_capture_facts (GlimsEngine *engine, GimpImage *image,
                                               GimpPaintOptions *options,
                                               const GlimsLabLayerBrushSettings *settings,
                                               GlimsStrokeCaptureFacts *facts);

#endif
