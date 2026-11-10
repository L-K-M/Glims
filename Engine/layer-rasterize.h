#ifndef GLIMS_LAYER_RASTERIZE_H
#define GLIMS_LAYER_RASTERIZE_H
#include "engine-private.h"

/* Engine thread. Validate and retain the complete captured vector first. */
GlimsStatus glims_image_rasterize_layers (GlimsEngine *, GlimsImageID,
                                         const GlimsItemID *, size_t, char **);
#endif
