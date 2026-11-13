/* Engine-thread-only private Lab layer carrier. No document is adopted here. */
#ifndef GLIMS_LAB_LAYER_STORAGE_H
#define GLIMS_LAB_LAYER_STORAGE_H

#include "engine-private.h"
#include "lab-layer-map.h"

typedef enum {
  GLIMS_LAB_LAYER_STORAGE_NONE,
  GLIMS_LAB_LAYER_STORAGE_VALID,
  GLIMS_LAB_LAYER_STORAGE_INVALID
} GlimsLabLayerStorageState;

typedef struct {
  guint map_index;
  GimpLayer *group;
  GimpLayer *planes[4]; /* L, a, b, alpha, independent of child order. */
} GlimsLabLayerNative;

typedef struct {
  GlimsLabLayerMap map;
  /* Borrowed, in actual top-to-bottom root order. Never retain across any edit,
   * Undo or nested main loop; read again at the next operation boundary. */
  GlimsLabLayerNative layers[GLIMS_LAB_LAYER_LIMIT];
} GlimsLabLayerStorage;

/* Fixed Gray U8_LINEAR, no channel objects, QuickMask, floating selection,
 * glims/plate-profile, icc-profile, or simulation-icc-profile parasites.
 * Root groups have four plain full-canvas scalar children. Group visibility
 * and finite opacity may vary; child attributes and all mode/spaces are fixed.
 * Selection-mask pixels are unrestricted. No mutations or pixel reads.
 * Without a map, any glims/plate-profile or item glims/plate-uuid is INVALID;
 * an otherwise ordinary image is NONE, including an ordinary ICC profile.
 * NONE/INVALID clear the complete output. This dedicated reader rejects v1. */
GlimsLabLayerStorageState glims_lab_layer_storage_read (GimpImage *image,
                                                       GlimsLabLayerStorage *out);
/* Creates an unadopted owned image with transparent logical layers, clean Undo
 * and stable map UUIDs. Names are display-only. No native mode is activated. */
GimpImage *glims_lab_layer_storage_create (GlimsEngine *engine,
                                         const GlimsLabLayerMap *map,
                                         char **error);
#endif
