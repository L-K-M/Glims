/* Captured plain-layer deletion. Native removal has no recoverable return;
 * preflight its complete input and record selection before removing anything. */
#include "layer-delete.h"
#include "layer-duplicate-selection-undo.h"
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"

static gboolean
contains (GPtrArray *items, gpointer item)
{
  for (guint i = 0; i < items->len; i++)
    if (g_ptr_array_index (items, i) == item) return TRUE;
  return FALSE;
}

GlimsStatus
glims_image_delete_layers (GlimsEngine *engine, GlimsImageID image,
                           const GlimsItemID *ids, size_t count, char **error)
{
  GlimsOpenImage *open;
  GPtrArray *sources = NULL, *before = NULL, *after = NULL;
  GlimsStatus status;
  if (!ids || count < 1 || count > 256) return GLIMS_STATUS_INVALID_ARGUMENT;
  for (size_t i = 0; i < count; i++) {
    if (ids[i] <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
    for (size_t j = 0; j < i; j++) if (ids[i] == ids[j]) return GLIMS_STATUS_INVALID_ARGUMENT;
  }
  open = glims_lookup_image (engine, image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (gimp_image_get_floating_selection (open->image)) {
    if (error) *error = g_strdup ("Resolve the floating selection before deleting layers.");
    return GLIMS_STATUS_BUSY;
  }
  if (!gimp_image_undo_is_enabled (open->image) || gimp_image_get_undo_group_count (open->image)) {
    if (error) *error = g_strdup ("Finish the current edit and enable Undo before deleting layers.");
    return GLIMS_STATUS_BUSY;
  }
  sources = g_ptr_array_new_with_free_func (g_object_unref);
  before = g_ptr_array_new_with_free_func (g_object_unref);
  after = g_ptr_array_new_with_free_func (g_object_unref);
  for (size_t i = 0; i < count; i++) {
    GimpItem *item = gimp_item_get_by_id (open->image->gimp, ids[i]);
    if (!item || !GIMP_IS_LAYER (item) || gimp_item_get_image (item) != open->image || !gimp_item_is_attached (item)) {
      status = GLIMS_STATUS_NOT_FOUND; goto done;
    }
    if (G_OBJECT_TYPE (item) != GIMP_TYPE_LAYER) {
      if (error) *error = g_strdup ("Delete ordinary pixel layers together. Delete groups and editable sources individually.");
      status = GLIMS_STATUS_UNSUPPORTED; goto done;
    }
    GimpLayerMask *mask = gimp_layer_get_mask (GIMP_LAYER (item));
    if (mask && gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (mask)))) {
      if (error) *error = g_strdup ("Merge the layer-mask effects before deleting these layers together.");
      status = GLIMS_STATUS_UNSUPPORTED; goto done;
    }
    g_ptr_array_add (sources, g_object_ref (item));
  }
  /* Native selected-list nodes are borrowed. Own only object references. */
  for (GList *it = gimp_image_get_selected_layers (open->image); it; it = it->next) {
    g_ptr_array_add (before, g_object_ref (it->data));
    if (!contains (sources, it->data)) g_ptr_array_add (after, g_object_ref (it->data));
  }
  if (!after->len) {
    /* Keep surviving selections; otherwise select the first surviving tree row.
     * Unlike the selected getter, the flattened layer-list nodes are owned. */
    GList *layers = gimp_image_get_layer_list (open->image);
    for (GList *it = layers; it; it = it->next) if (!contains (sources, it->data)) {
      g_ptr_array_add (after, g_object_ref (it->data)); break;
    }
    g_list_free (layers);
  }
  engine->busy++;
  if (!gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "Delete Layers")) {
    status = glims_fail (error, NULL, "The layer deletion Undo group could not be started.");
    engine->busy--; goto done;
  }
  /* This FIRST record runs LAST on Undo, after removed layers are attached.
   * On Redo it selects only survivors before native removal runs again. */
  glims_layer_selection_undo_push (open->image, before, after);
  {
    GList *selected = NULL;
    for (guint i = 0; i < after->len; i++) selected = g_list_prepend (selected, g_ptr_array_index (after, i));
    selected = g_list_reverse (selected);
    gimp_image_set_selected_layers (open->image, selected);
    g_list_free (selected);
  }
  for (guint i = 0; i < sources->len; i++)
    gimp_image_remove_layer (open->image, g_ptr_array_index (sources, i), TRUE, NULL);
  gimp_image_undo_group_end (open->image);
  gimp_image_flush (open->image);
  engine->busy--;
  status = GLIMS_STATUS_OK;
done:
  g_ptr_array_unref (sources); g_ptr_array_unref (before); g_ptr_array_unref (after);
  return status;
}
