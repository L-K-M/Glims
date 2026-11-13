#include "lab-layer-preview-read.h"
#include "lab-layer-render.h"
#include <cairo.h>
#include "gegl/gimptilehandlervalidate.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define MIN_SCALE (1.0 / 1048576.0)
#define MAX_SCALE 32.0
#define MAX_SAMPLE_COORD 67108864.0

static gboolean
valid_request (GimpImage *image, GlimsLabLayerPreview **preview,
               double scale, GlimsRect area, void *rgba, size_t stride)
{
  if (!image || !preview || !rgba || !(scale >= MIN_SCALE) || scale > MAX_SCALE ||
      area.width < 1 || area.height < 1 ||
      (int64_t) area.x + area.width > G_MAXINT32 ||
      (int64_t) area.y + area.height > G_MAXINT32)
    return FALSE;
  const double sampling_scale = (double) (float) scale;
  if (fabs ((double) area.x / sampling_scale) > MAX_SAMPLE_COORD ||
      fabs ((double) area.y / sampling_scale) > MAX_SAMPLE_COORD ||
      fabs (((double) area.x + area.width) / sampling_scale) > MAX_SAMPLE_COORD ||
      fabs (((double) area.y + area.height) / sampling_scale) > MAX_SAMPLE_COORD)
    return FALSE;
  const uint64_t row_bytes = (uint64_t) area.width * 4 * sizeof (float);
  if (stride < row_bytes || stride > GLIMS_MAX_PIXEL_BUFFER_BYTES ||
      row_bytes > GLIMS_MAX_PIXEL_BUFFER_BYTES ||
      (uint64_t) (area.height - 1) >
        (GLIMS_MAX_PIXEL_BUFFER_BYTES - row_bytes) / stride)
    return FALSE;
  const uint64_t span = (uint64_t) (area.height - 1) * stride + row_bytes;
  return (uintptr_t) rgba <= UINTPTR_MAX - span;
}

static void
validate_sampling_area (GeglBuffer *buffer, double scale, GlimsRect area)
{
  GimpTileHandlerValidate *validate = gimp_tile_handler_validate_get_assigned (buffer);
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  if (!validate) return;
  double factor = 1.0, level_scale = scale;
  while (level_scale <= 0.5)
    {
      factor *= 2.0;
      level_scale *= 2.0;
    }
  /* GEGL buffer-access chooses mip levels, rounds source bounds outward and
   * samples a neighboring box/bilinear footprint. Include complete mip blocks
   * and a conservative halo. At our 2^26 source-coordinate bound, 32 pixels
   * also covers binary32 coordinate/division rounding. Clip BEFORE narrowing.
   * This is required even when a previously generated mip tile is cached. */
  const double sampling_scale = (double) (float) scale;
  const double padding = scale == 1.0 ? 0.0 : 4.0 * factor + 32.0;
  const double left = MAX (floor (area.x / sampling_scale / factor) * factor - padding,
                           (double) extent->x);
  const double top = MAX (floor (area.y / sampling_scale / factor) * factor - padding,
                          (double) extent->y);
  const double right = MIN (ceil (((double) area.x + area.width) / sampling_scale / factor) * factor + padding,
                            (double) extent->x + extent->width);
  const double bottom = MIN (ceil (((double) area.y + area.height) / sampling_scale / factor) * factor + padding,
                             (double) extent->y + extent->height);
  if (!(right > left && bottom > top)) return;
  const GeglRectangle full = { (gint) left, (gint) top,
                               (gint) (right - left), (gint) (bottom - top) };
  gimp_tile_handler_validate_validate (validate, buffer, &full, TRUE, FALSE);
}

static gboolean
unassociate (float *rgba, guint width)
{
  for (guint x = 0; x < width; x++)
    {
      float *pixel = rgba + x * 4;
      const double alpha = pixel[3];
      if (!isfinite (alpha) || alpha < 0.0 || alpha > 1.0) return FALSE;
      if (alpha == 0.0)
        {
          for (guint c = 0; c < 4; c++) pixel[c] = 0.0f;
          continue;
        }
      for (guint c = 0; c < 3; c++)
        {
          /* A float reciprocal can overflow for a positive subnormal alpha.
           * Babl's conversion instead floors alpha, which changes this policy. */
          const double value = (double) pixel[c] / alpha;
          if (!isfinite (value) || fabs (value) > FLT_MAX) return FALSE;
          pixel[c] = (float) value;
        }
    }
  return TRUE;
}

GlimsStatus
glims_lab_layer_preview_read (GimpImage *image, GlimsLabLayerPreview **preview,
                              double scale, GlimsRect area, void *rgba, size_t stride)
{
  if (!valid_request (image, preview, scale, area, rgba, stride))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GeglBuffer *buffer = NULL;
  GlimsStatus status = glims_lab_layer_preview_prepare (image, preview, &buffer);
  if (status != GLIMS_STATUS_OK) return status;
  const Babl *format = babl_format ("RaGaBaA float");
  if (!buffer || gegl_buffer_get_format (buffer) != format)
    return GLIMS_STATUS_FAILED;
  if (scale < 2.0 && scale != 1.0)
    return glims_lab_layer_preview_sample (*preview, scale, area, rgba, stride);
  if (scale != 1.0 || area.width == 1)
    validate_sampling_area (buffer, scale, area);
  if (!glims_lab_layer_preview_succeeded (*preview)) return GLIMS_STATUS_FAILED;

  float chunk[GLIMS_LAB_LAYER_RENDER_MAX_WIDTH * 4];
  for (gint y = 0; y < area.height; y++)
    for (gint x = 0; x < area.width; )
      {
        guint width = MIN (GLIMS_LAB_LAYER_RENDER_MAX_WIDTH, (guint) (area.width - x));
        /* Avoid the GEGL 1x1 hot-tile shortcut on a final chunk. A wholly
         * one-column request was explicitly validated above. */
        if (area.width - x == GLIMS_LAB_LAYER_RENDER_MAX_WIDTH + 1) width--;
        const GeglRectangle rect = { area.x + x, area.y + y, (gint) width, 1 };
        gegl_buffer_get (buffer, &rect, scale, format, chunk,
                         GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        if (!glims_lab_layer_preview_succeeded (*preview) || !unassociate (chunk, width))
          return GLIMS_STATUS_FAILED;
        memcpy ((guint8 *) rgba + (size_t) y * stride + (size_t) x * 4 * sizeof (float),
                 chunk, width * 4 * sizeof (float));
        x += (gint) width;
      }
  return GLIMS_STATUS_OK;
}
