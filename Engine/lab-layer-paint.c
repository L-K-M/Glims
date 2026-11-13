#include "lab-layer-paint.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct { uintptr_t start, end; } Range;

static bool
range_of(const void *pointer, size_t size, Range *range)
{
  uintptr_t start = (uintptr_t)pointer;
  if ((size && !pointer) || size > UINTPTR_MAX - start) return false;
  range->start = start;
  range->end = start + size;
  return true;
}

static bool
overlap(Range a, Range b)
{
  return a.start < b.end && b.start < a.end;
}

/* Round the exact encoded-alpha expression for this binary64 source alpha.
 * A rounded intermediate plus 0.5 can cross a half-code boundary. FMA
 * compares against that boundary without the intermediate rounding. */
static unsigned
quantize_alpha(uint8_t old, double source_alpha)
{
  double span = 255.0 - old;
  double scaled = fma(source_alpha, span, old);
  unsigned result = (unsigned)floor(scaled + 0.5);
  if (result > 255) result = 255;
  if (result > 0 && fma(source_alpha, span, (double)old - result + 0.5) < 0) result--;
  if (result < 255 && fma(source_alpha, span, (double)old - result - 0.5) >= 0) result++;
  return result;
}

static uint8_t
quantize_color(uint8_t old, double target, double fraction)
{
  double delta = target - old;
  double scaled = fma(fraction, delta, old);
  unsigned result = (unsigned)floor(scaled + 0.5);
  if (result > 255) result = 255;
  if (result > 0 && fma(fraction, delta, (double)old - result + 0.5) < 0) result--;
  if (result < 255 && fma(fraction, delta, (double)old - result - 0.5) >= 0) result++;
  return (uint8_t)result;
}

bool
glims_lab_layer_paint_row(size_t width, const uint8_t *const source[4],
                          const void *coverage, double lightness,
                          double a, double b, double opacity,
                          uint8_t *const destination[4], bool *changed)
{
  Range change_range, source_descriptors, destination_descriptors;
  Range inputs[4], outputs[4], mask_range = {0, 0};
  if (!changed || !range_of(changed, sizeof *changed, &change_range) ||
      width > GLIMS_LAB_LAYER_PAINT_MAX_WIDTH ||
      !range_of(source, 4 * sizeof *source, &source_descriptors) ||
      !range_of(destination, 4 * sizeof *destination, &destination_descriptors) ||
      overlap(change_range, source_descriptors) || overlap(change_range, destination_descriptors))
    return false;
  if (!isfinite(lightness) || lightness < 0 || lightness > 100 ||
      !isfinite(a) || a < -128 || a > 127 || !isfinite(b) || b < -128 || b > 127 ||
      !isfinite(opacity) || opacity < 0 || opacity > 1)
    return false;
  if (coverage && !range_of(coverage, width * sizeof(float), &mask_range)) return false;
  if (overlap(change_range, mask_range)) return false;
  for (unsigned i = 0; i < 4; i++) {
    if (!range_of(source[i], width, &inputs[i]) || !range_of(destination[i], width, &outputs[i]) ||
        overlap(change_range, inputs[i]) || overlap(change_range, outputs[i]) ||
        overlap(outputs[i], source_descriptors) || overlap(outputs[i], destination_descriptors) ||
        overlap(outputs[i], mask_range)) return false;
  }
  for (unsigned i = 0; i < 4; i++)
    for (unsigned j = 0; j < 4; j++) {
      if (i != j && overlap(outputs[i], outputs[j])) return false;
      if (overlap(outputs[i], inputs[j]) && !(i == j && source[j] == destination[i])) return false;
    }
  *changed = false;
  uint8_t staged[4][GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  const double color[3] = { lightness * 255.0 / 100.0, a + 128.0, b + 128.0 };
  bool any = false;
  for (size_t x = 0; x < width; x++) {
    float mask = 1;
    if (coverage) memcpy(&mask, (const unsigned char *)coverage + x * sizeof mask, sizeof mask);
    if (!isfinite(mask) || mask < 0 || mask > 1) return false;
    double source_alpha = opacity * (double)mask;
    double old_alpha = (double)source[3][x] / 255.0;
    double output_alpha = source_alpha + old_alpha * (1.0 - source_alpha);
    unsigned quantized_alpha = quantize_alpha(source[3][x], source_alpha);
    if (source_alpha == 0 || (source[3][x] == 0 && quantized_alpha == 0)) {
      for (unsigned role = 0; role < 4; role++) staged[role][x] = source[role][x];
      continue;
    }
    double fraction = source_alpha / output_alpha;
    for (unsigned role = 0; role < 3; role++)
      staged[role][x] = quantize_color(source[role][x], color[role], fraction);
    staged[3][x] = (uint8_t)quantized_alpha;
  }
  for (unsigned role = 0; role < 4; role++)
    if (width && memcmp(source[role], staged[role], width)) any = true;
  for (unsigned role = 0; role < 4; role++)
    if (width) memcpy(destination[role], staged[role], width);
  *changed = any;
  return true;
}
