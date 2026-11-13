/* Private engine-thread logical Lab layer duplication. No image is adopted. */
#ifndef GLIMS_LAB_LAYER_DUPLICATE_H
#define GLIMS_LAB_LAYER_DUPLICATE_H
#include "engine-private.h"

/* Caller holds valid native objects and excludes source writes, validation,
 * nested dispatch and external/native mutation throughout this operation.
 * Only strict v2 carriers, an explicit resolved root group, enabled/unfrozen
 * Undo without an active group, and fewer than256 layers are admitted.
 *
 * Success inserts one copy immediately above source, selects it, and appends
 * five fresh identities to the map. One native Undo restores map/tree/selection;
 * Redo retains the same new UUIDs. The result is borrowed from the image and
 * must not survive subsequent edits/Undo. A supplied output is cleared first.
 * All ordinary refusals/staging failures precede Undo/history mutation.
 * Native allocation/fatal failures or forbidden external mutation after the
 * preflight are not rollback-safe; unexpected commit failures report failure
 * explicitly, without arbitrary Undo-stack surgery. */
GlimsStatus glims_lab_layer_duplicate (GlimsEngine *engine, GimpImage *image,
                                       GimpLayer *source, GimpLayer **borrowed_copy,
                                       char **error);
#endif
