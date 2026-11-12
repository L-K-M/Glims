#include "lab-fill.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

/* Test an address range against the small changed object without constructing
 * an overflowing end address. count/width are bounded by the caller below. */
static bool
aliases_changed(const void *pointer, size_t bytes, uintptr_t changed_start,
                uintptr_t changed_end)
{
  if (!pointer || !bytes) return false;
  uintptr_t start = (uintptr_t)pointer;
  if (start >= changed_start) return start < changed_end;
  return changed_start - start < bytes;
}

static bool
checked_end(const void *pointer, size_t bytes, uintptr_t *end)
{
  uintptr_t start = (uintptr_t)pointer;
  if (bytes > UINTPTR_MAX - start) return false;
  *end = start + bytes;
  return true;
}

static bool
overlaps(const void *a, uintptr_t a_end, const void *b, uintptr_t b_end)
{
  return (uintptr_t)a < b_end && (uintptr_t)b < a_end;
}

bool
glims_lab_fill_row(GlimsLabRole role, GlimsLabFormat format,
                   double physical_value, double opacity, size_t count,
                   const void *source, const float *mask, void *destination,
                   bool *changed)
{
  if (!changed) return false;
  uintptr_t changed_start = (uintptr_t)changed, changed_end;
  if (!checked_end(changed, sizeof *changed, &changed_end)) return false;

  size_t width = glims_lab_sample_size(format);
  /* A bad format/count has no accepted sample range. Exact pointer aliases
   * are nevertheless refused without touching their protected first byte. */
  if (count && (source == (const void *)changed || destination == (void *)changed ||
                (const void *)mask == (const void *)changed)) return false;
  if (width && count <= GLIMS_LAB_FILL_MAX_COUNT) {
    if (aliases_changed(source, count * width, changed_start, changed_end) ||
        aliases_changed(destination, count * width, changed_start, changed_end) ||
        aliases_changed(mask, count * sizeof(float), changed_start, changed_end))
      return false;
  }
  *changed = false;
  if (!width || count > GLIMS_LAB_FILL_MAX_COUNT ||
      (role != GLIMS_LAB_ROLE_L && role != GLIMS_LAB_ROLE_A && role != GLIMS_LAB_ROLE_B) ||
      !isfinite(physical_value) || !isfinite(opacity) || opacity < 0 || opacity > 1)
    return false;
  if (format == GLIMS_LAB_FORMAT_FLOAT) {
    if (fabs(physical_value) > FLT_MAX) return false;
  } else if (role == GLIMS_LAB_ROLE_L) {
    if (physical_value < 0 || physical_value > 100) return false;
  } else if (physical_value < -128 || physical_value > 127) return false;
  if (!count) return true;
  if (!source || !destination) return false;

  size_t bytes = count * width;
  uintptr_t source_end, destination_end, mask_end = 0;
  if (!checked_end(source, bytes, &source_end) ||
      !checked_end(destination, bytes, &destination_end) ||
      (mask && !checked_end(mask, count * sizeof(float), &mask_end))) return false;
  if (source != destination && overlaps(source, source_end, destination, destination_end))
    return false;
  if (mask && (overlaps(source, source_end, mask, mask_end) ||
               overlaps(destination, destination_end, mask, mask_end))) return false;

  unsigned char staging[GLIMS_LAB_FILL_MAX_COUNT * sizeof(float)];
  const unsigned char *input = source;
  const unsigned char *mask_bytes = (const unsigned char *)mask;
  for (size_t i = 0; i < count; i++) {
    float coverage = 1;
    if (mask) memcpy(&coverage, mask_bytes + i * sizeof coverage, sizeof coverage);
    if (!isfinite(coverage) || coverage < 0 || coverage > 1) return false;
    double weight = opacity * (double)coverage;
    if (weight == 0) {
      memcpy(staging + i * width, input + i * width, width);
      continue;
    }
    double original;
    if (!glims_lab_decode_row(role, format, 1, input + i * width, &original)) return false;
    double result = weight == 1 ? physical_value :
                    fma(weight, physical_value, (1 - weight) * original);
    if (!isfinite(result)) return false;
    /* Rounded weighted terms can land one binary64 ulp outside the exact
     * convex interval, including just above FLT_MAX for identical endpoints.
     * Repair only that arithmetic drift, never a Lab gamut or nominal range. */
    if (weight != 1) {
      double low = fmin(original, physical_value), high = fmax(original, physical_value);
      if (result < low) result = low;
      if (result > high) result = high;
    }
    if (!glims_lab_encode_row(role, format, 1, &result, staging + i * width)) return false;
  }
  bool any_changed = memcmp(source, staging, bytes) != 0;
  memcpy(destination, staging, bytes);
  *changed = any_changed;
  return true;
}
