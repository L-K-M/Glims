#ifndef GLIMS_LAYER_DELETE_H
#define GLIMS_LAYER_DELETE_H
#include "engine-private.h"

/* Engine thread. Validate every captured plain layer before any mutation. */
GlimsStatus glims_image_delete_layers (GlimsEngine *, GlimsImageID,
                                      const GlimsItemID *, size_t, char **);
#endif
