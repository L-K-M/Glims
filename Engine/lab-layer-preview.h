/* Private serialized derived Lab cache. Native scalar layers are authoritative. */
#ifndef GLIMS_LAB_LAYER_PREVIEW_H
#define GLIMS_LAB_LAYER_PREVIEW_H
#include "engine-private.h"

typedef struct _GlimsLabLayerPreview GlimsLabLayerPreview;
void glims_lab_layer_preview_free (GlimsLabLayerPreview *preview);
gboolean glims_lab_layer_preview_succeeded (GlimsLabLayerPreview *preview);
/* Engine thread only. Freshly validates storage and recaptures changed map,
 * root order, attributes, dimensions or buffer identities. Invalid storage
 * clears/frees the cache and returns UNSUPPORTED; buffer is cleared on refusal.
 * The returned diagnostic buffer is borrowed until the next prepare/free.
 *
 * Native format is linear associated RaGaBaA float. Validate the required
 * level0 region before scaled/single-pixel reads. Every spatial read MUST keep
 * associated linear format through filtering; only unassociate AFTER sampling,
 * using actual alpha (no Babl alpha floor), before ICC. Direct scaled straight
 * RGBA reads are incorrect. Use the private preview-read helper for consumers.
 * Tiny-alpha association can lose float color precision; this is derived data.
 *
 * ONLY synchronous engine-thread validate/get is supported: never attach this
 * buffer to a GEGL graph, parallel read, worker or asynchronous job. Finish all
 * validation/reads and source writes before prepare, mutation or free, and keep
 * sources unchanged during the complete validation/read epoch. No nested
 * dispatch/reentry. The narrow row mutex does not grant worker capability.
 * Check succeeded AFTER the entire synchronous read; failure placeholders are
 * not pixels. Next prepare invalidates the whole extent for an explicit retry.
 * No document mutation or image-sized scratch. Free accepts NULL; succeeded
 * accepts NULL as TRUE, matching the existing private plate preview API. */
GlimsStatus glims_lab_layer_preview_prepare (GimpImage *image,
                                            GlimsLabLayerPreview **preview,
                                            GeglBuffer **buffer);
#endif
