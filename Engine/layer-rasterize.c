/* Explicit, ordered batch rasterization of retained text/link/vector sources.
 * Ordinary admission failures precede every mutation. Unexpected Core failures
 * do not imply rollback: any changed prefix remains inside one native Undo.
 * Runs only on the engine thread; strong references cover the entire job. */
#include "layer-rasterize.h"

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

GlimsStatus
glims_image_rasterize_layers (GlimsEngine *engine, GlimsImageID image,
                              const GlimsItemID *ids, size_t count, char **error)
{
  GlimsOpenImage *open;
  GPtrArray *targets;
  GlimsLayerSourceInfo sources[256] = {0};
  GlimsStatus status;
  gboolean changed = FALSE;
  char *reason = NULL;

  if (!ids || count < 1 || count > G_N_ELEMENTS (sources))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (size_t i = 0; i < count; i++)
    {
      if (ids[i] <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
      for (size_t j = 0; j < i; j++)
        if (ids[i] == ids[j]) return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (gimp_image_get_floating_selection (open->image))
    {
      if (error) *error = g_strdup ("Resolve the floating selection before rasterizing layers.");
      return GLIMS_STATUS_BUSY;
    }
  if (!gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image))
    {
      if (error) *error = g_strdup ("Finish the current edit and enable Undo before rasterizing layers.");
      return GLIMS_STATUS_BUSY;
    }

  targets = g_ptr_array_new_with_free_func (g_object_unref);
  for (size_t i = 0; i < count; i++)
    {
      GimpItem *item = gimp_item_get_by_id (open->image->gimp, ids[i]);
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
      sources[i].struct_size = sizeof sources[i];
      status = glims_layer_source_info (engine, image, ids[i], &sources[i], error);
      if (status != GLIMS_STATUS_OK) goto done;
      if ((sources[i].source_kind != GLIMS_LAYER_TEXT &&
           sources[i].source_kind != GLIMS_LAYER_LINK &&
           sources[i].source_kind != GLIMS_LAYER_VECTOR) || !sources[i].has_source)
        {
          glims_fail (error, NULL,
                      "Every layer must have a retained text, link or vector source to rasterize.");
          status = GLIMS_STATUS_UNSUPPORTED; goto done;
        }
      changed |= !sources[i].is_rasterized;
    }

  /* Retained, pixel-behaving structured subclasses are eligible no-ops.
   * Validate their locks and source too, but create no history or dirty mark. */
  if (!changed)
    {
      status = GLIMS_STATUS_OK; goto done;
    }

  engine->busy++;
  if (!gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                                    "Rasterize Layers"))
    {
      status = glims_fail (error, NULL, "The layer rasterization Undo group could not be started.");
      engine->busy--; goto done;
    }

  status = GLIMS_STATUS_OK;
  for (guint i = 0; i < targets->len; i++)
    {
      GlimsLayerSourceInfo after = { .struct_size = sizeof after };
      if (sources[i].is_rasterized) continue;
      status = glims_layer_rasterize (open->image, g_ptr_array_index (targets, i), &reason);
      if (status != GLIMS_STATUS_OK) break;
      /* Native setters return void. Verify actual retained-source behavior
       * rather than reporting a failed native change as a successful batch. */
      status = glims_layer_source_info (engine, image, ids[i], &after, &reason);
      if (status != GLIMS_STATUS_OK || !after.is_rasterized || !after.has_source ||
          after.source_kind != sources[i].source_kind)
        {
          status = GLIMS_STATUS_FAILED;
          if (!reason) reason = g_strdup ("The native layer did not retain its rasterized source.");
          break;
        }
    }

  if (!gimp_image_undo_group_end (open->image) && status == GLIMS_STATUS_OK)
    {
      status = GLIMS_STATUS_FAILED;
      reason = g_strdup ("The native Undo group could not be closed.");
    }
  /* A failed Core operation may have changed earlier members. Refresh the
   * authoritative image before releasing busy; never claim atomic rollback. */
  gimp_image_flush (open->image);
  engine->busy--;
  if (status != GLIMS_STATUS_OK && error)
    *error = g_strdup_printf ("Rasterizing layers stopped. Some layers may already have changed; "
                              "use Undo to revert the batch. %s",
                              reason ? reason : "The native operation failed.");
  g_free (reason);

done:
  g_ptr_array_unref (targets);
  return status;
}
