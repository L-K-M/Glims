/* Private engine-thread creation of a transparent logical Lab layer. */
#ifndef GLIMS_LAB_LAYER_CREATE_H
#define GLIMS_LAB_LAYER_CREATE_H
#include "engine-private.h"

/* Insert at an exact root index in [0, count], select the new root, and
 * append five fresh identities to the map. Scalar bytes are initially
 * L=255, a=b=128, alpha=0. A NULL/empty name uses "Layer"; other names must
 * be valid UTF-8 of at most 1024 bytes. The result is borrowed from the image.
 * One native Undo restores the prior map/tree/ordered selection; Redo uses
 * the same new objects and UUIDs. An empty valid carrier is supported.
 *
 * Caller holds valid native objects and excludes writes, validation, nested
 * dispatch and external native mutation for the whole call. Ordinary
 * refusals/staging failures precede history mutation. Fatal allocation or
 * unexpected native failure after preflight is not rollback-safe. Do not
 * retain the borrowed output across subsequent edits or Undo. */
GlimsStatus glims_lab_layer_create (GlimsEngine *engine, GimpImage *image,
                                   int32_t index, const char *name,
                                   GimpLayer **borrowed_layer, char **error);
#endif
