#ifndef GLIMS_LAYER_DUPLICATE_SELECTION_UNDO_H
#define GLIMS_LAYER_DUPLICATE_SELECTION_UNDO_H

#include <glib.h>

typedef struct _GimpImage GimpImage;
typedef struct _GimpUndo  GimpUndo;

/* Engine-thread helper. Pushes one native GimpUndo subclass that records
 * the before/after layer selection as weak snapshots, for use inside the
 * caller's structural group. Duplication pushes it last, after attaching
 * copies. Deletion pushes it first, while all before/after members are still
 * attached, so Undo restores selection after native layers return. The caller
 * owns the placement, the same
 * worker job, and the outer group/structure accounting; this helper never
 * opens or closes a group, attaches or removes items, duplicates anything,
 * or changes pixels, selection outside the recorded snapshots, or history
 * policy.
 *
 * `before_layers` and `after_layers` are borrowed GPtrArrays (element type
 * GimpLayer*). They are validated (non-NULL, every layer live and attached
 * to `image`) before the push; either snapshot may be empty. The
 * helper does not take ownership of the caller's arrays or their elements.
 *
 * Returns the borrowed, stack-owned GimpUndo* exactly like
 * gimp_image_undo_push (may be NULL when the stack is frozen or the new
 * step is immediately expired). The caller must not unref, inspect or
 * change its fields after the push. */
GimpUndo *glims_layer_selection_undo_push (GimpImage  *image,
                                                     GPtrArray *before_layers,
                                                     GPtrArray *after_layers);

#endif /* GLIMS_LAYER_DUPLICATE_SELECTION_UNDO_H */
