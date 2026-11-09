/* Captured, ordered batch "Layers to Image Size": every explicitly named
 * pixel-behaving layer fits the image bounds at 0,0 with transparent
 * fill, its mask with it. This is the batch counterpart of the
 * single-layer Fit (edit.c GLIMS_LAYER_FIT_TO_IMAGE); like the native
 * multi-layer command (app/actions/layers-commands.c
 * layers_resize_to_image_cmd_callback) the resizes sit inside one outer
 * Undo group; unlike it, no source is silently skipped: an ineligible
 * member refuses the complete request before any mutation.
 *
 * Runs on the engine thread only; serialization comes from that thread
 * and the caller's queue, not from locking here. Every resolved target
 * is held by a strong GObject reference for the whole job, released on
 * every exit path. Core's resize returns void: preflight covers ordinary
 * refusals, but there is no general rollback for unexpected Core failure. */
#include "layer-fit.h"

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

GlimsStatus
glims_image_fit_layers_to_image (GlimsEngine *engine, GlimsImageID image,
                                 const GlimsItemID *ids, size_t count, char **error)
{
  GlimsOpenImage *open;
  GPtrArray *targets = NULL;
  GlimsStatus status;
  gint image_width, image_height;
  gboolean changed = FALSE;

  /* The caller captures 1..256 ordered, unique, positive layer ids. */
  if (!ids || count < 1 || count > 256)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (size_t i = 0; i < count; i++)
    {
      if (ids[i] <= 0) return GLIMS_STATUS_INVALID_ARGUMENT;
      for (size_t j = 0; j < i; j++) if (ids[i] == ids[j]) return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (gimp_image_get_floating_selection (open->image))
    {
      if (error) *error = g_strdup ("Resolve the floating selection before resizing layers.");
      status = GLIMS_STATUS_BUSY; return status;
    }
  /* A frozen Undo reports disabled, and an open native Undo group means
   * another edit is mid-flight; either would break the advertised single
   * history step. */
  if (!gimp_image_undo_is_enabled (open->image) || gimp_image_get_undo_group_count (open->image))
    {
      if (error) *error = g_strdup ("Finish the current edit and enable Undo before resizing layers.");
      status = GLIMS_STATUS_BUSY; return status;
    }

  /* Resolve and retain every member of the image first: a stale,
   * foreign, detached or non-layer id refuses the whole batch. Kind is
   * decided below by glims_layer_kind, not the raw GType: a rasterized
   * text, link or vector instance keeps its subclass yet reports PIXEL
   * because its current content is pixels. The native selected-layer
   * list is neither read nor written here. */
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

      /* Effective pixel and position locks gate every target: the
       * layer's own or any ancestor group's, as the native UI checks. */
      status = glims_check_item_locks (GIMP_ITEM (layer),
                                       GLIMS_LOCK_PIXELS | GLIMS_LOCK_POSITION, error);
      if (status != GLIMS_STATUS_OK) goto done;

      switch (glims_layer_kind (layer))
        {
        case GLIMS_LAYER_PIXEL:
          /* Rasterized text, link and vector instances report PIXEL
           * here too: their current content is pixels. */
          break;
        case GLIMS_LAYER_GROUP:
          glims_fail (error, NULL,
                      "A layer group cannot be resized this way; size the layers inside it.");
          status = GLIMS_STATUS_UNSUPPORTED; goto done;
        default:
          /* Resizing genuine text, link and vector layers re-renders
           * their source into pixels. Refuse rather than rasterize
           * silently, the same rule as the single-layer Fit. */
          glims_fail (error, NULL,
                      "Rasterize the text, link or vector layer before resizing it.");
          status = GLIMS_STATUS_UNSUPPORTED; goto done;
        }
    }

  /* A target needs the native resize only when its offset is not 0,0 or
   * its size differs from the image's. */
  image_width  = gimp_image_get_width (open->image);
  image_height = gimp_image_get_height (open->image);
  for (guint i = 0; i < targets->len; i++)
    {
      GimpItem *item = g_ptr_array_index (targets, i);
      gint x, y;

      gimp_item_get_offset (item, &x, &y);
      if (x != 0 || y != 0 ||
          gimp_item_get_width (item) != image_width ||
          gimp_item_get_height (item) != image_height)
        changed = TRUE;
    }

  /* Every target already sits at the image bounds: succeed without an
   * Undo group, a dirty mark or a flush. */
  if (!changed)
    {
      status = GLIMS_STATUS_OK; goto done;
    }

  engine->busy++;
  if (!gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_ITEM_RESIZE,
                                    "Layers to Image Size"))
    {
      status = glims_fail (error, NULL, "The layer resize Undo group could not be started.");
      engine->busy--; goto done;
    }
  /* gimp_layer_resize_to_image opens its own nested Undo group per call
   * (core/gimplayer.c); it runs only on targets the bounds check found
   * changed. */
  for (guint i = 0; i < targets->len; i++)
    {
      GimpLayer *layer = g_ptr_array_index (targets, i);
      gint x, y;

      gimp_item_get_offset (GIMP_ITEM (layer), &x, &y);
      if (x == 0 && y == 0 &&
          gimp_item_get_width (GIMP_ITEM (layer)) == image_width &&
          gimp_item_get_height (GIMP_ITEM (layer)) == image_height)
        continue;
      gimp_layer_resize_to_image (layer, gimp_get_user_context (engine->gimp),
                                  GIMP_FILL_TRANSPARENT);
    }
  gimp_image_undo_group_end (open->image);
  gimp_image_flush (open->image);
  engine->busy--;
  status = GLIMS_STATUS_OK;

done:
  g_ptr_array_unref (targets);
  return status;
}
