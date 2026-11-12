#include "lab-brush-coverage.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define GLIMS_LAB_BRUSH_COVERAGE_MAX_COUNT 4096u

_Static_assert(sizeof(float) == sizeof(uint32_t) && FLT_RADIX == 2 &&
               FLT_MANT_DIG == 24 && FLT_MAX_EXP == 128,
               "Lab coverage requires native IEEE binary32 float");

static bool
checked_end(const void *pointer, size_t bytes, uintptr_t *end)
{
  uintptr_t start = (uintptr_t)pointer;

  if (bytes > (size_t)(UINTPTR_MAX - start))
    return false;
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
glims_lab_brush_coverage(size_t count, const void *previous,
                         const void *generated_mask, void *destination)
{
  float staging[GLIMS_LAB_BRUSH_COVERAGE_MAX_COUNT];
  uintptr_t previous_end, generated_end, destination_end;
  size_t bytes;

  if (count == 0)
    return true;
  if (count > GLIMS_LAB_BRUSH_COVERAGE_MAX_COUNT)
    return false;
  if (!previous || !generated_mask || !destination)
    return false;

  bytes = count * sizeof(float);
  if (!checked_end(previous, bytes, &previous_end) ||
      !checked_end(generated_mask, bytes, &generated_end) ||
      !checked_end(destination, bytes, &destination_end))
    return false;
  if (ranges_overlap((uintptr_t)destination, destination_end,
                     (uintptr_t)previous, previous_end) ||
      ranges_overlap((uintptr_t)destination, destination_end,
                     (uintptr_t)generated_mask, generated_end))
    return false;

  for (size_t i = 0; i < count; i++) {
    float previous_value, generated_value, clamped_mask, output_value;
    double result;

    memcpy(&previous_value, (const unsigned char *)previous + i * sizeof(float),
           sizeof(previous_value));
    memcpy(&generated_value,
           (const unsigned char *)generated_mask + i * sizeof(float),
           sizeof(generated_value));

    if (!isfinite(previous_value) || previous_value < 0.0f || previous_value > 1.0f)
      return false;
    if (!isfinite(generated_value))
      return false;

    if (generated_value <= 0.0f)
      clamped_mask = 0.0f;
    else if (generated_value >= 1.0f)
      clamped_mask = 1.0f;
    else
      clamped_mask = generated_value;

    if (clamped_mask == 0.0f) {
      memcpy(&staging[i], (const unsigned char *)previous + i * sizeof(float),
             sizeof(float)); /* Preserve the original bytes, including -0. */
      continue;
    }

    result = fma(1.0 - (double)previous_value, (double)clamped_mask,
                 (double)previous_value);
    if (!isfinite(result))
      return false;
    output_value = (float)result;
    if (!isfinite(output_value))
      return false;

    /* Arithmetic-only clamp for floating-point roundoff. */
    if (output_value < 0.0f)
      output_value = 0.0f;
    else if (output_value > 1.0f)
      output_value = 1.0f;

    staging[i] = output_value;
  }

  memcpy(destination, staging, bytes);
  return true;
}
