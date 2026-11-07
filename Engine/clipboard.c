/* System-clipboard pixels. Selection extraction follows core/gimp-edit.c;
 * all transport is straight-alpha sRGB, independent of engine precision. */
#include "engine-private.h"
#include <string.h>
#include <math.h>

#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-edit.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpselection.h"

#define MAX_CLIPBOARD_BYTES ((uint64_t) 512 * 1024 * 1024)

static gboolean
pixel_bytes (int width, int height, size_t *bytes)
{
  uint64_t count;
  if (width < 1 || height < 1 || width > GIMP_MAX_IMAGE_SIZE || height > GIMP_MAX_IMAGE_SIZE)
    return FALSE;
  count = (uint64_t) width * height * 4;
  if (count > MAX_CLIPBOARD_BYTES || count > SIZE_MAX)
    return FALSE;
  *bytes = (size_t) count;
  return TRUE;
}

static GimpLayer *
selected_layer (GimpImage *image)
{
  GList *selected = gimp_image_get_selected_layers (image);
  return selected ? selected->data : NULL;
}

GlimsStatus
glims_image_from_pixels (GlimsEngine *engine, int32_t width, int32_t height,
                         const uint8_t *pixels, size_t byte_count, GlimsImageID *out, char **error)
{
  size_t bytes;
  GimpImage *image;
  GeglBuffer *buffer;
  GimpLayer *layer;

  if (out) *out = 0;
  if (! out || ! pixels || ! pixel_bytes (width, height, &bytes) || bytes != byte_count)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;

  image = gimp_create_image (engine->gimp, width, height, GIMP_RGB, GIMP_PRECISION_U8_NON_LINEAR, FALSE);
  gimp_image_undo_disable (image);
  buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, width, height), babl_format ("R'G'B'A u8"));
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, width, height), 0,
                   babl_format ("R'G'B'A u8"), pixels, width * 4);
  layer = gimp_layer_new_from_gegl_buffer (buffer, image, gimp_image_get_layer_format (image, TRUE),
                                          "Clipboard", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL, NULL);
  g_object_unref (buffer);
  if (! layer || ! gimp_image_add_layer (image, layer, NULL, 0, FALSE))
    {
      if (layer) g_object_unref (layer);
      g_object_unref (image);
      return glims_fail (error, NULL, "The clipboard image could not be created.");
    }
  gimp_image_undo_enable (image);
  gimp_image_dirty (image, GIMP_DIRTY_IMAGE);
  gimp_image_flush (image);
  return glims_adopt_image (engine, image, out);
}

GlimsStatus
glims_image_copy_pixels (GlimsEngine *engine, GlimsImageID id, gboolean merged,
                         GlimsPixelBuffer *result, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer     *layer;
  GimpImage     *image;
  GList         pickables = { 0 };
  GeglBuffer   *buffer;
  GError       *gerror = NULL;
  int           x, y, width, height;
  int           offset_x, offset_y;
  size_t        bytes;

  if (! result) return GLIMS_STATUS_INVALID_ARGUMENT;
  memset (result, 0, sizeof *result);
  if (! open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  image = open->image;
  layer = selected_layer (image);
  if (! merged && ! layer)
    return glims_fail (error, NULL, "Select a layer to copy.");

  /* Check before extraction can allocate a large intermediate buffer. */
  if (merged)
    {
      if (! gimp_item_bounds (GIMP_ITEM (gimp_image_get_mask (image)), &x, &y, &width, &height))
        { width = gimp_image_get_width (image); height = gimp_image_get_height (image); }
      pickables.data = image;
    }
  else
    {
      int x2, y2;
      gimp_item_mask_bounds (GIMP_ITEM (layer), &x, &y, &x2, &y2);
      width = x2 - x; height = y2 - y;
      pickables.data = layer;
    }
  if (! pixel_bytes (width, height, &bytes))
    return glims_fail (error, NULL, "The selected pixels are empty or too large for the clipboard.");

  buffer = gimp_selection_extract (GIMP_SELECTION (gimp_image_get_mask (image)), &pickables,
                                    gimp_get_user_context (engine->gimp), FALSE, FALSE, TRUE,
                                    &offset_x, &offset_y, &gerror);
  if (! buffer)
    return glims_fail (error, gerror, "The selected pixels could not be copied.");
  width = gegl_buffer_get_width (buffer); height = gegl_buffer_get_height (buffer);
  if (! pixel_bytes (width, height, &bytes))
    { g_object_unref (buffer); return GLIMS_STATUS_INVALID_ARGUMENT; }
  result->pixels = g_try_malloc (bytes);
  if (! result->pixels)
    { g_object_unref (buffer); return glims_fail (error, NULL, "Not enough memory to copy these pixels."); }
  result->bounds = (GlimsRect) { offset_x, offset_y, width, height };
  result->byte_count = bytes;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, width, height), 1.0,
                   babl_format ("R'G'B'A u8"), result->pixels, width * 4, GEGL_ABYSS_NONE);
  g_object_unref (buffer);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_clear (GlimsEngine *engine, GlimsImageID id, const GlimsColor *background, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpLayer *layer;
  GlimsStatus status;
  uint32_t locks = GLIMS_LOCK_PIXELS;
  if (! open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  layer = selected_layer (open->image);
  if (! layer || GIMP_IS_GROUP_LAYER (layer))
    return glims_fail (error, NULL, "Select a pixel layer to clear.");
  if (gimp_drawable_has_alpha (GIMP_DRAWABLE (layer))) locks |= GLIMS_LOCK_ALPHA;
  status = glims_check_item_locks (GIMP_ITEM (layer), locks, error);
  if (status != GLIMS_STATUS_OK) return status;
  /* Native Clear honors selection alpha; on a layer without alpha it
   * fills with the background, matching the other engine edit commands. */
  if (background && (! isfinite (background->red) || ! isfinite (background->green) ||
                     ! isfinite (background->blue) || ! isfinite (background->alpha)))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GimpContext *context = gimp_context_new (engine->gimp, "Glims Clear", gimp_get_user_context (engine->gimp));
  if (background)
    {
      GeglColor *color = gegl_color_new (NULL);
      gegl_color_set_rgba (color, CLAMP (background->red, 0, 1), CLAMP (background->green, 0, 1),
                           CLAMP (background->blue, 0, 1), CLAMP (background->alpha, 0, 1));
      gimp_context_set_background (context, color);
      g_object_unref (color);
    }
  gimp_drawable_edit_clear (GIMP_DRAWABLE (layer), context);
  g_object_unref (context);
  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_paste_pixels (GlimsEngine *engine, GlimsImageID id, GlimsRect bounds,
                          const uint8_t *pixels, size_t byte_count, GlimsItemID *result, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpImage *image;
  GeglBuffer *buffer;
  GimpLayer *layer;
  GList selected = { 0 };
  size_t bytes;
  if (result) *result = 0;
  if (! open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy > 0) return GLIMS_STATUS_BUSY;
  if (! pixels || ! pixel_bytes (bounds.width, bounds.height, &bytes) || bytes != byte_count ||
      bounds.x < -GIMP_MAX_IMAGE_SIZE || bounds.x > GIMP_MAX_IMAGE_SIZE ||
      bounds.y < -GIMP_MAX_IMAGE_SIZE || bounds.y > GIMP_MAX_IMAGE_SIZE)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  image = open->image;
  buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, bounds.width, bounds.height), babl_format ("R'G'B'A u8"));
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, bounds.width, bounds.height), 0,
                   babl_format ("R'G'B'A u8"), pixels, bounds.width * 4);
  layer = gimp_layer_new_from_gegl_buffer (buffer, image, gimp_image_get_layer_format (image, TRUE),
                                          "Pasted Layer", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL, NULL);
  g_object_unref (buffer);
  if (! layer) return glims_fail (error, NULL, "The clipboard image could not become a layer.");
  gimp_item_set_offset (GIMP_ITEM (layer), bounds.x, bounds.y);
  gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_EDIT_PASTE, "Paste");
  if (! gimp_image_add_layer (image, layer, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
    {
      gimp_image_undo_group_end (image);
      g_object_unref (layer);
      return glims_fail (error, NULL, "The pasted layer could not be added.");
    }
  selected.data = layer;
  gimp_image_set_selected_layers (image, &selected);
  gimp_image_undo_group_end (image);
  if (result) *result = gimp_item_get_id (GIMP_ITEM (layer));
  gimp_image_flush (image);
  return GLIMS_STATUS_OK;
}
