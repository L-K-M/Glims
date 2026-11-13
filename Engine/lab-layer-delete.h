/* Private serialized logical Lab root deletion. No public mode is enabled. */
#ifndef GLIMS_LAB_LAYER_DELETE_H
#define GLIMS_LAB_LAYER_DELETE_H
#include "engine-private.h"

/* Engine thread only; caller holds valid native objects and excludes source
 * writes, validation, nested dispatch and external/native mutation throughout.
 * Requires a strict carrier, an explicit attached logical root, idle engine,
 * and enabled/unfrozen Undo without an active group. Last-root removal is valid.
 *
 * After deletion, retain previously selected surviving LOGICAL ROOTS in their
 * original order, or select the first surviving root in native top-to-bottom
 * order. With no roots, select nothing. Scalar children are never after-targets.
 * One native Undo group restores the complete original ordered native selection
 * (including selected scalar children), map and tree; Redo repeats the removal.
 * Ordinary refusal/staging failures precede history mutation and preserve Redo.
 * Unexpected native/fatal failure after preflight may leave history/state changed;
 * no arbitrary Undo-stack rollback or override of native retention is attempted. */
GlimsStatus glims_lab_layer_delete (GlimsEngine *engine, GimpImage *image,
                                    GimpLayer *explicit_source, char **error);
#endif
