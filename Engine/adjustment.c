/* A pass-through group and its committed effect, recorded together.
 * No upstream GUI code. */
#include "engine-private.h"

#include <string.h>

#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpviewable.h"
#include "operations/gimp-operation-config.h"

GlimsStatus
glims_adjustment_layer_new (GlimsEngine *engine, GlimsImageID image_id,
                            GlimsItemID parent_id, int32_t index,
                            const char *operation, const char *name,
                            GlimsItemID *out_layer, GlimsEffectID *out_effect,
                            char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  GimpLayer *parent = NULL;
  GimpLayer *group = NULL;
  GimpDrawableFilter *filter = NULL;
  GeglNode *node = NULL;
  GimpContainer *children;
  GlimsStatus status;
  GError *gerror = NULL;

  if (out_layer) *out_layer = 0;
  if (out_effect) *out_effect = 0;
  if (!out_layer || !out_effect || parent_id < 0 || index < 0 || !operation || !*operation ||
      !g_utf8_validate (operation, -1, NULL) ||
      (name && (!*name || !g_utf8_validate (name, -1, NULL))))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (gimp_image_get_floating_selection (open->image))
    {
      glims_fail (error, NULL, "Resolve the floating selection before creating an adjustment layer.");
      return GLIMS_STATUS_BUSY;
    }
  /* Native layers-actions disables new groups on indexed images. A
   * pass-through adjustment needs RGB/grayscale compositing semantics. */
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED)
    {
      glims_fail (error, NULL, "Convert the image to RGB or grayscale before creating an adjustment layer.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (!gimp_image_undo_is_enabled (open->image))
    return glims_fail (error, NULL, "The image's undo history is unavailable.");
  if (parent_id)
    {
      GimpItem *item = gimp_item_get_by_id (engine->gimp, parent_id);
      if (!item || !GIMP_IS_LAYER (item) || !gimp_item_is_attached (item) ||
          gimp_item_get_image (item) != open->image)
        return GLIMS_STATUS_NOT_FOUND;
      if (!GIMP_IS_GROUP_LAYER (item)) return GLIMS_STATUS_INVALID_ARGUMENT;
      parent = GIMP_LAYER (item);
    }
  children = parent ? gimp_viewable_get_children (GIMP_VIEWABLE (parent))
                    : gimp_image_get_layers (open->image);
  if (index < 0 || index > gimp_container_get_n_children (children))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!glims_filter_operation_allowed (operation) ||
      gimp_operation_config_is_custom (engine->gimp, operation))
    {
      glims_fail (error, NULL, "That operation cannot be used as an adjustment layer.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  node = gegl_node_new_child (NULL, "operation", operation, NULL);
  gchar **inputs = gegl_node_list_input_pads (node);
  gboolean single_input = inputs && inputs[0] && !strcmp (inputs[0], "input") && !inputs[1];
  g_strfreev (inputs);
  if (!gegl_node_has_pad (node, "output") || !single_input)
    {
      if (error) *error = strdup ("Choose a filter with one input and no auxiliary image.");
      status = GLIMS_STATUS_UNSUPPORTED;
      goto cleanup;
    }
  group = gimp_group_layer_new (open->image);
  /* GimpItem starts floating. Keep our own reference across publication. */
  g_object_ref_sink (group);
  gimp_layer_set_mode (group, GIMP_LAYER_MODE_PASS_THROUGH, FALSE);
  if (name && !gimp_item_rename (GIMP_ITEM (group), name, &gerror))
    {
      status = glims_fail (error, g_steal_pointer (&gerror), "The adjustment layer could not be named.");
      goto cleanup;
    }
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (group), NULL, node, NULL);
  if (!filter)
    {
      status = glims_fail (error, NULL, "The adjustment filter could not be created.");
      goto cleanup;
    }
  if (gimp_item_get_id (GIMP_ITEM (group)) <= 0 ||
      gimp_drawable_filter_get_id (filter) <= 0)
    {
      status = glims_fail (error, NULL, "The adjustment layer has no usable identity.");
      goto cleanup;
    }

  /* All recoverable construction/argument checks precede the undo
   * group. Core's ND commit returns TRUE for this valid filter and NULL
   * progress; it performs no file work or destructive merge. Record the
   * filter separately: removing a drawable detaches its filters, so a
   * layer-add undo alone cannot restore their graph/invalidations. */
  if (!gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_LAYER_ADD,
                                    "New Adjustment Layer"))
    {
      status = glims_fail (error, NULL, "The image's undo history is unavailable.");
      goto cleanup;
    }
  if (!gimp_image_add_layer (open->image, group, parent, index, TRUE))
    {
      gimp_image_undo_group_end (open->image);
      status = glims_fail (error, NULL, "The adjustment layer could not be added.");
      goto cleanup;
    }
  gimp_drawable_filter_apply (filter, NULL);
  gimp_drawable_filter_layer_mask_freeze (filter);
  gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
  gimp_drawable_filter_set_temporary (filter, FALSE);
  gimp_image_undo_push_filter_add (open->image, "New Adjustment Layer",
                                  GIMP_DRAWABLE (group), filter);
  gimp_image_undo_group_end (open->image);
  *out_layer = gimp_item_get_id (GIMP_ITEM (group));
  *out_effect = gimp_drawable_filter_get_id (filter);
  gimp_image_flush (open->image);
  status = GLIMS_STATUS_OK;

cleanup:
  if (filter && status != GLIMS_STATUS_OK) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter);
  g_clear_object (&group);
  g_clear_object (&node);
  return status;
}

/* 3.0's pass-through groups can keep cached backdrop pixels after a
 * filter parameter changes, including modified-filter Undo. The node
 * values themselves are current. Invalidate the image projection after
 * these mutations; lazy rendering still reads only requested tiles.
 * This does not touch image pixels, dirty state or history. */
void
glims_adjustment_projection_changed (GimpImage *image)
{
#if !GIMP_CHECK_VERSION (3, 2, 0)
  GList *layers = gimp_image_get_layer_list (image);
  gboolean found = FALSE;
  for (GList *iter = layers; iter; iter = iter->next)
    {
      GimpLayer *layer = iter->data;
      if (GIMP_IS_GROUP_LAYER (layer) &&
          gimp_layer_get_mode (layer) == GIMP_LAYER_MODE_PASS_THROUGH &&
          gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (layer))) > 0)
        { found = TRUE; break; }
    }
  g_list_free (layers);
  if (found) gimp_image_invalidate_all (image);
#else
  (void) image;
#endif
}
