/* Private engine-thread physical-Lab row rendering. No image is adopted. */
#ifndef GLIMS_LAB_LAYER_RENDER_H
#define GLIMS_LAB_LAYER_RENDER_H

#include "engine-private.h"

#define GLIMS_LAB_LAYER_RENDER_MAX_WIDTH 256u

typedef struct GlimsLabLayerRender GlimsLabLayerRender;

/* Freshly validates the complete carrier and captures root order, visibility,
 * opacity, dimensions, and owned references to the actual scalar buffers.
 * Buffers remain LIVE: this is not an immutable image snapshot. No borrowed
 * image/layer pointers survive construction. Caller keeps the image unchanged
 * during construction. Serialized ordinary writes into these SAME pixel buffers
 * are visible to subsequent rows and permitted; no coherent whole-image snapshot
 * is promised across calls. Discard/recapture after topology, group attributes,
 * geometry, format, Undo or buffer replacement, and before image close or engine
 * shutdown. All native writes must finish before a row read starts.
 * Returns NULL for invalid/unsupported carriers or allocation failure. */
GlimsLabLayerRender *glims_lab_layer_render_new (GimpImage *image);
void glims_lab_layer_render_free (GlimsLabLayerRender *render);

/* Engine-thread-only, serialized, nonreentrant mutable row workspace. Never
 * call from GEGL workers, nested dispatch, or concurrently with native writes.
 * Writes straight linear-sRGB RGBA float without clipping or premultiplication.
 * Final float alpha0 publishes canonical +0 RGBA, including coverage underflow.
 *
 * Requires x>=0, y>=0, x<=image width, y<image height, width<=256, and
 * width<=image width-x. Width0 permits NULL rgba and performs no buffer reads.
 * Positive width requires writable width*4*sizeof(float) bytes; unaligned
 * output is supported. Its address range must not overflow or alias any
 * renderer-owned memory (including captured native objects/transform). Known
 * workspace overlap is rejected. All failures leave caller output unchanged.
 * Free accepts NULL; every object must be freed before engine shutdown. */
gboolean glims_lab_layer_render_row (GlimsLabLayerRender *render,
                                     gint x, gint y, guint width, void *rgba);
#endif
