/*
 * Image > Adjust > Variations. Runs on the engine thread.
 *
 * The dialog accumulates Color Balance corrections for one tonal range
 * plus a master lightness and saturation change, then applies them as a
 * single destructive edit: gimp:color-balance with Preserve Luminosity
 * on, followed by gimp:hue-saturation on the master range. Both run
 * through gimp_drawable_apply_operation inside one undo group named
 * "Variations", so the pair is one undo step and the selection bounds
 * both operations. The two-operation chain cannot go through the live
 * filter sessions (one session holds one operation), which is why this
 * command has its own slots.
 *
 * The preview slot renders the layer's thumbnail exactly as
 * glims_drawable_thumbnail does, then applies the same chain to a float
 * copy. The intermediate result is quantized back to the 8-bit grid
 * before the second operation, because the destructive commit writes
 * each stage into the layer's 8-bit buffer; the final quantization also
 * produces the clipping mask, whose threshold is half a 8-bit step
 * beyond the representable range.
 */
#include "engine-private.h"
#include "color-balance-config.h"
#include "hue-saturation-config.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-operation.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"
#include "core/gimpviewable.h"

#include "libgimpmath/gimpmath.h"

#include "gegl/gimp-gegl-apply-operation.h"
#include "gegl/gimptilehandlervalidate.h"

#include "gimp-intl.h"

/* The preview's long-side cap, the same bound drawable_thumbnail takes. */
#define GLIMS_VARIATIONS_PREVIEW_MAX 256

static gboolean
finite_unit (double value)
{
  return isfinite (value) && value >= -1.0 && value <= 1.0;
}

static gboolean
valid_range (const GlimsColorBalanceRange *range)
{
  return finite_unit (range->cyan_red) && finite_unit (range->magenta_green) &&
         finite_unit (range->yellow_blue);
}

static gboolean
valid_settings (const GlimsVariationsSettings *settings)
{
  return valid_range (&settings->shadows) && valid_range (&settings->midtones) &&
         valid_range (&settings->highlights) &&
         finite_unit (settings->lightness) && finite_unit (settings->saturation);
}

static gboolean
zero_range (const GlimsColorBalanceRange *range)
{
  return range->cyan_red == 0.0 && range->magenta_green == 0.0 && range->yellow_blue == 0.0;
}

static gboolean
identity_settings (const GlimsVariationsSettings *settings)
{
  return zero_range (&settings->shadows) && zero_range (&settings->midtones) &&
         zero_range (&settings->highlights) &&
         settings->lightness == 0.0 && settings->saturation == 0.0;
}

static GlimsStatus
bad_settings (char **error)
{
  return glims_fail (error, NULL,
                     "Variations values must be finite and between -1 and 1.");
}

/* Fills the native Color Balance settings the facade struct maps to:
 * preserve luminosity is always on. */
static void
balance_from (const GlimsVariationsSettings *settings, GlimsColorBalanceSettings *balance)
{
  memset (balance, 0, sizeof *balance);
  balance->struct_size = sizeof *balance;
  balance->preserve_luminosity = 1;
  balance->shadows = settings->shadows;
  balance->midtones = settings->midtones;
  balance->highlights = settings->highlights;
}

/* Fills the native Hue-Saturation settings the facade struct maps to:
 * only the master range carries lightness and saturation, hue stays 0
 * and every other range stays at zero. */
static void
hue_saturation_from (const GlimsVariationsSettings *settings,
                     GlimsHueSaturationSettings *hue)
{
  memset (hue, 0, sizeof *hue);
  hue->struct_size = sizeof *hue;
  hue->master.lightness = settings->lightness;
  hue->master.saturation = settings->saturation;
}

static GlimsStatus
resolve_layer (GlimsEngine *engine, GlimsOpenImage *open, GlimsItemID layer_id,
               GimpLayer **layer)
{
  GimpItem *item = gimp_item_get_by_id (engine->gimp, layer_id);

  if (! item || ! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != open->image ||
      ! gimp_item_is_attached (item))
    return GLIMS_STATUS_NOT_FOUND;

  *layer = GIMP_LAYER (item);
  return GLIMS_STATUS_OK;
}

/* The layer admission the one-click adjustments use, minus the
 * selected-drawable resolution: this command names its layer. */
static GlimsStatus
admit_layer (GimpImage *image, GimpLayer *layer, char **error)
{
  if (GIMP_IS_GROUP_LAYER (layer))
    return glims_fail (error, NULL, "A layer group cannot take Variations.");

  switch (glims_layer_kind (layer))
    {
    case GLIMS_LAYER_PIXEL:
      break;
    case GLIMS_LAYER_GROUP:
      return glims_fail (error, NULL, "A layer group cannot take Variations.");
    default:
      return glims_fail (error, NULL,
                         "Rasterize the text, link or vector layer before using Variations.");
    }

  if (gimp_image_get_base_type (image) != GIMP_RGB)
    {
      glims_fail (error, NULL, "Variations operates only on RGB images.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_variations_apply (GlimsEngine                 *engine,
                              GlimsImageID                 id,
                              GlimsItemID                  layer_id,
                              const GlimsVariationsSettings *settings,
                              char                       **error)
{
  GlimsOpenImage          *open;
  GimpImage               *image;
  GimpLayer               *layer = NULL;
  GimpDrawable            *drawable;
  GlimsColorBalanceSettings balance;
  GlimsHueSaturationSettings hue;
  GeglNode                *node = NULL;
  gboolean                 changed;
  GlimsStatus              status;

  if (error) *error = NULL;
  if (! settings || settings->struct_size < sizeof *settings || ! valid_settings (settings))
    return bad_settings (error);
  if (identity_settings (settings))
    return glims_fail (error, NULL, "Variations has no change to apply.");

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;

  if (engine->busy > 0 || engine->progress || g_hash_table_size (engine->strokes) ||
      g_hash_table_size (engine->filters) || ! gimp_image_undo_is_enabled (image) ||
      gimp_image_get_undo_group_count (image))
    return GLIMS_STATUS_BUSY;
  if (gimp_image_get_floating_selection (image))
    return glims_fail (error, NULL, "Anchor or cancel the floating selection first.");

  status = resolve_layer (engine, open, layer_id, &layer);
  if (status != GLIMS_STATUS_OK)
    return status;
  drawable = GIMP_DRAWABLE (layer);

  status = admit_layer (image, layer, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (! gimp_item_mask_intersect (GIMP_ITEM (drawable), NULL, NULL, NULL, NULL))
    return glims_fail (error, NULL, "The selection does not overlap the layer.");

  balance_from (settings, &balance);
  hue_saturation_from (settings, &hue);

  if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                                     C_("undo-type", "Variations")))
    return glims_fail (error, NULL, "The image history could not group Variations.");

  if (! zero_range (&settings->shadows) || ! zero_range (&settings->midtones) ||
      ! zero_range (&settings->highlights))
    {
      node = gegl_node_new_child (NULL, "operation", "gimp:color-balance", NULL);
      if (! node)
        {
          gimp_image_undo_group_end (image);
          return glims_fail (error, NULL, "The Color Balance operation could not be created.");
        }
      status = glims_color_balance_config_prepare (node, error);
      if (status == GLIMS_STATUS_OK)
        status = glims_color_balance_config_set (node, &balance, &changed, error);
      if (status == GLIMS_STATUS_OK)
        gimp_drawable_apply_operation (drawable, NULL, C_("undo-type", "Color Balance"), node);
      g_object_unref (node);
      node = NULL;
      if (status != GLIMS_STATUS_OK)
        {
          gimp_image_undo_group_end (image);
          return status;
        }
    }

  if (settings->lightness != 0.0 || settings->saturation != 0.0)
    {
      node = gegl_node_new_child (NULL, "operation", "gimp:hue-saturation", NULL);
      if (! node)
        {
          gimp_image_undo_group_end (image);
          return glims_fail (error, NULL, "The Hue-Saturation operation could not be created.");
        }
      status = glims_hue_saturation_config_prepare (node, error);
      if (status == GLIMS_STATUS_OK)
        status = glims_hue_saturation_config_set (node, &hue, &changed, error);
      if (status == GLIMS_STATUS_OK)
        gimp_drawable_apply_operation (drawable, NULL, C_("undo-type", "Hue/Saturation"), node);
      g_object_unref (node);
      node = NULL;
      if (status != GLIMS_STATUS_OK)
        {
          gimp_image_undo_group_end (image);
          return status;
        }
    }

  gimp_image_undo_group_end (image);
  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}

/* Rounds one float channel the way babl writes an 8-bit component. */
static int
quantized_channel (float value)
{
  /* Keep the scaled value inside int range even for an extreme
   * overshoot; the clamping below makes the answer 0 or 255 anyway. */
  float scaled = CLAMP (value, -1.0f, 2.0f) * 255.0f + 0.5f;
  return CLAMP ((int) scaled, 0, 255);
}

/* Copies `source` into `destination` through the 8-bit grid, the
 * intermediate step that matches the destructive commit writing each
 * stage into the layer's 8-bit buffer. */
static void
quantize_to_grid (const float *source, float *destination, size_t channels)
{
  for (size_t i = 0; i < channels; i++)
    destination[i] = (float) quantized_channel (source[i]) / 255.0f;
}

/* Builds one operation node and runs it from `source` to `destination`,
 * two float RGBA buffers of the same extent. Returns the settings or
 * preparation failure; OK means the operation produced output. */
static GlimsStatus
apply_float_operation (const char *operation, const GlimsVariationsSettings *settings,
                       GeglBuffer *source, GeglBuffer *destination, char **error)
{
  GeglNode                *node;
  GlimsColorBalanceSettings balance;
  GlimsHueSaturationSettings hue;
  gboolean                 changed;
  GlimsStatus              status;

  node = gegl_node_new_child (NULL, "operation", operation, NULL);
  if (! node)
    return glims_fail (error, NULL, "The Variations operation could not be created.");

  if (! strcmp (operation, "gimp:color-balance"))
    {
      balance_from (settings, &balance);
      status = glims_color_balance_config_prepare (node, error);
      if (status == GLIMS_STATUS_OK)
        status = glims_color_balance_config_set (node, &balance, &changed, error);
    }
  else
    {
      hue_saturation_from (settings, &hue);
      status = glims_hue_saturation_config_prepare (node, error);
      if (status == GLIMS_STATUS_OK)
        status = glims_hue_saturation_config_set (node, &hue, &changed, error);
    }

  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (node);
      return status;
    }

  /* The caller created both buffers; the rectangle covers their whole
   * extent, so no crop is needed and the source connects directly. */
  gimp_gegl_apply_operation (source, NULL, NULL, node, destination, NULL, FALSE);
  g_object_unref (node);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_variations_preview (GlimsEngine                 *engine,
                                GlimsImageID                 id,
                                GlimsItemID                  layer_id,
                                const GlimsVariationsSettings *settings,
                                int32_t                      max_size,
                                uint8_t                     *pixels,
                                size_t                       byte_count,
                                uint8_t                     *clipping,
                                size_t                       clipping_byte_count,
                                int32_t                     *width,
                                int32_t                     *height,
                                char                       **error)
{
  GlimsOpenImage     *open;
  GimpDrawable       *drawable;
  GeglBuffer         *buffer = NULL;
  const GeglRectangle *extent;
  gint                w, h, out_w, out_h;
  gdouble             scale;
  size_t              need, pixel_count, channels;
  uint8_t            *thumbnail = NULL;
  float              *source = NULL, *destination = NULL, *final;
  GeglBuffer         *source_buffer = NULL, *destination_buffer = NULL;
  const Babl         *float_format;
  GeglRectangle       rect;

  if (error) *error = NULL;
  if (! width || ! height)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *width = 0;
  *height = 0;
  if (max_size < 1 || max_size > GLIMS_VARIATIONS_PREVIEW_MAX)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! settings || settings->struct_size < sizeof *settings || ! valid_settings (settings))
    return bad_settings (error);

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  drawable = glims_lookup_drawable (open, layer_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;

  w = gimp_item_get_width (GIMP_ITEM (drawable));
  h = gimp_item_get_height (GIMP_ITEM (drawable));
  if (w < 1 || h < 1)
    return GLIMS_STATUS_FAILED;

  scale = MIN ((gdouble) max_size / w, (gdouble) max_size / h);
  scale = MIN (scale, 1.0);
  out_w = MAX (1, (gint) RINT (w * scale));
  out_h = MAX (1, (gint) RINT (h * scale));
  need = (size_t) out_w * (size_t) out_h * 4;

  *width = out_w;
  *height = out_h;
  if (! pixels)
    return GLIMS_STATUS_OK;   /* a size query; clipping is ignored */
  if (byte_count < need)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (clipping && clipping_byte_count < need / 4)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* The layer's own thumbnail, exactly as glims_drawable_thumbnail
   * reads it: effects included, never upscaled, clamped at the edges. */
  thumbnail = g_try_malloc (need);
  if (! thumbnail)
    return GLIMS_STATUS_FAILED;

  gimp_pickable_flush (GIMP_PICKABLE (drawable));
  buffer = gimp_drawable_get_buffer_with_effects (drawable);
  if (! buffer)
    {
      g_free (thumbnail);
      return GLIMS_STATUS_FAILED;
    }
  extent = gegl_buffer_get_extent (buffer);
  if (scale == 1.0 && out_w == 1 && out_h == 1)
    {
      GimpTileHandlerValidate *validate = gimp_tile_handler_validate_get_assigned (buffer);
      if (validate)
        {
          GeglRectangle area = { extent->x, extent->y, 1, 1 };
          gimp_tile_handler_validate_validate (validate, buffer, &area, TRUE, FALSE);
        }
    }
  gegl_buffer_get (buffer,
                   GEGL_RECTANGLE ((gint) RINT (extent->x * scale),
                                   (gint) RINT (extent->y * scale),
                                   out_w, out_h),
                   scale,
                   babl_format ("R'G'B'A u8"),
                   thumbnail,
                   (gint) out_w * 4,
                   GEGL_ABYSS_CLAMP);
  g_object_unref (buffer);
  buffer = NULL;

  pixel_count = (size_t) out_w * out_h;
  channels = pixel_count * 4;
  float_format = babl_format ("R'G'B'A float");
  source = g_try_malloc (channels * sizeof (float));
  destination = g_try_malloc (channels * sizeof (float));
  if (! source || ! destination)
    {
      g_free (source);
      g_free (destination);
      g_free (thumbnail);
      return GLIMS_STATUS_FAILED;
    }

  babl_process (babl_fish (babl_format ("R'G'B'A u8"), float_format),
                thumbnail, source, pixel_count);
  g_free (thumbnail);
  thumbnail = NULL;

  rect = (GeglRectangle) { 0, 0, out_w, out_h };
  if (! zero_range (&settings->shadows) || ! zero_range (&settings->midtones) ||
      ! zero_range (&settings->highlights))
    {
      source_buffer = gegl_buffer_new (&rect, float_format);
      destination_buffer = gegl_buffer_new (&rect, float_format);
      if (! source_buffer || ! destination_buffer)
        {
          g_clear_object (&source_buffer);
          g_clear_object (&destination_buffer);
          g_free (source);
          g_free (destination);
          return GLIMS_STATUS_FAILED;
        }
      gegl_buffer_set (source_buffer, &rect, 0, float_format, source, GEGL_AUTO_ROWSTRIDE);
      if (apply_float_operation ("gimp:color-balance", settings, source_buffer,
                                 destination_buffer, error) != GLIMS_STATUS_OK)
        {
          g_clear_object (&source_buffer);
          g_clear_object (&destination_buffer);
          g_free (source);
          g_free (destination);
          return GLIMS_STATUS_FAILED;
        }
      gegl_buffer_get (destination_buffer, &rect, 1.0, float_format, destination,
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      g_clear_object (&source_buffer);
      g_clear_object (&destination_buffer);
      /* The destructive commit quantized this stage into the layer's
       * 8-bit buffer before the next operation read it back. */
      quantize_to_grid (destination, source, channels);
    }

  if (settings->lightness != 0.0 || settings->saturation != 0.0)
    {
      source_buffer = gegl_buffer_new (&rect, float_format);
      destination_buffer = gegl_buffer_new (&rect, float_format);
      if (! source_buffer || ! destination_buffer)
        {
          g_clear_object (&source_buffer);
          g_clear_object (&destination_buffer);
          g_free (source);
          g_free (destination);
          return GLIMS_STATUS_FAILED;
        }
      gegl_buffer_set (source_buffer, &rect, 0, float_format, source, GEGL_AUTO_ROWSTRIDE);
      if (apply_float_operation ("gimp:hue-saturation", settings, source_buffer,
                                 destination_buffer, error) != GLIMS_STATUS_OK)
        {
          g_clear_object (&source_buffer);
          g_clear_object (&destination_buffer);
          g_free (source);
          g_free (destination);
          return GLIMS_STATUS_FAILED;
        }
      gegl_buffer_get (destination_buffer, &rect, 1.0, float_format, destination,
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      g_clear_object (&source_buffer);
      g_clear_object (&destination_buffer);
    }

  final = (settings->lightness != 0.0 || settings->saturation != 0.0) ? destination : source;

  for (size_t i = 0; i < pixel_count; i++)
    {
      gboolean clipped = FALSE;
      for (size_t c = 0; c < 4; c++)
        {
          float value = final[i * 4 + c];
          if (c < 3 && (value < -0.5f / 255.0f || value > 1.0f + 0.5f / 255.0f))
            clipped = TRUE;
          pixels[i * 4 + c] = (uint8_t) quantized_channel (value);
        }
      if (clipping)
        clipping[i] = clipped ? 255 : 0;
    }

  g_free (source);
  g_free (destination);
  return GLIMS_STATUS_OK;
}
