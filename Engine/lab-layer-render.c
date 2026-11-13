#include "lab-layer-render.h"
#include "lab-layer-storage.h"
#include "lab-layer-composite.h"
#include "lab-transform.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include <math.h>
#include <stdint.h>
#include <string.h>

struct GlimsLabLayerRender {
  guint width, height, count;
  const Babl *format;
  GlimsLabTransform *transform;
  GeglBuffer *planes[GLIMS_LAB_LAYER_LIMIT][4];
  GlimsLabLayerCompositeLayer layers[GLIMS_LAB_LAYER_LIMIT];
  /* Fixed heap workspace, independent of canvas dimensions. All transform
   * input/output arrays are separate, including at partial chunk widths. */
  guint8 samples[GLIMS_LAB_LAYER_LIMIT][4][GLIMS_LAB_LAYER_RENDER_MAX_WIDTH];
  double composite[GLIMS_LAB_LAYER_RENDER_MAX_WIDTH * 4];
  float lab[GLIMS_LAB_LAYER_RENDER_MAX_WIDTH * 3];
  float rgba[GLIMS_LAB_LAYER_RENDER_MAX_WIDTH * 4];
};

void
glims_lab_layer_render_free (GlimsLabLayerRender *render)
{
  if (!render) return;
  /* Scan every slot so partial construction owns exactly the refs it acquired. */
  for (guint i = 0; i < GLIMS_LAB_LAYER_LIMIT; i++)
    for (guint role = 0; role < 4; role++)
      g_clear_object (&render->planes[i][role]);
  glims_lab_transform_free (render->transform);
  g_free (render);
}

static gboolean
buffer_matches (GeglBuffer *buffer, const Babl *format, guint width, guint height)
{
  if (!buffer || gegl_buffer_get_format (buffer) != format) return FALSE;
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  return extent && !extent->x && !extent->y &&
    extent->width == (gint) width && extent->height == (gint) height;
}

GlimsLabLayerRender *
glims_lab_layer_render_new (GimpImage *image)
{
  GlimsLabLayerStorage storage;
  if (glims_lab_layer_storage_read (image, &storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return NULL;
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  if (babl_format_get_n_components (format) != 1 ||
      babl_format_get_bytes_per_pixel (format) != 1)
    return NULL;
  GlimsLabLayerRender *render = g_try_new0 (GlimsLabLayerRender, 1);
  if (!render) return NULL;
  render->width = storage.map.width;
  render->height = storage.map.height;
  render->format = format;
  render->transform = glims_lab_transform_new ();
  if (!render->transform) goto failed;

  for (guint i = 0; i < storage.map.count; i++)
    {
      GlimsLabLayerNative *native = &storage.layers[i];
      gdouble opacity = gimp_layer_get_opacity (native->group);
      gboolean visible = gimp_item_get_visible (GIMP_ITEM (native->group));
      GeglBuffer *buffers[4];
      if (!isfinite (opacity) || opacity < 0 || opacity > 1) goto failed;
      /* Check actual buffers even on groups whose captured attributes let us
       * omit them. The storage reader already validated the entire tree. */
      for (guint role = 0; role < 4; role++)
        {
          buffers[role] = gimp_drawable_get_buffer (GIMP_DRAWABLE (native->planes[role]));
          if (!buffer_matches (buffers[role], format, render->width, render->height))
            goto failed;
        }
      if (!visible || opacity == 0.0) continue;
      guint index = render->count++;
      for (guint role = 0; role < 4; role++)
        render->planes[index][role] = g_object_ref (buffers[role]);
      GlimsLabLayerCompositeLayer *layer = &render->layers[index];
      layer->l = render->samples[index][0];
      layer->a = render->samples[index][1];
      layer->b = render->samples[index][2];
      layer->alpha = render->samples[index][3];
      layer->opacity = opacity;
    }
  return render;

failed:
  glims_lab_layer_render_free (render);
  return NULL;
}

static gboolean
output_is_separate (const GlimsLabLayerRender *render, const void *rgba, size_t size)
{
  const uintptr_t output = (uintptr_t) rgba, owner = (uintptr_t) render;
  if (output > UINTPTR_MAX - size || owner > UINTPTR_MAX - sizeof *render)
    return FALSE;
  return !(output < owner + sizeof *render && owner < output + size);
}

gboolean
glims_lab_layer_render_row (GlimsLabLayerRender *render, gint x, gint y,
                            guint width, void *rgba)
{
  if (!render || x < 0 || y < 0 || (guint) x > render->width ||
      (guint) y >= render->height || width > GLIMS_LAB_LAYER_RENDER_MAX_WIDTH ||
      width > render->width - (guint) x)
    return FALSE;
  if (!width) return TRUE;
  /* The chunk-width bound makes this product safe before address checks. */
  const size_t size = (size_t) width * 4 * sizeof (float);
  if (!rgba || !output_is_separate (render, rgba, size)) return FALSE;

  const GeglRectangle rect = { x, y, (gint) width, 1 };
  for (guint i = 0; i < render->count; i++)
    for (guint role = 0; role < 4; role++)
      gegl_buffer_get (render->planes[i][role], &rect, 1.0, render->format,
                       render->samples[i][role], GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  if (!glims_lab_layer_composite_row (render->count, width, render->layers,
                                      render->composite))
    return FALSE;
  for (guint i = 0; i < width; i++)
    for (guint role = 0; role < 3; role++)
      render->lab[i * 3 + role] = (float) render->composite[i * 4 + role];
  if (!glims_lab_transform_pixels (render->transform, render->lab, width, render->rgba))
    return FALSE;
  for (guint i = 0; i < width; i++)
    {
      const float alpha = (float) render->composite[i * 4 + 3];
      if (alpha == 0.0f)
        {
          /* Decide transparency after binary32 narrowing, not from double
           * coverage: a positive tiny opacity can publish float alpha0. */
          for (guint channel = 0; channel < 4; channel++)
            render->rgba[i * 4 + channel] = 0.0f;
        }
      else render->rgba[i * 4 + 3] = alpha;
    }
  memcpy (rgba, render->rgba, size);
  return TRUE;
}
