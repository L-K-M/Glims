/* Captured, ordered plain-layer batch duplication. All ordinary input and
 * insertion prerequisites are checked before the native Undo group starts. */
#include "engine-private.h"
#include "layer-duplicate-prepare.h"
#include "layer-duplicate-selection-undo.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpitemtree.h"
#include "core/gimplayer.h"
#include <string.h>

GlimsStatus
glims_image_duplicate_layers (GlimsEngine *engine, GlimsImageID image,
                              const GlimsItemID *sources, int32_t count,
                              GlimsItemID *copies, char **error)
{
  GlimsItemID captured[256];
  GlimsLayerDuplicatePlan *plan = NULL;
  GlimsOpenImage *open;
  GPtrArray *before, *after;
  GlimsStatus status;
  gint added = 0;
  char *selection_error = NULL;

  if (count < 1 || count > 256 || !copies)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!sources) {
    memset (copies, 0, (gsize) count * sizeof (*copies));
    return GLIMS_STATUS_INVALID_ARGUMENT;
  }
  /* Input/output may overlap. Capture before clearing the result. */
  memcpy (captured, sources, (gsize) count * sizeof (*sources));
  memset (copies, 0, (gsize) count * sizeof (*copies));
  status = glims_layer_duplicate_prepare (engine, image, captured, (size_t) count, &plan, error);
  if (status != GLIMS_STATUS_OK) return status;
  open = glims_lookup_image (engine, image);

  for (gint i = 0; i < count; i++) {
    GimpItem *source = g_ptr_array_index (plan->sources, i);
    GimpItem *copy = g_ptr_array_index (plan->copies, i);
    GimpLayer *parent = gimp_layer_get_parent (GIMP_LAYER (source));
    GimpItem *checked_parent = parent ? GIMP_ITEM (parent) : NULL;
    gint position = gimp_item_get_index (source), checked_position = position;
    if (position < 0 || !gimp_item_tree_get_insert_pos (gimp_item_get_tree (source), copy,
                                                      &checked_parent, &checked_position) ||
        checked_parent != (parent ? GIMP_ITEM (parent) : NULL) || checked_position != position) {
      glims_layer_duplicate_plan_free (plan);
      return glims_fail (error, NULL, "A layer copy cannot be inserted above its source.");
    }
  }

  before = g_ptr_array_new_with_free_func (g_object_unref);
  after = g_ptr_array_new ();
  /* Native selected-layer getter nodes belong to Core. Own only refs to
   * the objects and our own GPtrArray, never the getter's list. */
  for (GList *it = gimp_image_get_selected_layers (open->image); it; it = it->next)
    g_ptr_array_add (before, g_object_ref (it->data));

  /* Prevent reentrant facade edits from native notifications. The worker
   * is already serialized; selection/read-only notifications may continue. */
  engine->busy++;
  if (!gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_LAYER_ADD, "Duplicate Layers")) {
    status = glims_fail (error, NULL, "The layer duplication Undo group could not be started.");
    goto done;
  }
  status = GLIMS_STATUS_OK;
  for (gint i = 0; i < count; i++) {
    GimpLayer *source = g_ptr_array_index (plan->sources, i);
    GimpLayer *copy = g_ptr_array_index (plan->copies, i);
    /* Earlier inserts shift indices. Always use this source's CURRENT
     * index and explicit actual parent, never the active-parent sentinel. */
    if (!gimp_image_add_layer (open->image, copy, gimp_layer_get_parent (source),
                              gimp_item_get_index (GIMP_ITEM (source)), TRUE)) {
      status = glims_fail (error, NULL, "The engine could not insert every layer copy. Undo removes any created copies.");
      break;
    }
    copies[added++] = gimp_item_get_id (GIMP_ITEM (copy));
    g_ptr_array_add (after, copy); /* plan/image still own the object */
  }
  if (added) {
    GlimsStatus selected = glims_image_select_layers (engine, image, copies, (size_t) added, &selection_error);
    if (selected != GLIMS_STATUS_OK && status == GLIMS_STATUS_OK) {
      status = selected;
      if (error) { *error = selection_error; selection_error = NULL; }
    }
    /* Layer-add Redo alone selects only its last copy. This last record
     * restores the complete ordered vector on Redo and the prior vector
     * before Undo removes copies. Native retention policy may expire the
     * record/group; as with native commands, that is not a failed edit. */
    glims_layer_selection_undo_push (open->image, before, after);
  }
  gimp_image_undo_group_end (open->image);
  gimp_image_flush (open->image);

done:
  engine->busy--;
  g_free (selection_error);
  g_ptr_array_unref (before); g_ptr_array_unref (after);
  glims_layer_duplicate_plan_free (plan);
  return status;
}
