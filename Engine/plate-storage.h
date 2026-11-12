/* Engine-thread-only storage primitives. No public mode is activated here. */
#ifndef GLIMS_PLATE_STORAGE_H
#define GLIMS_PLATE_STORAGE_H
#include "engine-private.h"
#include "plate-map.h"

#define GLIMS_PLATE_MAP_PARASITE "glims/plate-map"
#define GLIMS_PLATE_UUID_PARASITE "glims/plate-uuid"
#define GLIMS_PLATE_VISIBLE_PARASITE "glims/plate-visible"

typedef enum {
  GLIMS_PLATE_STORAGE_NONE,
  GLIMS_PLATE_STORAGE_VALID,
  GLIMS_PLATE_STORAGE_INVALID
} GlimsPlateStorageState;

typedef struct {
  GlimsPlateMap map;
  /* Borrowed, in persisted component order. Do not retain across any edit,
   * Undo or nested main loop; read again at the next operation boundary. */
  GimpChannel *planes[GLIMS_PLATE_LIMIT];
  /* Optional persistent one-byte plane attribute, absent means visible.
   * Kept separate from GIMP's channel overlay visibility. */
  gboolean visible[GLIMS_PLATE_LIMIT];
} GlimsPlateStorage;

/* Distinguishes an ordinary image from damaged/unsupported known metadata.
 * On NONE or INVALID, clears out completely. No mutations or pixel reads. */
GlimsPlateStorageState glims_plate_storage_read (GimpImage *image, GlimsPlateStorage *out);
/* Creates an unadopted, flat, all-paper component image. Caller owns its
 * reference. The map supplies stable UUIDs; names are display-only. */
GimpImage *glims_plate_storage_create (GlimsEngine *engine, const GlimsPlateMap *map,
                                      char **error);
#endif
