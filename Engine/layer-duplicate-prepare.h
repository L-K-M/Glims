#ifndef GLIMS_LAYER_DUPLICATE_PREPARE_H
#define GLIMS_LAYER_DUPLICATE_PREPARE_H

#include <glib.h>

#include "glims_engine.h"

/* Engine-thread preflight only. Prepares a batch of layer duplicates as a
 * plan of owned source references and owned clones, without attaching
 * anything, changing history, selection or pixels. The plan is consumed and
 * freed by the same serialized engine job that created it; it is never
 * shared across calls and no thread-safety is claimed for it.
 *
 * `sources` and `copies` are GPtrArrays (free function g_object_unref) in
 * INPUT ORDER; each entry is a strong GimpLayer reference. */
typedef struct
{
  GPtrArray *sources;
  GPtrArray *copies;
} GlimsLayerDuplicatePlan;

GlimsStatus glims_layer_duplicate_prepare (GlimsEngine                *engine,
                                           GlimsImageID                image,
                                           const GlimsItemID          *sources,
                                           size_t                      count,
                                           GlimsLayerDuplicatePlan   **out,
                                           char                      **error);

void glims_layer_duplicate_plan_free (GlimsLayerDuplicatePlan *plan);

#endif /* GLIMS_LAYER_DUPLICATE_PREPARE_H */
