#ifndef GLIMS_LAYER_FIT_H
#define GLIMS_LAYER_FIT_H
#include "engine-private.h"

/* Engine thread. Validate every captured layer before any resize. */
GlimsStatus glims_image_fit_layers_to_image (GlimsEngine *, GlimsImageID,
                                             const GlimsItemID *, size_t, char **);
#endif
