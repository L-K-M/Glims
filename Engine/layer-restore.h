#ifndef GLIMS_LAYER_RESTORE_H
#define GLIMS_LAYER_RESTORE_H
#include "engine-private.h"

/* Engine thread. Admit and retain the entire captured vector before edits. */
GlimsStatus glims_image_restore_layer_sources (GlimsEngine *, GlimsImageID,
                                              const GlimsItemID *, size_t, char **);
#endif
