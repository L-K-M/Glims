/*
 * Image > Apply Image and Image > Calculations. Runs on the engine thread.
 *
 * Both commands blend one or two channels through the pure kernel in
 * apply-image-math.h, on straight nonlinear sRGB floats. Apply Image
 * writes into a layer or a saved channel of one image, limited by the
 * current selection, as one undo step named "Blend With Image". Calculations
 * blends two single channels and puts the result into a new saved channel,
 * a new selection or a new grayscale image as one undo step named
 * "Blend Channels".
 *
 * Sources and masks are resolved once into owned snapshots before the
 * target is touched. Layers are read with their effects, exactly as
 * filter-input.c reads captured sources; the merged visible image goes
 * through glims_projection_prepare_read and its borrowed buffer is copied
 * out. Saved channels and selections are read through the same linear
 * luminance mask path Color Range uses. A layer or channel outside the
 * target image stays transparent, so it contributes nothing.
 */
#include "engine-private.h"
#include "apply-image-math.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpchannel-select.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"

#include "gegl/gimp-babl.h"

#include "libgimpmath/gimpmath.h"

#include "gimp-intl.h"

/* Rows processed per band. Bounds the float scratch buffers to about a
 * quarter of the working set whatever the image height. */
#define GLIMS_APPLY_BAND_ROWS 64

/* A selection value within half an 8-bit step counts as unchanged, so a
 * no-op NEW_SELECTION does not push a step for rounding alone. */
#define GLIMS_APPLY_HALF_STEP (0.5f / 255.0f)

static GlimsStatus
refuse (char **error, GlimsStatus status, const char *message)
{
  glims_fail (error, NULL, message);
  return status;
}

/* Drops a channel's cached bounds and "full" flag, as select.c does after
 * writing a new mask through gimp_channel_select_buffer. */
static void
forget_mask_state (GimpChannel *mask)
{
  gimp_drawable_invalidate_boundary (GIMP_DRAWABLE (mask));
}

static float *
alloc_pixels (gint width, gint height)
{
  return g_try_malloc0 ((gsize) width * (gsize) height * 4 * sizeof (float));
}

static float *
alloc_scalars (gint width, gint height)
{
  return g_try_malloc0 ((gsize) width * (gsize) height * sizeof (float));
}

/* ---- Settings -------------------------------------------------------- */

static gboolean
valid_ref_kind (uint32_t channel, gboolean mask)
{
  if (mask && channel == GLIMS_CHANNEL_NONE)
    return TRUE;
  return channel >= GLIMS_CHANNEL_COMPOSITE && channel <= GLIMS_CHANNEL_SAVED;
}

static GlimsStatus
validate_ref (const GlimsChannelRef *ref, gboolean mask, char **error)
{
  if (! ref || ref->struct_size < sizeof *ref)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "A channel reference is incomplete.");
  if (ref->invert > 1)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Invert must be on or off.");
  if (! valid_ref_kind (ref->channel, mask))
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Choose a channel for the source or mask.");
  return GLIMS_STATUS_OK;
}

static void
math_from (uint32_t mode, double opacity, double scale, double offset,
           uint32_t invert_source, uint32_t invert_mask, GlimsAIMath *math)
{
  math->mode = mode;
  math->opacity = opacity;
  math->scale = scale;
  math->offset = offset;
  math->invert_source = invert_source;
  math->invert_mask = invert_mask;
}

static GlimsStatus
validate_apply (const GlimsApplyImageSettings *settings, GlimsAIMath *math,
                char **error)
{
  GlimsStatus status;

  if (! settings || settings->struct_size < sizeof *settings)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "The Blend With Image settings are incomplete.");
  status = validate_ref (&settings->source, FALSE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = validate_ref (&settings->mask, TRUE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  if (settings->source.channel == GLIMS_CHANNEL_NONE)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Blend With Image needs a source channel.");

  math_from (settings->mode, settings->opacity, settings->scale,
             settings->offset, settings->source.invert, settings->mask.invert, math);
  if (! glims_ai_settings_valid (math))
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Blend With Image's mode, opacity, scale or offset is invalid.");
  return GLIMS_STATUS_OK;
}

static GlimsStatus
validate_calculations (const GlimsCalculationsSettings *settings,
                       GlimsAIMath *math, char **error)
{
  GlimsStatus status;

  if (! settings || settings->struct_size < sizeof *settings)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "The Blend Channels settings are incomplete.");
  status = validate_ref (&settings->first, FALSE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = validate_ref (&settings->second, FALSE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = validate_ref (&settings->mask, TRUE, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (settings->first.channel == GLIMS_CHANNEL_NONE ||
      settings->first.channel == GLIMS_CHANNEL_COMPOSITE ||
      settings->second.channel == GLIMS_CHANNEL_NONE ||
      settings->second.channel == GLIMS_CHANNEL_COMPOSITE)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Blend Channels needs two single channels.");

  if (settings->destination < GLIMS_CALCULATIONS_NEW_CHANNEL ||
      settings->destination > GLIMS_CALCULATIONS_NEW_IMAGE)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Choose where Blend Channels puts its result.");

  math_from (settings->mode, settings->opacity, settings->scale,
             settings->offset, settings->second.invert, settings->mask.invert, math);
  if (! glims_ai_settings_valid (math))
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Blend Channels' mode, opacity, scale or offset is invalid.");
  return GLIMS_STATUS_OK;
}

/* ---- Images, layers and channels ------------------------------------- */

static GlimsStatus
admit_document (GlimsOpenImage *open, char **error)
{
  if (open->component_document)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED,
                   "This command is not available for component documents.");
  if (gimp_image_get_base_type (open->image) == GIMP_INDEXED)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED,
                   "This command is unavailable for indexed images.");
  return GLIMS_STATUS_OK;
}

static GlimsStatus
same_size (GlimsOpenImage *open, gint width, gint height,
           const char *command, char **error)
{
  if (gimp_image_get_width (open->image) == width &&
      gimp_image_get_height (open->image) == height)
    return GLIMS_STATUS_OK;
  if (strcmp (command, "Blend Channels") == 0)
    return refuse (error, GLIMS_STATUS_FAILED,
                   "Blend Channels needs images of the same pixel size.");
  return refuse (error, GLIMS_STATUS_FAILED,
                 "Blend With Image needs images of the same pixel size.");
}

static GlimsStatus
resolve_source_layer (GlimsEngine *engine, GlimsOpenImage *open, GlimsItemID id,
                      GimpLayer **layer, char **error)
{
  GimpItem *item;

  *layer = NULL;
  if (id == 0)
    return GLIMS_STATUS_OK;

  item = gimp_item_get_by_id (engine->gimp, id);
  if (! item || ! GIMP_IS_LAYER (item) ||
      gimp_item_get_image (item) != open->image || ! gimp_item_is_attached (item))
    return GLIMS_STATUS_NOT_FOUND;

  if (GIMP_IS_GROUP_LAYER (item))
    return refuse (error, GLIMS_STATUS_UNSUPPORTED,
                   "A layer group cannot be used as an Blend With Image source.");
  switch (glims_layer_kind (GIMP_LAYER (item)))
    {
    case GLIMS_LAYER_PIXEL:
      break;
    default:
      return refuse (error, GLIMS_STATUS_UNSUPPORTED,
                     "Rasterize the text, link or vector layer before using it as a source.");
    }

  *layer = GIMP_LAYER (item);
  return GLIMS_STATUS_OK;
}

/* Resolves the command's write target: a raster layer or a saved channel
 * of `open`'s image. Returns the drawable and whether it is a channel. */
static GlimsStatus
resolve_target (GlimsEngine *engine, GlimsOpenImage *open, GlimsItemID target,
                GimpDrawable **drawable, gboolean *is_channel, char **error)
{
  GimpItem *item = gimp_item_get_by_id (engine->gimp, target);

  if (is_channel)
    *is_channel = FALSE;
  *drawable = NULL;
  if (! item || gimp_item_get_image (item) != open->image ||
      ! gimp_item_is_attached (item))
    return GLIMS_STATUS_NOT_FOUND;

  if (GIMP_IS_LAYER (item))
    {
      if (GIMP_IS_GROUP_LAYER (item))
        return refuse (error, GLIMS_STATUS_UNSUPPORTED,
                       "Blend With Image cannot change a layer group.");
      switch (glims_layer_kind (GIMP_LAYER (item)))
        {
        case GLIMS_LAYER_PIXEL:
          break;
        default:
          return refuse (error, GLIMS_STATUS_UNSUPPORTED,
                         "Rasterize the text, link or vector layer before using Blend With Image.");
        }
      *drawable = GIMP_DRAWABLE (item);
      return GLIMS_STATUS_OK;
    }

  if (GIMP_IS_CHANNEL (item))
    {
      if (! glims_find_channel (open->image, target))
        return GLIMS_STATUS_NOT_FOUND;
      *drawable = GIMP_DRAWABLE (item);
      if (is_channel)
        *is_channel = TRUE;
      return GLIMS_STATUS_OK;
    }

  return GLIMS_STATUS_NOT_FOUND;
}

/* Refuses while a stroke, filter session or plug-in is running. A command
 * that only creates a new image needs no more than this. */
static GlimsStatus
engine_gate (GlimsEngine *engine, char **error)
{
  if (engine->busy > 0 || engine->progress ||
      g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters))
    return refuse (error, GLIMS_STATUS_BUSY,
                   "Finish the stroke or close the filter dialog first.");
  return GLIMS_STATUS_OK;
}

static GlimsStatus
edit_gate (GlimsEngine *engine, GlimsOpenImage *open, gboolean floating,
           char **error)
{
  GimpImage  *image = open->image;
  GlimsStatus status = engine_gate (engine, error);

  if (status != GLIMS_STATUS_OK)
    return status;
  if (! gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image))
    return refuse (error, GLIMS_STATUS_BUSY,
                   "Finish the stroke or close the filter dialog first.");
  if (floating && gimp_image_get_floating_selection (image))
    return refuse (error, GLIMS_STATUS_BUSY,
                   "Anchor or cancel the floating selection first.");
  return GLIMS_STATUS_OK;
}

/* ---- Buffer reads ---------------------------------------------------- */

/* A drawable's buffer is item-local: coordinate 0 sits at the item's
 * offset, the convention matting and Color Range already read with. */
static void
item_origin (GimpItem *item, gint *x, gint *y)
{
  gimp_item_get_offset (item, x, y);
}

/* Copies the clipped intersection of `buffer` with the canvas into `out`
 * as straight nonlinear sRGB RGBA floats. Areas outside stay zero, so a
 * source layer's transparent margin carries no weight. */
static void
read_rgba_full (GeglBuffer *buffer, gint origin_x, gint origin_y,
                gint canvas_w, gint canvas_h, float *out)
{
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  gint dx0 = MAX (0, origin_x), dy0 = MAX (0, origin_y);
  gint dx1 = MIN (canvas_w, origin_x + extent->width);
  gint dy1 = MIN (canvas_h, origin_y + extent->height);
  GeglRectangle src;

  if (dx1 <= dx0 || dy1 <= dy0)
    return;
  src.x = dx0 - origin_x;
  src.y = dy0 - origin_y;
  src.width = dx1 - dx0;
  src.height = dy1 - dy0;
  gegl_buffer_get (buffer, &src, 1.0, babl_format ("R'G'B'A float"),
                   out + ((gsize) dy0 * canvas_w + dx0) * 4,
                   canvas_w * 4 * (gint) sizeof (float), GEGL_ABYSS_NONE);
}

/* GIMP keeps masks linear except saved channels of 8-bit perceptual
 * images, which are "Y' u8" and which it copies without a gamma conversion
 * (gimp-gegl-mask-combine.cc), so a channel's stored value is its coverage.
 * Reading and writing in the buffer's own curve keeps that value. */
static const Babl *
coverage_format (GeglBuffer *buffer)
{
  return gimp_babl_format_change_component_type (gegl_buffer_get_format (buffer),
                                                 GIMP_COMPONENT_TYPE_FLOAT);
}

static void
read_scalar_full (GeglBuffer *buffer, gint origin_x, gint origin_y,
                  gint canvas_w, gint canvas_h, float *out)
{
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  gint dx0 = MAX (0, origin_x), dy0 = MAX (0, origin_y);
  gint dx1 = MIN (canvas_w, origin_x + extent->width);
  gint dy1 = MIN (canvas_h, origin_y + extent->height);
  GeglRectangle src;

  if (dx1 <= dx0 || dy1 <= dy0)
    return;
  src.x = dx0 - origin_x;
  src.y = dy0 - origin_y;
  src.width = dx1 - dx0;
  src.height = dy1 - dy0;
  gegl_buffer_get (buffer, &src, 1.0, coverage_format (buffer),
                   out + (gsize) dy0 * canvas_w + dx0,
                   canvas_w * (gint) sizeof (float), GEGL_ABYSS_NONE);
}

/* Previews snapshot their inputs at canvas size and average a window of
 * them down with a box filter, without a window-size copy. Window samples
 * outside the canvas count as zero, so a layer partly off the canvas keeps
 * its transparency. The box is exact on the flat colors the tests use and
 * avoids asking GEGL to resample an offset layer through an abyss. */
typedef struct
{
  gint x, y, width, height;   /* canvas coordinates; may leave the canvas */
} PreviewWindow;

/* The window samples [*start, *end) that preview sample `index` of `size`
 * averages. Never empty. */
static void
box_span (gint index, gint size, gint window, gint *start, gint *end)
{
  *start = (gint) floor ((gdouble) index * window / size);
  *end = MAX (*start + 1, (gint) ceil ((gdouble) (index + 1) * window / size));
  if (*end > window)
    *end = window;
}

static void
scale_box (const float *src, gint src_w, gint src_h, gint components,
           const PreviewWindow *window, gint dst_w, gint dst_h, float *dst)
{
  for (gint dy = 0; dy < dst_h; dy++)
    {
      gint wy0, wy1, sy0, sy1;

      box_span (dy, dst_h, window->height, &wy0, &wy1);
      sy0 = MAX (0, window->y + wy0);
      sy1 = MIN (src_h, window->y + wy1);

      for (gint dx = 0; dx < dst_w; dx++)
        {
          gint   wx0, wx1, sx0, sx1;
          double sum[4] = { 0.0, 0.0, 0.0, 0.0 };
          double n;
          float *out = dst + ((gsize) dy * dst_w + dx) * components;

          box_span (dx, dst_w, window->width, &wx0, &wx1);
          sx0 = MAX (0, window->x + wx0);
          sx1 = MIN (src_w, window->x + wx1);
          n = (double) (wy1 - wy0) * (wx1 - wx0);
          for (gint sy = sy0; sy < sy1; sy++)
            for (gint sx = sx0; sx < sx1; sx++)
              {
                const float *in = src + ((gsize) sy * src_w + sx) * components;

                for (gint c = 0; c < components; c++)
                  sum[c] += in[c];
              }
          for (gint c = 0; c < components; c++)
            out[c] = (float) (sum[c] / n);
        }
    }
}

/* Extracts one plane in place: the RGB triple becomes the plane's value,
 * the alpha (source coverage) is kept. */
static void
extract_channel (uint32_t channel, float *rgba, size_t count)
{
  for (size_t i = 0; i < count; i++)
    {
      float value;

      switch (channel)
        {
        case GLIMS_CHANNEL_RED:   value = rgba[i * 4]; break;
        case GLIMS_CHANNEL_GREEN: value = rgba[i * 4 + 1]; break;
        case GLIMS_CHANNEL_BLUE:  value = rgba[i * 4 + 2]; break;
        case GLIMS_CHANNEL_GRAY:
          value = glims_ai_luma (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]);
          break;
        case GLIMS_CHANNEL_ALPHA: value = rgba[i * 4 + 3]; break;
        default: continue;
        }
      rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = CLAMP (value, 0.0f, 1.0f);
    }
}

static GlimsStatus
read_channel_scalar_full (GlimsOpenImage *open, const GlimsChannelRef *ref,
                          gint width, gint height,
                          float **values_out, char **error)
{
  GimpChannel *channel;
  GeglBuffer *buffer;
  gint origin_x, origin_y;
  float *values;

  *values_out = NULL;
  if (ref->channel == GLIMS_CHANNEL_SELECTION)
    {
      channel = gimp_image_get_mask (open->image);
      if (gimp_channel_is_empty (channel))
        {
          values = alloc_scalars (width, height);
          if (! values)
            return glims_fail (error, NULL, "Not enough memory to read the selection.");
          *values_out = values;
          return GLIMS_STATUS_OK;
        }
    }
  else
    {
      channel = glims_find_channel (open->image, ref->item);
      if (! channel)
        return GLIMS_STATUS_NOT_FOUND;
    }

  buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (channel));
  if (! buffer)
    return glims_fail (error, NULL, "The channel's pixels could not be read.");
  values = alloc_scalars (width, height);
  if (! values)
    return glims_fail (error, NULL, "Not enough memory to read the channel.");
  item_origin (GIMP_ITEM (channel), &origin_x, &origin_y);
  read_scalar_full (buffer, origin_x, origin_y, width, height, values);
  *values_out = values;
  return GLIMS_STATUS_OK;
}

/* Resolves one channel reference into an owned RGBA canvas. SELECTION and
 * SAVED arrive as opaque grayscale; the layer kinds keep their alpha as
 * source coverage; a single-plane kind is replicated to RGB. */
static GlimsStatus
snapshot_ref (GlimsEngine *engine, const GlimsChannelRef *ref,
              gint width, gint height, const char *command,
              float **rgba_out, char **error)
{
  GlimsOpenImage *open;
  float *rgba = NULL;
  GlimsStatus status;

  *rgba_out = NULL;
  open = glims_lookup_image (engine, ref->image);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  status = admit_document (open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = same_size (open, width, height, command, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  rgba = alloc_pixels (width, height);
  if (! rgba)
    return glims_fail (error, NULL, "Not enough memory to snapshot the source.");

  if (ref->channel == GLIMS_CHANNEL_SELECTION ||
      ref->channel == GLIMS_CHANNEL_SAVED)
    {
      float *values = NULL;

      status = read_channel_scalar_full (open, ref, width, height,
                                         &values, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_free (rgba);
          return status;
        }
      for (gsize i = 0; i < (gsize) width * height; i++)
        {
          rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = values[i];
          rgba[i * 4 + 3] = 1.0f;
        }
      g_free (values);
      *rgba_out = rgba;
      return GLIMS_STATUS_OK;
    }

  {
    GimpLayer *layer = NULL;
    GeglBuffer *buffer = NULL;
    gint origin_x, origin_y;

    status = resolve_source_layer (engine, open, ref->layer, &layer, error);
    if (status != GLIMS_STATUS_OK)
      {
        g_free (rgba);
        return status;
      }

    if (! layer)
      {
        GeglBuffer *projection = NULL;

        status = glims_projection_prepare_read (open, 1.0,
                                               (GlimsRect) { 0, 0, width, height },
                                               &projection);
        if (status != GLIMS_STATUS_OK)
          {
            g_free (rgba);
            return status;
          }
        read_rgba_full (projection, 0, 0, width, height, rgba);
        projection = NULL;   /* borrowed; never unref */
      }
    else
      {
        gimp_pickable_flush (GIMP_PICKABLE (layer));
        buffer = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (layer));
        if (! buffer)
          {
            g_free (rgba);
            return glims_fail (error, NULL, "The source pixels could not be read.");
          }
        item_origin (GIMP_ITEM (layer), &origin_x, &origin_y);
        read_rgba_full (buffer, origin_x, origin_y, width, height, rgba);
        g_object_unref (buffer);
      }
  }

  if (ref->channel != GLIMS_CHANNEL_COMPOSITE)
    extract_channel (ref->channel, rgba, (gsize) width * height);
  *rgba_out = rgba;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
snapshot_mask (GlimsEngine *engine, const GlimsChannelRef *mask,
               gint width, gint height, const char *command,
               float **values_out, char **error)
{
  float *rgba = NULL, *values;
  GlimsStatus status;

  *values_out = NULL;
  if (mask->channel == GLIMS_CHANNEL_NONE)
    return GLIMS_STATUS_OK;

  status = snapshot_ref (engine, mask, width, height, command, &rgba, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  values = alloc_scalars (width, height);
  if (! values)
    {
      g_free (rgba);
      return glims_fail (error, NULL, "Not enough memory to read the mask.");
    }
  for (gsize i = 0; i < (gsize) width * height; i++)
    values[i] = mask->channel == GLIMS_CHANNEL_COMPOSITE
      ? glims_ai_luma (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
      : rgba[i * 4];
  g_free (rgba);
  *values_out = values;
  return GLIMS_STATUS_OK;
}

static GlimsStatus
snapshot_selection (GimpImage *image, gint width, gint height,
                    float **values_out, char **error)
{
  GimpChannel *mask = gimp_image_get_mask (image);
  GeglBuffer *buffer;
  gint origin_x, origin_y;
  float *values;

  *values_out = NULL;
  if (gimp_channel_is_empty (mask))
    return GLIMS_STATUS_OK;

  buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (mask));
  if (! buffer)
    return glims_fail (error, NULL, "The selection could not be read.");
  values = alloc_scalars (width, height);
  if (! values)
    return glims_fail (error, NULL, "Not enough memory to read the selection.");
  item_origin (GIMP_ITEM (mask), &origin_x, &origin_y);
  read_scalar_full (buffer, origin_x, origin_y, width, height, values);
  *values_out = values;
  return GLIMS_STATUS_OK;
}

/* Reads the preview target into an owned canvas-sized RGBA snapshot in
 * straight nonlinear sRGB. A channel target is opaque gray; a layer is
 * placed at its offset, with transparency outside its bounds. */
static GlimsStatus
read_target_rgba_full (GlimsOpenImage *open, GimpDrawable *target,
                       gboolean is_channel, gint width, gint height,
                       float **rgba_out, char **error)
{
  float *rgba;
  GlimsStatus status;

  *rgba_out = NULL;
  rgba = alloc_pixels (width, height);
  if (! rgba)
    return glims_fail (error, NULL, "Not enough memory for the preview target.");

  if (is_channel)
    {
      float *values = NULL;

      status = read_channel_scalar_full (open,
          &(GlimsChannelRef) { .struct_size = sizeof (GlimsChannelRef),
                                .channel = GLIMS_CHANNEL_SAVED,
                                .item = gimp_item_get_id (GIMP_ITEM (target)) },
          width, height, &values, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_free (rgba);
          return status;
        }
      for (gsize i = 0; i < (gsize) width * height; i++)
        {
          rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = values[i];
          rgba[i * 4 + 3] = 1.0f;
        }
      g_free (values);
      *rgba_out = rgba;
      return GLIMS_STATUS_OK;
    }

  {
    GeglBuffer *buffer = gimp_drawable_get_buffer (target);
    gint origin_x, origin_y;

    if (! buffer)
      {
        g_free (rgba);
        return glims_fail (error, NULL, "The target pixels could not be read.");
      }
    item_origin (GIMP_ITEM (target), &origin_x, &origin_y);
    read_rgba_full (buffer, origin_x, origin_y, width, height, rgba);
  }

  *rgba_out = rgba;
  return GLIMS_STATUS_OK;
}

static uint8_t
quantized_byte (float value)
{
  return (uint8_t) CLAMP ((gint) (CLAMP (value, 0.0f, 1.0f) * 255.0f + 0.5f), 0, 255);
}

static void
include_pixel (GeglRectangle *damage, gboolean *any, gint x, gint y)
{
  if (! *any)
    {
      *damage = (GeglRectangle) { x, y, 1, 1 };
      *any = TRUE;
    }
  else
    {
      gint x0 = MIN (damage->x, x), y0 = MIN (damage->y, y);
      gint x1 = MAX (damage->x + damage->width - 1, x);
      gint y1 = MAX (damage->y + damage->height - 1, y);
      *damage = (GeglRectangle) { x0, y0, x1 - x0 + 1, y1 - y0 + 1 };
    }
}

/* The float comparison in the band loop also flags changes smaller than
 * the target's storage step. Comparing the stored bytes of `before` and
 * `after` (same format) shrinks `damage` to the pixels that really change,
 * so a blend that rounds back to the same pixels adds no undo step.
 * Returns FALSE when no stored byte differs. If the row buffers cannot be
 * allocated, `damage` is kept as it is. */
static gboolean
native_damage (GeglBuffer *before, GeglBuffer *after, GeglRectangle *damage)
{
  const Babl   *format = gegl_buffer_get_format (before);
  gsize         bpp = (gsize) babl_format_get_bytes_per_pixel (format);
  guint8       *old_row = g_try_malloc ((gsize) damage->width * bpp);
  guint8       *new_row = g_try_malloc ((gsize) damage->width * bpp);
  GeglRectangle tight = { 0, 0, 0, 0 };
  gboolean      any = FALSE;

  if (! old_row || ! new_row)
    {
      g_free (old_row);
      g_free (new_row);
      return TRUE;
    }

  for (gint y = damage->y; y < damage->y + damage->height; y++)
    {
      GeglRectangle row = { damage->x, y, damage->width, 1 };

      gegl_buffer_get (before, &row, 1.0, format, old_row,
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      gegl_buffer_get (after, &row, 1.0, format, new_row,
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      if (memcmp (old_row, new_row, (gsize) damage->width * bpp) == 0)
        continue;
      for (gint x = 0; x < damage->width; x++)
        if (memcmp (old_row + (gsize) x * bpp, new_row + (gsize) x * bpp, bpp) != 0)
          include_pixel (&tight, &any, damage->x + x, y);
    }

  g_free (old_row);
  g_free (new_row);
  if (any)
    *damage = tight;
  return any;
}

/* ---- Apply Image ----------------------------------------------------- */

GlimsStatus
glims_image_apply_image (GlimsEngine *engine, GlimsImageID id, GlimsItemID target_id,
                         const GlimsApplyImageSettings *settings, char **error)
{
  GlimsOpenImage *open;
  GimpImage      *image;
  GimpDrawable   *target;
  GlimsAIMath     math;
  float          *source = NULL, *mask_values = NULL, *selection = NULL;
  float          *rgba = NULL, *out = NULL, *coverage = NULL;
  GeglBuffer     *pixels = NULL, *candidate = NULL;
  const Babl     *float_format;
  const Babl     *channel_format = NULL;
  gboolean        target_is_channel = FALSE;
  gint            width, height, offset_x, offset_y;
  gint            target_w, target_h, x0, y0, x1, y1;
  gint            band_rows;
  gboolean        changed = FALSE;
  GeglRectangle   damage = { 0, 0, 0, 0 };
  GlimsStatus     status;

  if (error) *error = NULL;
  status = validate_apply (settings, &math, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;
  status = admit_document (open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = edit_gate (engine, open, TRUE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = resolve_target (engine, open, target_id, &target, &target_is_channel,
                           error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  width = gimp_image_get_width (image);
  height = gimp_image_get_height (image);
  status = snapshot_ref (engine, &settings->source, width, height,
                         "Blend With Image", &source, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = snapshot_mask (engine, &settings->mask, width, height,
                          "Blend With Image", &mask_values, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  status = snapshot_selection (image, width, height, &selection, error);
  if (status != GLIMS_STATUS_OK)
    goto done;

  gimp_item_get_offset (GIMP_ITEM (target), &offset_x, &offset_y);
  target_w = gimp_item_get_width (GIMP_ITEM (target));
  target_h = gimp_item_get_height (GIMP_ITEM (target));
  x0 = MAX (0, -offset_x);
  y0 = MAX (0, -offset_y);
  x1 = MIN (target_w, width - offset_x);
  y1 = MIN (target_h, height - offset_y);
  if (x1 <= x0 || y1 <= y0)
    goto done;   /* nothing of the target lies on the canvas */

  pixels = g_object_ref (gimp_drawable_get_buffer (target));
  if (! pixels)
    {
      status = glims_fail (error, NULL, "The target pixels could not be read.");
      goto done;
    }
  candidate = gegl_buffer_dup (pixels);
  if (target_is_channel)
    channel_format = coverage_format (pixels);
  /* The kernel is defined on straight nonlinear sRGB, so every target is
   * read and written through that space regardless of its native curve. */
  float_format = babl_format ("R'G'B'A float");
  if (! candidate || ! float_format || (target_is_channel && ! channel_format))
    {
      status = glims_fail (error, NULL, "The target pixels could not be prepared.");
      goto done;
    }
  band_rows = MIN (GLIMS_APPLY_BAND_ROWS, y1 - y0);
  rgba = g_try_malloc ((gsize) (x1 - x0) * band_rows * 4 * sizeof (float));
  out = g_try_malloc ((gsize) (x1 - x0) * band_rows * 4 * sizeof (float));
  if (target_is_channel)
    coverage = g_try_malloc ((gsize) (x1 - x0) * band_rows * sizeof (float));
  if (! rgba || ! out || (target_is_channel && ! coverage))
    {
      status = glims_fail (error, NULL, "Not enough memory to apply the image.");
      goto done;
    }

  for (gint band_y = y0; band_y < y1; band_y += band_rows)
    {
      gint   rows = MIN (band_rows, y1 - band_y);
      gint   count = (x1 - x0) * rows;
      gint   canvas_y = offset_y + band_y;
      gint   canvas_x = offset_x + x0;
      GeglRectangle band = { x0, band_y, x1 - x0, rows };
      gboolean band_changed = FALSE;

      /* A saved channel holds coverage (see coverage_format). It enters
       * the kernel as opaque gray and stores the luma of the result. */
      if (target_is_channel)
        {
          gegl_buffer_get (pixels, &band, 1.0, channel_format, coverage,
                           GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
          for (gint i = 0; i < count; i++)
            {
              rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = coverage[i];
              rgba[i * 4 + 3] = 1.0f;
            }
        }
      else
        gegl_buffer_get (pixels, &band, 1.0, float_format, rgba,
                         GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      /* The band is packed at the target's clipped width, the snapshots
       * at the canvas width, so the kernel runs one row at a time. */
      for (gint row = 0; row < rows; row++)
        {
          gsize packed = (gsize) row * (x1 - x0);
          gsize canvas = (gsize) (canvas_y + row) * width + canvas_x;

          glims_ai_apply (&math, rgba + packed * 4, source + canvas * 4,
                          mask_values ? mask_values + canvas : NULL,
                          selection ? selection + canvas : NULL,
                          (gsize) (x1 - x0), out + packed * 4);
        }

      for (gint row = 0; row < rows; row++)
        for (gint column = 0; column < x1 - x0; column++)
          {
            size_t i = (size_t) row * (x1 - x0) + column;
            gboolean differs = memcmp (rgba + i * 4, out + i * 4,
                                       4 * sizeof (float)) != 0;

            if (differs && target_is_channel)
              {
                float gray = glims_ai_luma (out[i * 4], out[i * 4 + 1],
                                            out[i * 4 + 2]);

                differs = gray != coverage[i];
                coverage[i] = gray;
              }
            if (differs)
              {
                include_pixel (&damage, &changed, x0 + column, band_y + row);
                band_changed = TRUE;
              }
          }

      if (band_changed && target_is_channel)
        gegl_buffer_set (candidate, &band, 0, channel_format, coverage,
                         GEGL_AUTO_ROWSTRIDE);
      else if (band_changed)
        gegl_buffer_set (candidate, &band, 0, float_format, out,
                         GEGL_AUTO_ROWSTRIDE);
    }

  if (! changed || ! native_damage (pixels, candidate, &damage))
    goto done;

  if (! gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                                     C_("undo-type", "Blend With Image")))
    {
      status = glims_fail (error, NULL, "The image history could not group Blend With Image.");
      goto done;
    }
  gimp_drawable_push_undo (target, C_("undo-type", "Blend With Image"), NULL,
                           damage.x, damage.y, damage.width, damage.height);
  gegl_buffer_copy (candidate, &damage, GEGL_ABYSS_NONE, pixels, &damage);
  gimp_drawable_update (target, damage.x, damage.y, damage.width, damage.height);
  {
    gboolean closed = gimp_image_undo_group_end (image);

    gimp_image_flush (image);
    {
      GeglRectangle image_damage = { damage.x + offset_x, damage.y + offset_y,
                                     damage.width, damage.height };
      glims_emit (engine, GLIMS_EVENT_PROJECTION_CHANGED, image, &image_damage, NULL);
    }
    if (! closed)
      {
        status = glims_fail (error, NULL,
                             "Blend With Image could not finish its Undo group; pixels changed.");
        goto done;
      }
  }
  status = GLIMS_STATUS_OK;

done:
  g_free (rgba);
  g_free (out);
  g_free (coverage);
  g_clear_object (&candidate);
  g_clear_object (&pixels);
  g_free (selection);
  g_free (mask_values);
  g_free (source);
  return status;
}

/* ---- Previews --------------------------------------------------------- */

/* The budget counts the flat buffers a preview allocates: one canvas-size
 * snapshot at a time (RGBA floats plus the plane it may be extracted from:
 * at most 24 bytes per canvas pixel) and its preview-size buffers (three
 * RGBA float buffers and a mask: 52 bytes per preview pixel). GEGL buffers
 * it reads, such as the projection or a filtered layer's effects buffer,
 * are tile-backed and live in GEGL's capped, swappable tile cache. */
static gboolean
preview_too_large (gint width, gint height, gint out_w, gint out_h)
{
  return (guint64) width * height * 24 + (guint64) out_w * out_h * 52 >
         GLIMS_MAX_PIXEL_BUFFER_BYTES;
}

static GlimsStatus
preview_size (gint width, gint height, int32_t max_side,
              gint *out_w, gint *out_h)
{
  gdouble scale;

  if (max_side < 1 || max_side > GLIMS_APPLY_IMAGE_PREVIEW_MAX)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  scale = MIN ((gdouble) max_side / width, (gdouble) max_side / height);
  scale = MIN (scale, 1.0);
  *out_w = MAX (1, (gint) RINT (width * scale));
  *out_h = MAX (1, (gint) RINT (height * scale));
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_apply_image_preview (GlimsEngine *engine, GlimsImageID id,
                                 GlimsItemID target_id,
                                 const GlimsApplyImageSettings *settings,
                                 int32_t max_side, uint8_t *rgba_out,
                                 int32_t capacity,
                                 int32_t *width_out, int32_t *height_out,
                                 char **error)
{
  GlimsOpenImage *open;
  GimpImage      *image;
  GimpDrawable   *target;
  gboolean        target_is_channel;
  GlimsAIMath     math;
  float          *source_full = NULL, *source = NULL;
  float          *mask_full = NULL, *mask_values = NULL;
  float          *target_full = NULL, *target_rgba = NULL;
  PreviewWindow   window;
  float          *result = NULL;
  gint            width, height, target_w, target_h, offset_x = 0, offset_y = 0;
  gint            out_w, out_h;
  size_t          count;
  GlimsStatus     status;

  if (! width_out || ! height_out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *width_out = 0;
  *height_out = 0;
  if (error) *error = NULL;
  status = validate_apply (settings, &math, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;
  status = admit_document (open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = resolve_target (engine, open, target_id, &target, &target_is_channel, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  gimp_item_get_offset (GIMP_ITEM (target), &offset_x, &offset_y);

  width = gimp_image_get_width (image);
  height = gimp_image_get_height (image);
  target_w = gimp_item_get_width (GIMP_ITEM (target));
  target_h = gimp_item_get_height (GIMP_ITEM (target));
  if (target_w < 1 || target_h < 1)
    return GLIMS_STATUS_FAILED;
  status = preview_size (target_w, target_h, max_side, &out_w, &out_h);
  if (status != GLIMS_STATUS_OK)
    return status;
  count = (size_t) out_w * out_h;
  window = (PreviewWindow) { offset_x, offset_y, target_w, target_h };

  *width_out = out_w;
  *height_out = out_h;
  if (! rgba_out)
    return GLIMS_STATUS_OK;   /* a size query */
  if (capacity < 0 || (size_t) capacity < count * 4)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (preview_too_large (width, height, out_w, out_h))
    return refuse (error, GLIMS_STATUS_FAILED,
                   "The Blend With Image preview exceeds the 512 MiB memory budget.");

  result = alloc_pixels (out_w, out_h);
  target_rgba = alloc_pixels (out_w, out_h);
  source = alloc_pixels (out_w, out_h);
  if (! result || ! target_rgba || ! source)
    {
      status = glims_fail (error, NULL, "Not enough memory for the preview.");
      goto done;
    }

  status = read_target_rgba_full (open, target, target_is_channel,
                                  width, height, &target_full, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  scale_box (target_full, width, height, 4, &window, out_w, out_h, target_rgba);
  g_free (target_full);
  target_full = NULL;

  status = snapshot_ref (engine, &settings->source, width, height,
                         "Blend With Image", &source_full, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  scale_box (source_full, width, height, 4, &window, out_w, out_h, source);
  g_free (source_full);
  source_full = NULL;

  if (settings->mask.channel != GLIMS_CHANNEL_NONE)
    {
      mask_values = alloc_scalars (out_w, out_h);
      if (! mask_values)
        {
          status = glims_fail (error, NULL, "Not enough memory for the preview.");
          goto done;
        }
      status = snapshot_mask (engine, &settings->mask, width, height,
                              "Blend With Image", &mask_full, error);
      if (status != GLIMS_STATUS_OK)
        goto done;
      scale_box (mask_full, width, height, 1, &window, out_w, out_h, mask_values);
      g_free (mask_full);
      mask_full = NULL;
    }

  glims_ai_apply (&math, target_rgba, source, mask_values, NULL, count, result);

  for (gsize i = 0; i < count; i++)
    {
      float r, g, b;

      if (target_is_channel)
        {
          float gray = glims_ai_luma (result[i * 4], result[i * 4 + 1],
                                      result[i * 4 + 2]);
          r = g = b = gray;
        }
      else
        {
          r = result[i * 4];
          g = result[i * 4 + 1];
          b = result[i * 4 + 2];
        }
      rgba_out[i * 4] = quantized_byte (r);
      rgba_out[i * 4 + 1] = quantized_byte (g);
      rgba_out[i * 4 + 2] = quantized_byte (b);
      rgba_out[i * 4 + 3] = target_is_channel ? 255 : quantized_byte (result[i * 4 + 3]);
    }
  status = GLIMS_STATUS_OK;

done:
  g_free (result);
  g_free (target_rgba);
  g_free (source);
  g_free (source_full);
  g_free (target_full);
  g_free (mask_values);
  g_free (mask_full);
  return status;
}

/* ---- Calculations ---------------------------------------------------- */

/* The kernel inverts only its second input (its "source"), so the first
 * input's Invert is applied to the snapshot before blending. */
static void
invert_first (const GlimsChannelRef *ref, float *rgba, size_t count)
{
  if (! ref->invert)
    return;
  for (size_t i = 0; i < count; i++)
    for (int c = 0; c < 3; c++)
      rgba[i * 4 + c] = 1.0f - rgba[i * 4 + c];
}

static gboolean
quick_mask_name (const char *name)
{
  gchar   *copy;
  gboolean matches;

  if (! name)
    return FALSE;
  copy = g_strchomp (g_strdup (name));
  matches = g_strcmp0 (copy, GIMP_IMAGE_QUICK_MASK_NAME) == 0;
  g_free (copy);
  return matches;
}

static gboolean
selection_equals (GimpImage *image, const float *result, gint width, gint height)
{
  GimpChannel *mask = gimp_image_get_mask (image);
  float       *current;
  gboolean     same = TRUE;

  /* `result` is the kernel's RGBA output; its first component is the
   * gray value the selection receives. */
  if (gimp_channel_is_empty (mask))
    {
      for (gsize i = 0; i < (gsize) width * height; i++)
        if (fabsf (result[i * 4]) > GLIMS_APPLY_HALF_STEP)
          return FALSE;
      return TRUE;
    }

  current = alloc_scalars (width, height);
  if (! current)
    return FALSE;   /* replacing the selection is always correct */
  {
    GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (mask));
    gint origin_x, origin_y;
    if (! buffer)
      {
        g_free (current);
        return FALSE;
      }
    item_origin (GIMP_ITEM (mask), &origin_x, &origin_y);
    read_scalar_full (buffer, origin_x, origin_y, width, height, current);
  }
  for (gsize i = 0; i < (gsize) width * height; i++)
    if (fabsf (result[i * 4] - current[i]) > GLIMS_APPLY_HALF_STEP)
      {
        same = FALSE;
        break;
      }
  g_free (current);
  return same;
}

static GlimsStatus
create_gray_image (GlimsEngine *engine, gint width, gint height,
                   const float *result, GlimsImageID *result_image, char **error)
{
  GimpImage   *copy;
  GimpLayer   *layer;
  const Babl  *format;
  guint        bpp;
  uint8_t     *bytes;

  copy = gimp_create_image (engine->gimp, width, height, GIMP_GRAY,
                            GIMP_PRECISION_U8_NON_LINEAR, FALSE);
  if (! copy)
    return glims_fail (error, NULL, "The new image could not be created.");
  gimp_image_undo_disable (copy);
  layer = gimp_layer_new (copy, width, height,
                          gimp_image_get_layer_format (copy, FALSE),
                          "Blend Channels", GIMP_OPACITY_OPAQUE,
                          GIMP_LAYER_MODE_NORMAL);
  if (! layer || ! gimp_image_add_layer (copy, layer, NULL, 0, FALSE))
    {
      if (layer) g_object_unref (layer);
      g_object_unref (copy);
      return glims_fail (error, NULL, "The new image's layer could not be created.");
    }
  format = gimp_drawable_get_format (GIMP_DRAWABLE (layer));
  bpp = babl_format_get_bytes_per_pixel (format);
  bytes = g_try_malloc ((gsize) width * height * bpp);
  if (! bytes || bpp != 1)
    {
      g_free (bytes);
      g_object_unref (copy);   /* owns the layer */
      return glims_fail (error, NULL, "The new image's pixels could not be prepared.");
    }
  for (gsize i = 0; i < (gsize) width * height; i++)
    bytes[i] = quantized_byte (result[i * 4]);
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, width, height), 0, format,
                   bytes, (gint) width * bpp);
  g_free (bytes);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
  gimp_image_undo_enable (copy);
  gimp_image_clean_all (copy);
  gimp_image_flush (copy);
  {
    /* Adoption keeps the caller's reference; only a failed adoption
     * releases it. */
    GlimsStatus adopted = glims_adopt_image (engine, copy, result_image);
    if (adopted != GLIMS_STATUS_OK)
      {
        g_object_unref (copy);
        return glims_fail (error, NULL, "The new image could not be opened.");
      }
  }
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_calculations (GlimsEngine *engine,
                          const GlimsCalculationsSettings *settings,
                          GlimsImageID *result_image, GlimsItemID *result_item,
                          char **error)
{
  GlimsOpenImage *first_open = NULL, *second_open = NULL, *mask_open = NULL;
  GlimsOpenImage *destination_open = NULL;
  GimpImage      *destination = NULL;
  GlimsAIMath     math;
  float          *first = NULL, *second = NULL, *mask_values = NULL, *result = NULL;
  GeglBuffer     *result_buffer = NULL;
  gint            width = 0, height = 0;
  size_t          count = 0;
  const char     *name;
  GlimsStatus     status;

  if (result_image) *result_image = 0;
  if (result_item) *result_item = 0;
  if (! result_image || ! result_item)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (error) *error = NULL;
  status = validate_calculations (settings, &math, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  first_open = glims_lookup_image (engine, settings->first.image);
  if (! first_open)
    return GLIMS_STATUS_NOT_FOUND;
  status = admit_document (first_open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  width = gimp_image_get_width (first_open->image);
  height = gimp_image_get_height (first_open->image);

  second_open = glims_lookup_image (engine, settings->second.image);
  if (! second_open)
    return GLIMS_STATUS_NOT_FOUND;
  status = admit_document (second_open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = same_size (second_open, width, height, "Blend Channels", error);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (settings->mask.channel != GLIMS_CHANNEL_NONE)
    {
      mask_open = glims_lookup_image (engine, settings->mask.image);
      if (! mask_open)
        return GLIMS_STATUS_NOT_FOUND;
      status = admit_document (mask_open, error);
      if (status != GLIMS_STATUS_OK)
        return status;
      status = same_size (mask_open, width, height, "Blend Channels", error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  if (settings->destination != GLIMS_CALCULATIONS_NEW_IMAGE)
    {
      destination_open = glims_lookup_image (engine, settings->destination_image);
      if (! destination_open)
        return GLIMS_STATUS_NOT_FOUND;
      status = admit_document (destination_open, error);
      if (status != GLIMS_STATUS_OK)
        return status;
      status = same_size (destination_open, width, height, "Blend Channels", error);
      if (status != GLIMS_STATUS_OK)
        return status;
      status = edit_gate (engine, destination_open, TRUE, error);
      if (status != GLIMS_STATUS_OK)
        return status;
      destination = destination_open->image;
      /* With Quick Mask on, the selection is the Quick Mask channel's
       * shadow; replacing it would desynchronize the two. */
      if (settings->destination == GLIMS_CALCULATIONS_NEW_SELECTION &&
          gimp_image_get_quick_mask_state (destination))
        return refuse (error, GLIMS_STATUS_BUSY,
                       "Turn off Quick Mask before making a selection.");
    }
  else
    {
      status = engine_gate (engine, error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  result = alloc_pixels (width, height);
  if (! result)
    {
      status = glims_fail (error, NULL, "Not enough memory for Blend Channels.");
      goto done;
    }

  status = snapshot_ref (engine, &settings->first, width, height,
                         "Blend Channels", &first, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  status = snapshot_ref (engine, &settings->second, width, height,
                         "Blend Channels", &second, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  status = snapshot_mask (engine, &settings->mask, width, height,
                          "Blend Channels", &mask_values, error);
  if (status != GLIMS_STATUS_OK)
    goto done;

  count = (size_t) width * height;
  invert_first (&settings->first, first, count);
  glims_ai_apply (&math, first, second, mask_values, NULL, count, result);

  /* The channel destinations write through a coverage buffer; a new image
   * builds its own from `result`. */
  if (settings->destination != GLIMS_CALCULATIONS_NEW_IMAGE)
    {
      float *values;

      result_buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, width, height),
                                       babl_format ("Y float"));
      values = result_buffer ? g_try_malloc (count * sizeof (float)) : NULL;
      if (! values)
        {
          status = glims_fail (error, NULL, "Not enough memory for the result.");
          goto done;
        }
      for (size_t i = 0; i < count; i++)
        values[i] = result[i * 4];
      gegl_buffer_set (result_buffer, GEGL_RECTANGLE (0, 0, width, height), 0,
                       babl_format ("Y float"), values, GEGL_AUTO_ROWSTRIDE);
      g_free (values);
    }

  switch (settings->destination)
    {
    case GLIMS_CALCULATIONS_NEW_CHANNEL:
      {
        GimpChannel *channel;
        GeglColor   *color = gegl_color_new ("black");
        gboolean     closed;

        name = (settings->channel_name && *settings->channel_name)
          ? settings->channel_name : "Blend Channels";
        if (quick_mask_name (name))
          {
            g_object_unref (color);
            status = refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                             "The Quick Mask's channel name is reserved.");
            goto done;
          }

        if (! gimp_image_undo_group_start (destination, GIMP_UNDO_GROUP_DRAWABLE_MOD,
                                           C_("undo-type", "Blend Channels")))
          {
            g_object_unref (color);
            status = glims_fail (error, NULL,
                                 "The image history could not group Blend Channels.");
            goto done;
          }
        channel = gimp_channel_new (destination, width, height, name, color);
        g_object_unref (color);
        if (! channel)
          {
            gimp_image_undo_group_end (destination);
            status = glims_fail (error, NULL, "The channel could not be created.");
            goto done;
          }
        gimp_item_set_visible (GIMP_ITEM (channel), FALSE, FALSE);
        if (! gimp_image_add_channel (destination, channel,
                                      GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
          {
            g_object_unref (channel);
            gimp_image_undo_group_end (destination);
            status = glims_fail (error, NULL, "The channel could not be added.");
            goto done;
          }
        forget_mask_state (GIMP_CHANNEL (channel));
        gimp_channel_select_buffer (channel, C_("undo-type", "Blend Channels"),
                                    result_buffer, 0, 0, GIMP_CHANNEL_OP_REPLACE,
                                    FALSE, 0.0, 0.0);
        /* The image owns the channel once it is added. */
        *result_item = gimp_item_get_id (GIMP_ITEM (channel));
        closed = gimp_image_undo_group_end (destination);
        gimp_image_flush (destination);
        if (! closed)
          {
            *result_item = 0;
            status = glims_fail (error, NULL,
                                 "Blend Channels could not finish its Undo group; pixels changed.");
            goto done;
          }
      }
      break;

    case GLIMS_CALCULATIONS_NEW_SELECTION:
      {
        GimpChannel *mask = gimp_image_get_mask (destination);

        if (! selection_equals (destination, result, width, height))
          {
            forget_mask_state (mask);
            gimp_channel_select_buffer (mask, C_("undo-type", "Blend Channels"),
                                        result_buffer, 0, 0, GIMP_CHANNEL_OP_REPLACE,
                                        FALSE, 0.0, 0.0);
            forget_mask_state (mask);
            gimp_image_flush (destination);
          }
      }
      break;

    case GLIMS_CALCULATIONS_NEW_IMAGE:
      status = create_gray_image (engine, width, height, result,
                                  result_image, error);
      if (status != GLIMS_STATUS_OK)
        goto done;
      break;
    }

  status = GLIMS_STATUS_OK;

done:
  g_clear_object (&result_buffer);
  g_free (result);
  g_free (mask_values);
  g_free (second);
  g_free (first);
  return status;
}

GlimsStatus
glims_image_calculations_preview (GlimsEngine *engine,
                                  const GlimsCalculationsSettings *settings,
                                  int32_t max_side, uint8_t *gray,
                                  int32_t capacity,
                                  int32_t *width_out, int32_t *height_out,
                                  char **error)
{
  GlimsOpenImage *first_open = NULL, *second_open = NULL, *mask_open = NULL;
  GlimsAIMath     math;
  float          *first = NULL, *second = NULL, *mask_values = NULL, *result = NULL;
  float          *first_full = NULL, *second_full = NULL, *mask_full = NULL;
  PreviewWindow   canvas;
  gint            width = 0, height = 0, out_w, out_h;
  size_t          count;
  GlimsStatus     status;

  if (! width_out || ! height_out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *width_out = 0;
  *height_out = 0;
  if (error) *error = NULL;
  /* The destination fields decide nothing here; only the two inputs, the
   * mask and the shared numeric rules matter. */
  if (! settings || settings->struct_size < sizeof *settings)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "The Blend Channels settings are incomplete.");
  status = validate_ref (&settings->first, FALSE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = validate_ref (&settings->second, FALSE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = validate_ref (&settings->mask, TRUE, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  if (settings->first.channel == GLIMS_CHANNEL_NONE ||
      settings->first.channel == GLIMS_CHANNEL_COMPOSITE ||
      settings->second.channel == GLIMS_CHANNEL_NONE ||
      settings->second.channel == GLIMS_CHANNEL_COMPOSITE)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Blend Channels needs two single channels.");
  math_from (settings->mode, settings->opacity, settings->scale,
             settings->offset, settings->second.invert, settings->mask.invert, &math);
  if (! glims_ai_settings_valid (&math))
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT,
                   "Blend Channels' mode, opacity, scale or offset is invalid.");

  first_open = glims_lookup_image (engine, settings->first.image);
  if (! first_open)
    return GLIMS_STATUS_NOT_FOUND;
  status = admit_document (first_open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  width = gimp_image_get_width (first_open->image);
  height = gimp_image_get_height (first_open->image);

  second_open = glims_lookup_image (engine, settings->second.image);
  if (! second_open)
    return GLIMS_STATUS_NOT_FOUND;
  status = admit_document (second_open, error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = same_size (second_open, width, height, "Blend Channels", error);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (settings->mask.channel != GLIMS_CHANNEL_NONE)
    {
      mask_open = glims_lookup_image (engine, settings->mask.image);
      if (! mask_open)
        return GLIMS_STATUS_NOT_FOUND;
      status = admit_document (mask_open, error);
      if (status != GLIMS_STATUS_OK)
        return status;
      status = same_size (mask_open, width, height, "Blend Channels", error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  status = preview_size (width, height, max_side, &out_w, &out_h);
  if (status != GLIMS_STATUS_OK)
    return status;
  count = (size_t) out_w * out_h;
  canvas = (PreviewWindow) { 0, 0, width, height };

  *width_out = out_w;
  *height_out = out_h;
  if (! gray)
    return GLIMS_STATUS_OK;   /* a size query */
  if (capacity < 0 || (size_t) capacity < count)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (preview_too_large (width, height, out_w, out_h))
    return refuse (error, GLIMS_STATUS_FAILED,
                   "The Blend Channels preview exceeds the 512 MiB memory budget.");

  result = alloc_pixels (out_w, out_h);
  first = alloc_pixels (out_w, out_h);
  second = alloc_pixels (out_w, out_h);
  if (! result || ! first || ! second)
    {
      status = glims_fail (error, NULL, "Not enough memory for the preview.");
      goto done;
    }

  status = snapshot_ref (engine, &settings->first, width, height,
                         "Blend Channels", &first_full, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  scale_box (first_full, width, height, 4, &canvas, out_w, out_h, first);
  g_free (first_full);
  first_full = NULL;

  status = snapshot_ref (engine, &settings->second, width, height,
                         "Blend Channels", &second_full, error);
  if (status != GLIMS_STATUS_OK)
    goto done;
  scale_box (second_full, width, height, 4, &canvas, out_w, out_h, second);
  g_free (second_full);
  second_full = NULL;

  if (settings->mask.channel != GLIMS_CHANNEL_NONE)
    {
      mask_values = alloc_scalars (out_w, out_h);
      if (! mask_values)
        {
          status = glims_fail (error, NULL, "Not enough memory for the preview.");
          goto done;
        }
      status = snapshot_mask (engine, &settings->mask, width, height,
                              "Blend Channels", &mask_full, error);
      if (status != GLIMS_STATUS_OK)
        goto done;
      scale_box (mask_full, width, height, 1, &canvas, out_w, out_h, mask_values);
      g_free (mask_full);
      mask_full = NULL;
    }

  invert_first (&settings->first, first, count);
  glims_ai_apply (&math, first, second, mask_values, NULL, count, result);
  for (size_t i = 0; i < count; i++)
    gray[i] = quantized_byte (result[i * 4]);
  status = GLIMS_STATUS_OK;

done:
  g_free (result);
  g_free (mask_values);
  g_free (second);
  g_free (first);
  g_free (second_full);
  g_free (first_full);
  g_free (mask_full);
  return status;
}
