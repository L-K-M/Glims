#include "lab-layer-composite.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

static bool
checked_end(const void *pointer, size_t bytes, uintptr_t *end)
{
  uintptr_t start = (uintptr_t)pointer;
  if (bytes > 0 && pointer == NULL) return false;
  if (bytes > UINTPTR_MAX - start) return false;
  *end = start + bytes;
  return true;
}

static bool
ranges_overlap(uintptr_t a_start, uintptr_t a_end, uintptr_t b_start,
               uintptr_t b_end)
{
  return a_start < b_end && b_start < a_end;
}

bool
glims_lab_layer_composite_row(size_t layer_count, size_t width,
                              const GlimsLabLayerCompositeLayer *layers,
                              void *destination)
{
  if (layer_count > GLIMS_LAB_LAYER_COMPOSITE_MAX_LAYERS ||
      width > GLIMS_LAB_LAYER_COMPOSITE_MAX_WIDTH)
    return false;

  size_t output_doubles = 0;
  size_t output_bytes = 0;
  uintptr_t destination_start = 0;
  uintptr_t destination_end = 0;
  if (width > 0) {
    if (width > SIZE_MAX / 4u) return false;
    output_doubles = width * 4u;
    if (output_doubles > SIZE_MAX / sizeof(double)) return false;
    output_bytes = output_doubles * sizeof(double);
    if (!checked_end(destination, output_bytes, &destination_end))
      return false;
    destination_start = (uintptr_t)destination;
  }

  uintptr_t layers_start = 0;
  uintptr_t layers_end = 0;
  if (layer_count > 0) {
    if (layer_count > SIZE_MAX / sizeof(*layers)) return false;
    if (!checked_end(layers, layer_count * sizeof(*layers), &layers_end))
      return false;
    layers_start = (uintptr_t)layers;
    if (width > 0 && ranges_overlap(destination_start, destination_end,
                                    layers_start, layers_end))
      return false;
  }

  if (width == 0) {
    for (size_t i = 0; i < layer_count; i++) {
      double opacity = layers[i].opacity;
      if (!isfinite(opacity) || opacity < 0.0 || opacity > 1.0) return false;
    }
    return true;
  }

  for (size_t i = 0; i < layer_count; i++) {
    const GlimsLabLayerCompositeLayer *layer = &layers[i];
    if (!isfinite(layer->opacity) || layer->opacity < 0.0 || layer->opacity > 1.0)
      return false;

    uintptr_t plane_end;
    const void *planes[4] = {layer->l, layer->a, layer->b, layer->alpha};
    for (unsigned p = 0; p < 4; p++) {
      if (!checked_end(planes[p], width, &plane_end)) return false;
      if (ranges_overlap(destination_start, destination_end,
                         (uintptr_t)planes[p], plane_end))
        return false;
    }
  }

  double staging[GLIMS_LAB_LAYER_COMPOSITE_MAX_WIDTH][4];
  for (size_t x = 0; x < width; x++) {
    double accum_l = 0.0;
    double accum_a = 0.0;
    double accum_b = 0.0;
    double accum_alpha = 0.0;

    for (size_t i = 0; i < layer_count && accum_alpha < 1.0; i++) {
      const GlimsLabLayerCompositeLayer *layer = &layers[i];
      double source_alpha = ((double)layer->alpha[x] / 255.0) * layer->opacity;
      if (!(source_alpha > 0.0)) continue;
      double weight = source_alpha * (1.0 - accum_alpha);
      if (!(weight > 0.0)) continue;

      double l = 100.0 * (double)layer->l[x] / 255.0;
      double a = (double)layer->a[x] - 128.0;
      double b = (double)layer->b[x] - 128.0;
      double next_alpha = accum_alpha + weight;
      if (accum_alpha == 0.0) {
        accum_l = l;
        accum_a = a;
        accum_b = b;
      } else {
        /* Keep the normalized weighted mean rather than multiplying color
         * by a possibly subnormal weight before dividing it away. */
        double fraction = weight / next_alpha;
        accum_l = fma(fraction, l - accum_l, accum_l);
        accum_a = fma(fraction, a - accum_a, accum_a);
        accum_b = fma(fraction, b - accum_b, accum_b);
      }
      accum_alpha = next_alpha;
    }

    if (!(accum_alpha > 0.0)) {
      staging[x][0] = +0.0;
      staging[x][1] = +0.0;
      staging[x][2] = +0.0;
      staging[x][3] = +0.0;
      continue;
    }

    double out_alpha = accum_alpha;
    if (out_alpha > 1.0) out_alpha = 1.0;
    staging[x][0] = accum_l;
    staging[x][1] = accum_a;
    staging[x][2] = accum_b;
    staging[x][3] = out_alpha;
  }

  memcpy(destination, staging, output_bytes);
  return true;
}
