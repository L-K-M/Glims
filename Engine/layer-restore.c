/* Ordered batch Restore of retained structured sources. Ordinary admission
 * failures precede mutation. Native regeneration can resize/reposition content
 * and masks; linked sources reload current files. A void native setter is not
 * rendering-success evidence, and unexpected failures do not imply rollback. */
#include "layer-restore.h"

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

GlimsStatus
glims_image_restore_layer_sources (GlimsEngine *engine, GlimsImageID image,
                                   const GlimsItemID *ids, size_t count,
                                   char **error)
{
  GlimsOpenImage *open;
  GPtrArray *targets;
  GlimsItemID captured[256];
  GlimsLayerSourceInfo sources[256] = {0};
  GlimsStatus status;
  gboolean changed = FALSE;
  char *reason = NULL;

  if (error) *error = NULL;
  if (!ids || count < 1 || count > G_N_ELEMENTS (captured))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (size_t i = 0; i < count; i++)
    {
      captured[i] = ids[i];
      if (captured[i] <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
      for (size_t j = 0; j < i; j++)
        if (captured[i] == captured[j]) return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (gimp_image_get_floating_selection (open->image))
    {
      if (error) *error = g_strdup ("Resolve the floating selection before restoring layer sources.");
      return GLIMS_STATUS_BUSY;
    }
  if (!gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image))
    {
      if (error) *error = g_strdup ("Finish the current edit and enable Undo before restoring layer sources.");
      return GLIMS_STATUS_BUSY;
    }

  targets = g_ptr_array_new_with_free_func (g_object_unref);
  for (size_t i = 0; i < count; i++)
    {
      GimpItem *item = gimp_item_get_by_id (open->image->gimp, captured[i]);
      if (!item || !GIMP_IS_LAYER (item) ||
          gimp_item_get_image (item) != open->image ||
          !gimp_item_is_attached (item))
        {
          status = GLIMS_STATUS_NOT_FOUND; goto done;
        }
      g_ptr_array_add (targets, g_object_ref (item));
    }

  for (guint i = 0; i < targets->len; i++)
    {
      GimpLayer *layer = g_ptr_array_index (targets, i);
      status = glims_check_item_locks (GIMP_ITEM (layer),
                                       GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK) goto done;
      status = glims_layer_restore_source_admit (layer, error);
      if (status != GLIMS_STATUS_OK) goto done;
      sources[i].struct_size = sizeof sources[i];
      status = glims_layer_source_info (engine, image, captured[i], &sources[i], error);
      if (status != GLIMS_STATUS_OK) goto done;
      changed |= sources[i].is_rasterized;
    }

  /* Editable retained sources still passed every admission gate. */
  if (!changed)
    {
      status = GLIMS_STATUS_OK; goto done;
    }

  engine->busy++;
  if (!gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                                    "Restore Layer Sources"))
    {
      status = glims_fail (error, NULL, "The layer source restoration Undo group could not be started.");
      engine->busy--; goto done;
    }

  status = GLIMS_STATUS_OK;
  for (guint i = 0; i < targets->len; i++)
    {
      GlimsLayerSourceInfo after = { .struct_size = sizeof after };
      if (!sources[i].is_rasterized) continue;
      status = glims_layer_restore_source (open->image, g_ptr_array_index (targets, i), &reason);
      if (status != GLIMS_STATUS_OK) break;
      /* The setter returns no render result. Confirm only the actual source
       * class/retention/editable predicate; do not claim pixel validation. */
      status = glims_layer_source_info (engine, image, captured[i], &after, &reason);
      if (status != GLIMS_STATUS_OK || after.is_rasterized || !after.has_source ||
          after.source_kind != sources[i].source_kind)
        {
          status = GLIMS_STATUS_FAILED;
          if (!reason) reason = g_strdup ("The native layer did not restore editable retained-source behavior.");
          break;
        }
    }

  if (!gimp_image_undo_group_end (open->image) && status == GLIMS_STATUS_OK)
    {
      status = GLIMS_STATUS_FAILED;
      g_clear_pointer (&reason, g_free);
      reason = g_strdup ("The native Undo group could not be closed.");
    }
  gimp_image_flush (open->image);
  engine->busy--;
  if (status != GLIMS_STATUS_OK && error)
    *error = g_strdup_printf ("Restoring layer sources stopped. Some layers may already have changed; "
                              "use Undo to revert the batch. %s",
                              reason ? reason : "The native operation failed.");
  g_free (reason);

done:
  g_ptr_array_unref (targets);
  return status;
}
