/*
 * Select > Color Range. Runs on the engine thread.
 *
 * Both slots read the merged visible image through the same projection
 * helper glims_image_sample_color uses, in straight nonlinear sRGB, so a
 * sampled color and the evaluated weights agree. The pure kernel in
 * color-range-math.h owns the ramp, hue sectors, luma bands, transparency,
 * Invert and the selection limit; this file only prepares buffers and
 * applies the result.
 *
 * Apply replaces the root selection mask through gimp_channel_select_buffer,
 * which pushes one undo step named "Color Range". The cached-mask workaround
 * select.c needs after every combine runs afterwards too.
 */
#include "engine-private.h"
#include "color-range-math.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpchannel-select.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimppickable.h"
#include "core/gimpprojection.h"

#include "libgimpmath/gimpmath.h"

#include "gimp-intl.h"

#define GLIMS_COLOR_RANGE_PREVIEW_MAX 512

/* Drops the mask's cached bounds and "full" flag, as select.c does after
 * combining a new shape (app/core/gimpchannel-combine.c). */
static void
forget_mask_state (GimpChannel *mask)
{
  gimp_drawable_invalidate_boundary (GIMP_DRAWABLE (mask));
}

static GlimsStatus
invalid_settings (char **error, const char *reason)
{
  glims_fail (error, NULL, reason);
  return GLIMS_STATUS_INVALID_ARGUMENT;
}

/* Every rule the facade promises. Samples are validated before any copy. */
static GlimsStatus
validate_settings (const GlimsColorRangeSettings *settings, char **error)
{
  if (! settings || settings->struct_size < sizeof *settings)
    return invalid_settings (error, "The color range settings are incomplete.");

  if (settings->mode < GLIMS_COLOR_RANGE_SAMPLED ||
      settings->mode > GLIMS_COLOR_RANGE_SHADOWS)
    return invalid_settings (error, "Choose sampled colors or a fixed color range.");

  if (! isfinite (settings->fuzziness) ||
      settings->fuzziness < 0.0 || settings->fuzziness > 200.0)
    return invalid_settings (error, "Fuzziness must be a whole number from 0 to 200.");

  if (settings->invert > 1)
    return invalid_settings (error, "Invert must be on or off.");

  if (settings->sample_count > GLIMS_COLOR_RANGE_MAX_SAMPLES)
    return invalid_settings (error, "Color Range takes at most 64 samples.");

  if (settings->sample_count && ! settings->samples)
    return invalid_settings (error, "The color range has no sample list.");

  gboolean has_add = FALSE;

  for (uint32_t i = 0; i < settings->sample_count; i++)
    {
      const GlimsColorRangeSample *sample = &settings->samples[i];

      if (! isfinite (sample->red) || ! isfinite (sample->green) ||
          ! isfinite (sample->blue) || sample->subtract > 1)
        return invalid_settings (error, "A sampled color is not a finite color.");
      has_add |= ! sample->subtract;
    }

  if (settings->mode == GLIMS_COLOR_RANGE_SAMPLED)
    {
      if (settings->sample_count == 0)
        return invalid_settings (error, "Sample at least one color first.");
      if (! has_add)
        return invalid_settings (error, "Sample at least one color to add first.");
    }
  else if (settings->sample_count != 0)
    {
      return invalid_settings (error, "A fixed color range takes no samples.");
    }

  return GLIMS_STATUS_OK;
}

/* Copies the borrowed facade samples into kernel-owned storage. */
static void
kernel_from (const GlimsColorRangeSettings *settings,
             GlimsCRSample *samples, GlimsCRSettings *kernel)
{
  kernel->mode = settings->mode;
  kernel->fuzziness = settings->fuzziness;
  kernel->invert = settings->invert;
  kernel->sample_count = settings->sample_count;
  kernel->samples = settings->sample_count ? samples : NULL;

  for (uint32_t i = 0; i < settings->sample_count; i++)
    samples[i] = (GlimsCRSample) {
      settings->samples[i].red,
      settings->samples[i].green,
      settings->samples[i].blue,
      settings->samples[i].subtract
    };
}

static GlimsStatus
refuse_indexed (GimpImage *image, char **error)
{
  if (gimp_image_get_base_type (image) != GIMP_INDEXED)
    return GLIMS_STATUS_OK;
  glims_fail (error, NULL, "Color Range is unavailable for indexed images.");
  return GLIMS_STATUS_UNSUPPORTED;
}

/* Reads the current selection mask into `values_out`, or leaves it NULL
 * when the image has no selection. The returned buffer is unref'd by the
 * caller; the values are freed by the caller. */
static GlimsStatus
read_selection (GimpImage *image, gint width, gint height, double scale,
                float **values_out, GeglBuffer **buffer_out)
{
  GimpChannel *mask = gimp_image_get_mask (image);
  float       *values;
  GeglBuffer  *buffer;

  *values_out = NULL;
  *buffer_out = NULL;
  if (gimp_channel_is_empty (mask))
    return GLIMS_STATUS_OK;

  values = g_try_malloc ((size_t) width * (size_t) height * sizeof (float));
  if (! values)
    return GLIMS_STATUS_FAILED;

  buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (mask));
  if (! buffer)
    {
      g_free (values);
      return GLIMS_STATUS_FAILED;
    }

  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, width, height), scale,
                   babl_format ("Y float"), values, GEGL_AUTO_ROWSTRIDE,
                   GEGL_ABYSS_NONE);
  *values_out = values;
  /* gimp_drawable_get_buffer lends the mask's buffer; the caller unrefs. */
  *buffer_out = g_object_ref (buffer);
  return GLIMS_STATUS_OK;
}

/* Pixels per band of the apply pass: bounds the float copies to about
 * 24 MiB whatever the image size (RGBA, selection and weight floats). */
#define GLIMS_COLOR_RANGE_BAND_PIXELS (1 << 20)

GlimsStatus
glims_selection_color_range (GlimsEngine                 *engine,
                             GlimsImageID                 id,
                             const GlimsColorRangeSettings *settings,
                             char                       **error)
{
  GlimsOpenImage     *open;
  GimpImage          *image;
  GimpChannel        *mask;
  GeglBuffer         *projection = NULL;   /* borrowed, not owned */
  GeglBuffer         *selection_buffer = NULL;
  GeglBuffer         *weight_buffer = NULL;
  GlimsCRSample       samples[GLIMS_COLOR_RANGE_MAX_SAMPLES];
  GlimsCRSettings     kernel;
  float              *rgba = NULL, *selection = NULL, *weights = NULL;
  float               maximum = 0.0f;
  gint                width, height, band_rows;
  size_t              band_pixels;
  GlimsStatus         status;

  if (error) *error = NULL;
  status = validate_settings (settings, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;

  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;
  status = refuse_indexed (image, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  width = gimp_image_get_width (image);
  height = gimp_image_get_height (image);
  band_rows = MAX (1, MIN (height, GLIMS_COLOR_RANGE_BAND_PIXELS / MAX (width, 1)));
  band_pixels = (size_t) width * (size_t) band_rows;

  kernel_from (settings, samples, &kernel);
  mask = gimp_image_get_mask (image);

  rgba = g_try_malloc (band_pixels * 4 * sizeof (float));
  weights = g_try_malloc (band_pixels * sizeof (float));
  if (! gimp_channel_is_empty (mask))
    {
      GeglBuffer *mask_buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (mask));

      if (! mask_buffer)
        {
          status = glims_fail (error, NULL, "The selection could not be read.");
          goto out;
        }
      selection = g_try_malloc (band_pixels * sizeof (float));
      selection_buffer = g_object_ref (mask_buffer);   /* lent by the mask */
    }
  weight_buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, width, height),
                                   babl_format ("Y float"));
  if (! rgba || ! weights || ! weight_buffer ||
      (selection_buffer && ! selection))
    {
      status = glims_fail (error, NULL, "Not enough memory to evaluate the color range.");
      goto out;
    }

  status = glims_projection_prepare_read (open, 1.0,
                                          (GlimsRect) { 0, 0, width, height },
                                          &projection);
  if (status != GLIMS_STATUS_OK)
    goto out;

  /* Same straight nonlinear sRGB conversion glims_image_sample_color asks
   * for, so the dialog's samples and these pixels agree. */
  for (gint y = 0; y < height; y += band_rows)
    {
      gint          rows = MIN (band_rows, height - y);
      size_t        count = (size_t) width * (size_t) rows;
      GeglRectangle band = { 0, y, width, rows };

      gegl_buffer_get (projection, &band, 1.0, babl_format ("R'G'B'A float"),
                       rgba, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      if (selection_buffer)
        gegl_buffer_get (selection_buffer, &band, 1.0, babl_format ("Y float"),
                         selection, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);

      glims_cr_apply (&kernel, rgba, count, selection_buffer ? selection : NULL, weights);
      for (size_t i = 0; i < count; i++)
        maximum = fmaxf (maximum, weights[i]);

      gegl_buffer_set (weight_buffer, &band, 0, babl_format ("Y float"),
                       weights, GEGL_AUTO_ROWSTRIDE);
    }
  projection = NULL;   /* borrowed from the projection; never unref */

  if (maximum < 0.5f / 255.0f)
    {
      status = glims_fail (error, NULL, "No pixels match the color range.");
      goto out;
    }

  forget_mask_state (mask);
  gimp_channel_select_buffer (mask, C_("undo-type", "Color Range"),
                              weight_buffer, 0, 0, GIMP_CHANNEL_OP_REPLACE,
                              FALSE, 0.0, 0.0);
  forget_mask_state (mask);
  gimp_image_flush (image);
  status = GLIMS_STATUS_OK;

out:
  g_clear_object (&selection_buffer);
  g_clear_object (&weight_buffer);
  g_free (rgba);
  g_free (selection);
  g_free (weights);
  return status;
}

GlimsStatus
glims_color_range_preview (GlimsEngine                 *engine,
                           GlimsImageID                 id,
                           const GlimsColorRangeSettings *settings,
                           int32_t                      max_size,
                           uint8_t                     *mask,
                           size_t                       byte_count,
                           int32_t                     *width_out,
                           int32_t                     *height_out,
                           char                       **error)
{
  GlimsOpenImage     *open;
  GimpImage          *image;
  GeglBuffer         *projection = NULL;   /* borrowed, not owned */
  GeglBuffer         *selection_buffer = NULL;
  GlimsCRSample       samples[GLIMS_COLOR_RANGE_MAX_SAMPLES];
  GlimsCRSettings     kernel;
  float              *rgba = NULL, *selection = NULL, *weights = NULL;
  gint                width, height, out_width, out_height;
  gdouble             scale;
  size_t              count;
  GlimsStatus         status;

  if (! width_out || ! height_out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *width_out = 0;
  *height_out = 0;
  if (error) *error = NULL;
  if (max_size < 1 || max_size > GLIMS_COLOR_RANGE_PREVIEW_MAX)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = validate_settings (settings, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  image = open->image;
  status = refuse_indexed (image, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  width = gimp_image_get_width (image);
  height = gimp_image_get_height (image);
  scale = MIN ((gdouble) max_size / width, (gdouble) max_size / height);
  scale = MIN (scale, 1.0);
  out_width = MAX (1, (gint) RINT (width * scale));
  out_height = MAX (1, (gint) RINT (height * scale));
  count = (size_t) out_width * (size_t) out_height;

  *width_out = out_width;
  *height_out = out_height;
  if (! mask)
    return GLIMS_STATUS_OK;   /* a size query */
  if (byte_count < count)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  kernel_from (settings, samples, &kernel);

  rgba = g_try_malloc (count * 4 * sizeof (float));
  weights = g_try_malloc (count * sizeof (float));
  if (! rgba || ! weights)
    {
      status = glims_fail (error, NULL, "Not enough memory to preview the color range.");
      goto out;
    }

  status = glims_projection_prepare_read (open, scale,
                                          (GlimsRect) { 0, 0, out_width, out_height },
                                          &projection);
  if (status != GLIMS_STATUS_OK)
    goto out;

  gegl_buffer_get (projection, GEGL_RECTANGLE (0, 0, out_width, out_height),
                   scale, babl_format ("R'G'B'A float"), rgba,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  projection = NULL;   /* borrowed from the projection; never unref */

  status = read_selection (image, out_width, out_height, scale,
                            &selection, &selection_buffer);
  if (status != GLIMS_STATUS_OK)
    {
      status = glims_fail (error, NULL, "The selection could not be read.");
      goto out;
    }

  glims_cr_apply (&kernel, rgba, count, selection, weights);

  for (size_t i = 0; i < count; i++)
    {
      float value = weights[i] * 255.0f + 0.5f;

      mask[i] = (uint8_t) CLAMP (value, 0.0f, 255.0f);
    }
  status = GLIMS_STATUS_OK;

out:
  g_clear_object (&selection_buffer);
  g_free (rgba);
  g_free (selection);
  g_free (weights);
  return status;
}
