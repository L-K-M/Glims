/*
 * Layer masks and small drawable thumbnails. Runs on the engine thread.
 *
 * The mask calls follow GIMP's own layer menu, ported deliberately from
 * app/actions/layers-commands.c (layers_add_mask_callback,
 * layers_mask_apply_cmd_callback, layers_mask_show_cmd_callback,
 * layers_mask_disable_cmd_callback,
 * layers_mask_to_selection_cmd_callback) and its sensitivity rules in
 * app/actions/layers-actions.c: the engine refuses APPLY on groups and
 * on rasterizable (text, link, vector) layers, and on layers whose
 * content is locked; adding, showing, disabling and deleting a mask are
 * allowed on locked layers. The core calls are app/core/gimplayer.c's
 * gimp_layer_create_mask, gimp_layer_add_mask, gimp_layer_set_apply_mask,
 * gimp_layer_set_edit_mask, gimp_layer_set_show_mask and
 * gimp_layer_apply_mask, which push the engine's own mask undo records,
 * and app/core/gimpchannel-combine.c's gimp_channel_combine_items for
 * mask-to-selection. Thumbnails follow
 * app/core/gimpdrawable-preview.c's gimp_drawable_get_sub_pixbuf; the
 * facade's renderer applies no ICC display transform, so neither does
 * this. All references at GIMP 3.2.8,
 * commit 7addd2b77efb798bbdc4d2fb082e786a48478ced.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "libgimpmath/gimpmath.h"

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpchannel-combine.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayermask.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"
#include "core/gimpviewable.h"

#include "gimp-intl.h"

/* The mask flags the facade knows. */
#define GLIMS_MASK_ALL (GLIMS_MASK_ENABLED | GLIMS_MASK_EDITING | GLIMS_MASK_SHOWING)

/* The largest thumbnail edge the facade accepts. */
#define GLIMS_THUMBNAIL_MAX 256

/* The layer `id` of `image`, or with 0 the first selected layer. Layer
 * groups are layers too, so this finds them. */
static GimpLayer *
find_layer (GimpImage   *image,
            GlimsItemID  id)
{
  GimpItem *item;

  if (id == 0)
    {
      GList     *selected = gimp_image_get_selected_layers (image);
      GimpLayer *layer    = selected ? selected->data : NULL;

      return layer;
    }

  item = gimp_item_get_by_id (image->gimp, id);
  if (! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item))
    return NULL;

  return GIMP_LAYER (item);
}

GlimsStatus
glims_layer_mask (GlimsEngine     *engine,
                  GlimsImageID     id,
                  GlimsItemID      layer_id,
                  GlimsMaskState  *state)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer      *layer;
  GimpLayerMask  *mask;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! state)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_layer (open->image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;

  memset (state, 0, sizeof (*state));
  mask = gimp_layer_get_mask (layer);
  if (mask)
    {
      state->mask    = gimp_item_get_id (GIMP_ITEM (mask));
      state->enabled = gimp_layer_get_apply_mask (layer) != FALSE;
      state->editing = gimp_layer_get_edit_mask (layer) != FALSE;
      state->showing = gimp_layer_get_show_mask (layer) != FALSE;
    }

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_mask_add (GlimsEngine  *engine,
                      GlimsImageID  id,
                      GlimsItemID   layer_id,
                      uint32_t      source,
                      gboolean      edit,
                      GlimsItemID  *result,
                      char        **error)
{
  GlimsOpenImage  *open = glims_lookup_image (engine, id);
  GlimsStatus      status;
  GimpImage       *image;
  GimpLayer       *layer;
  GimpLayerMask   *mask;
  GimpAddMaskType  type;
  GError          *gerror = NULL;
  gboolean         group;
  gint             w, h;

  if (result)
    *result = 0;
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  switch (source)
    {
    case GLIMS_MASK_WHITE:          type = GIMP_ADD_MASK_WHITE;          break;
    case GLIMS_MASK_BLACK:          type = GIMP_ADD_MASK_BLACK;          break;
    case GLIMS_MASK_ALPHA:          type = GIMP_ADD_MASK_ALPHA;          break;
    case GLIMS_MASK_ALPHA_TRANSFER: type = GIMP_ADD_MASK_ALPHA_TRANSFER; break;
    case GLIMS_MASK_SELECTION:      type = GIMP_ADD_MASK_SELECTION;      break;
    case GLIMS_MASK_GRAYSCALE:      type = GIMP_ADD_MASK_COPY;           break;
    default:
      glims_fail (error, NULL, "The mask source is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  image = open->image;

  layer = find_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  if (gimp_layer_get_mask (layer))
    return glims_fail (error, NULL, "The layer already has a mask.");

  /* gimp_layer_create_mask sizes the mask from the layer (a group from
   * its bounding box); an empty layer cannot host one. */
  if (GIMP_IS_GROUP_LAYER (layer))
    {
      GeglRectangle bounds = gimp_drawable_get_bounding_box (GIMP_DRAWABLE (layer));

      w = bounds.width;
      h = bounds.height;
    }
  else
    {
      w = gimp_item_get_width (GIMP_ITEM (layer));
      h = gimp_item_get_height (GIMP_ITEM (layer));
    }
  if (w < 1 || h < 1)
    return glims_fail (error, NULL, "The layer is empty.");

  /* The mask's floating reference moves to the layer inside
   * gimp_layer_add_mask's g_object_ref_sink (app/core/gimplayer.c):
   * released only when the add fails, as
   * app/actions/layers-commands.c's layers_add_mask_callback does. */
  group = gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_LAYER_ADD,
                                       _("Add Layer Masks"));
  mask  = gimp_layer_create_mask (layer, type, NULL);
  if (mask && ! gimp_layer_add_mask (layer, mask, edit, TRUE, &gerror))
    {
      g_object_unref (mask);
      mask = NULL;
    }
  if (! mask)
    {
      if (group)
        gimp_image_undo_group_end (image);
      return glims_fail (error, gerror, "The mask could not be added.");
    }
  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (mask));
  if (group)
    gimp_image_undo_group_end (image);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_mask_set (GlimsEngine  *engine,
                      GlimsImageID  id,
                      GlimsItemID   layer_id,
                      uint32_t      flags,
                      uint32_t      values,
                      char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;
  GimpLayer      *layer;
  gboolean        group;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! flags || flags & ~GLIMS_MASK_ALL || values & ~GLIMS_MASK_ALL)
    {
      glims_fail (error, NULL, "The flags name a mask flag the engine has no bit for.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  layer = find_layer (open->image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  if (! gimp_layer_get_mask (layer))
    return glims_fail (error, NULL, "The layer has no mask.");

  /* Each setter pushes its own named undo record when its flag actually
   * changes (enable/show) or none (edit, which the engine treats as
   * transient). The group keeps the call a single undo step; it is
   * opened only when a record will land in it, since
   * undo_group_start pushes even an empty group. */
  group = ((flags & GLIMS_MASK_ENABLED) &&
           gimp_layer_get_apply_mask (layer) != ((values & GLIMS_MASK_ENABLED) != 0)) ||
          ((flags & GLIMS_MASK_SHOWING) &&
           gimp_layer_get_show_mask (layer)  != ((values & GLIMS_MASK_SHOWING)  != 0));
  if (group)
    group = gimp_image_undo_group_start (open->image, GIMP_UNDO_GROUP_ITEM_PROPERTIES,
                                         _("Change Layer Mask"));
  if (flags & GLIMS_MASK_ENABLED)
    gimp_layer_set_apply_mask (layer, (values & GLIMS_MASK_ENABLED) != 0, TRUE);
  if (flags & GLIMS_MASK_EDITING)
    gimp_layer_set_edit_mask (layer, (values & GLIMS_MASK_EDITING) != 0);
  if (flags & GLIMS_MASK_SHOWING)
    gimp_layer_set_show_mask (layer, (values & GLIMS_MASK_SHOWING) != 0, TRUE);
  if (group)
    gimp_image_undo_group_end (open->image);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_mask_apply (GlimsEngine  *engine,
                        GlimsImageID  id,
                        GlimsItemID   layer_id,
                        uint32_t      mode,
                        char        **error)
{
  GlimsOpenImage   *open = glims_lookup_image (engine, id);
  GlimsStatus       status;
  GimpLayer        *layer;
  GimpMaskApplyMode apply;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  switch (mode)
    {
    case GLIMS_MASK_APPLY:   apply = GIMP_MASK_APPLY;   break;
    case GLIMS_MASK_DISCARD: apply = GIMP_MASK_DISCARD; break;
    default:
      glims_fail (error, NULL, "The mask apply mode is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  layer = find_layer (open->image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  if (! gimp_layer_get_mask (layer))
    return glims_fail (error, NULL, "The layer has no mask.");

  /* The engine's rules (layers_mask_apply_cmd_callback): only raster
   * layers apply masks; groups, text, link and vector layers may still
   * discard them, and a content lock protects apply, not discard. */
  if (apply == GIMP_MASK_APPLY)
    {
      if (gimp_viewable_get_children (GIMP_VIEWABLE (layer)))
        {
          glims_fail (error, NULL, "A layer group cannot apply its mask.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      if (gimp_item_is_rasterizable (GIMP_ITEM (layer)))
        {
          glims_fail (error, NULL, "A text, link or vector layer cannot apply a mask.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_PIXELS, error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  /* Pushes the "Apply Layer Masks" / "Delete Layer Masks" undo records
   * itself; a mask-less layer gains alpha before the mask is baked. */
  gimp_layer_apply_mask (layer, apply, TRUE);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_layer_mask_to_selection (GlimsEngine  *engine,
                               GlimsImageID  id,
                               GlimsItemID   layer_id,
                               uint32_t      operation,
                               char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GlimsStatus     status;
  GimpLayer      *layer;
  GimpChannel    *mask;
  const gchar    *desc;
  GList          *masks;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  switch (operation)
    {
    case GLIMS_SELECT_REPLACE:   desc = C_("undo-type", "Masks to Selection");             break;
    case GLIMS_SELECT_ADD:       desc = C_("undo-type", "Add Masks to Selection");         break;
    case GLIMS_SELECT_SUBTRACT:  desc = C_("undo-type", "Subtract Masks from Selection");  break;
    case GLIMS_SELECT_INTERSECT: desc = C_("undo-type", "Intersect Masks with Selection"); break;
    default:
      glims_fail (error, NULL, "The selection operation is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  layer = find_layer (open->image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  if (! gimp_layer_get_mask (layer))
    return glims_fail (error, NULL, "The layer has no mask.");

  /* combine_items places the mask's buffer at the layer's offset
   * (app/core/gimpchannel-combine.c), so the selection lands where the
   * masked pixels are. */
  mask  = gimp_image_get_mask (open->image);
  masks = g_list_prepend (NULL, gimp_layer_get_mask (layer));
  gimp_channel_push_undo (mask, desc);
  gimp_channel_combine_items (mask, masks, glims_channel_op (operation));
  g_list_free (masks);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_drawable_thumbnail (GlimsEngine  *engine,
                          GlimsImageID  id,
                          GlimsItemID   item_id,
                          int32_t       max_size,
                          uint8_t      *pixels,
                          size_t        byte_count,
                          int32_t      *width,
                          int32_t      *height)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpDrawable   *drawable;
  GeglBuffer     *buffer;
  const GeglRectangle *extent;
  gint            w, h, out_w, out_h;
  gdouble         scale;
  size_t          need;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! width || ! height || max_size < 1 || max_size > GLIMS_THUMBNAIL_MAX)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *width  = 0;
  *height = 0;

  drawable = glims_lookup_drawable (open, item_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;

  w = gimp_item_get_width (GIMP_ITEM (drawable));
  h = gimp_item_get_height (GIMP_ITEM (drawable));
  if (w < 1 || h < 1)
    return GLIMS_STATUS_FAILED;

  scale  = MIN ((gdouble) max_size / w, (gdouble) max_size / h);
  scale  = MIN (scale, 1.0);
  out_w  = MAX (1, (gint) RINT (w * scale));
  out_h  = MAX (1, (gint) RINT (h * scale));
  need   = (size_t) out_w * (size_t) out_h * 4;

  *width  = out_w;
  *height = out_h;
  if (! pixels)
    return GLIMS_STATUS_OK;
  if (byte_count < need)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* A group's own buffer holds its composited children once its
   * projection is flushed (app/core/gimpgrouplayer.c
   * gimp_group_layer_update_size); on other drawables flush is a no-op.
   * get_buffer_with_effects includes applied filters. */
  gimp_pickable_flush (GIMP_PICKABLE (drawable));
  buffer = gimp_drawable_get_buffer_with_effects (drawable);
  if (! buffer)
    return GLIMS_STATUS_FAILED;

  /* Drawable buffers are 0-origin except a group's, whose extent sits at
   * the group's bounds in image coordinates
   * (app/core/gimpdrawable.c gimp_drawable_real_set_buffer). */
  extent = gegl_buffer_get_extent (buffer);
  gegl_buffer_get (buffer,
                   GEGL_RECTANGLE ((gint) RINT (extent->x * scale),
                                   (gint) RINT (extent->y * scale),
                                   out_w, out_h),
                   scale,
                   babl_format ("R'G'B'A u8"),
                   pixels,
                   (gint) out_w * 4,
                   GEGL_ABYSS_CLAMP);
  g_object_unref (buffer);

  return GLIMS_STATUS_OK;
}
