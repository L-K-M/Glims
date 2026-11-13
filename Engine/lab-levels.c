#include "lab-levels.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

/* Compensated products require separately rounded intermediates. */
#pragma STDC FP_CONTRACT OFF

static bool
unit_value (double value)
{
  return isfinite (value) && value >= 0 && value <= 1;
}

static double
bounded (double value, double low, double high)
{
  return value < low ? low : value > high ? high : value;
}

/* Match the cancellation-preserving arithmetic of component-levels.c. */
static double
product_sum (double a, double b, double c, double d)
{
  double first = a * b, second = c * d;
  double first_error = fma (a, b, -first);
  double second_error = fma (c, d, -second);
  double sum = first + second;
  double second_part = sum - first;
  double sum_error = (first - (sum - second_part)) + (second - second_part);
  return sum + (sum_error + first_error + second_error);
}

static bool
affine_coefficients (const GlimsLabLevels *s, double offset, double scale,
                     double coverage, double *coefficient, double *constant)
{
  double denominator = s->high_input != s->low_input ? s->high_input - s->low_input : 1;
  double output_span = s->high_output - s->low_output;
  int exponent;
  (void) frexp (fmax (fabs (denominator), fabs (output_span)), &exponent);
  int shift = exponent < 0 ? -exponent : 0;
  double span = scalbn (denominator, shift);
  double output = scalbn (output_span, shift);
  *coefficient = product_sum (1 - coverage, span, coverage, output) / span;
  double normalized_constant = product_sum (s->low_output, span, -s->low_input, output);
  double physical_constant = product_sum (offset, span - output, scale, normalized_constant);
  *constant = coverage * (physical_constant / span);
  return isfinite (*coefficient) && isfinite (*constant);
}

static bool
float_sample (GlimsLabRole role, const GlimsLabLevels *s, float source,
              double coverage, float *destination)
{
  if (!isfinite (source)) return false;
  double original = source;
  double offset = role == GLIMS_LAB_ROLE_L ? 0 : -128;
  double scale = role == GLIMS_LAB_ROLE_L ? 100 : 255;
  double input_span = s->high_input - s->low_input;
  double denominator = input_span != 0 ? input_span : 1;
  double output_span = s->high_output - s->low_output;
  double low_input = fma (scale, s->low_input, offset);
  double high_input = fma (scale, s->high_input, offset);

  /* Cancel the identity before normalization loses small physical chroma or
   * creates a one-ULP edit. Requested clamps still affect extended samples. */
  if (s->gamma == 1 && input_span != 0 &&
      s->low_input == s->low_output && s->high_input == s->high_output &&
      (!s->clamp_input || (original >= fmin (low_input, high_input) &&
                          original <= fmax (low_input, high_input))) &&
      (!s->clamp_output || (original >= offset && original <= offset + scale)))
    {
      *destination = source;
      return true;
    }

  /* Evaluate near the input anchor in physical units. A normalized binary32
   * intermediate would erase signed/near-neutral chroma and HDR precision. */
  double coordinate = (original - low_input) / (scale * denominator);
  if (!isfinite (coordinate)) return false;
  bool constant_region = false;
  if (s->clamp_input)
    {
      double limited = bounded (coordinate, 0, 1);
      double other_endpoint = input_span != 0 ? high_input : low_input + scale;
      constant_region = limited != coordinate ||
        original < fmin (low_input, other_endpoint) ||
        original > fmax (low_input, other_endpoint);
      coordinate = limited;
    }
  if (s->gamma != 1 && coordinate > 0)
    {
      coordinate = pow (coordinate, 1 / s->gamma);
      if (!isfinite (coordinate)) return false;
    }
  double mapped = coordinate * output_span;
  if (!isfinite (mapped)) return false;
  double target = fma (scale, mapped, fma (scale, s->low_output, offset));
  bool use_affine = fabs (original - low_input) >= fabs (original) * .5;
  if (s->gamma == 1 && !constant_region && use_affine)
    {
      double coefficient, constant;
      if (affine_coefficients (s, offset, scale, 1, &coefficient, &constant))
        target = fma (coefficient, original, constant);
    }
  if (!isfinite (target)) return false;
  if (s->clamp_output)
    {
      double limited = bounded (target, offset, offset + scale);
      constant_region = constant_region || limited != target;
      target = limited;
    }
  if (target == original)
    {
      *destination = source;
      return true;
    }

  double blended = target;
  if (coverage != 1)
    {
      double coefficient, constant;
      /* Combine the weighted slope before multiplying an extended sample.
       * Half-covered inversion is exactly L*=50 or chroma=-.5 even at
       * +/-FLT_MAX; evaluating two large opposing samples loses that value. */
      if (s->gamma == 1 && !constant_region && use_affine &&
          affine_coefficients (s, offset, scale, coverage, &coefficient, &constant))
        blended = fma (coefficient, original, constant);
      else
        blended = fma (coverage, target, (1 - coverage) * original);
    }
  if (!isfinite (blended) || fabs (blended) > FLT_MAX) return false;
  *destination = (float) blended;
  return true;
}

static bool
aliases_changed (const void *pointer, size_t bytes, uintptr_t start, uintptr_t end)
{
  if (!pointer || !bytes) return false;
  uintptr_t address = (uintptr_t) pointer;
  return address >= start ? address < end : start - address < bytes;
}

static bool
checked_end (const void *pointer, size_t bytes, uintptr_t *end)
{
  uintptr_t start = (uintptr_t) pointer;
  if (bytes > UINTPTR_MAX - start) return false;
  *end = start + bytes;
  return true;
}

static bool
overlaps (const void *a, uintptr_t a_end, const void *b, uintptr_t b_end)
{
  return (uintptr_t) a < b_end && (uintptr_t) b < a_end;
}

bool
glims_lab_levels_row (GlimsLabRole role, GlimsLabFormat format,
                      const GlimsLabLevels *settings, size_t count,
                      const void *source, const float *mask,
                      void *destination, bool *changed)
{
  if (!changed) return false;
  uintptr_t changed_start = (uintptr_t) changed, changed_end;
  if (!checked_end (changed, sizeof *changed, &changed_end)) return false;
  size_t width = glims_lab_sample_size (format);
  /* An invalid format still cannot authorize clobbering a flag inside the
   * caller's sample storage. Conservatively protect the largest sample width. */
  size_t protected_width = width ? width : sizeof (float);
  if (aliases_changed (settings, sizeof *settings, changed_start, changed_end)) return false;
  if (count && (source == (const void *) changed || destination == (void *) changed ||
                (const void *) mask == (const void *) changed)) return false;
  if (count <= SIZE_MAX / protected_width &&
      (aliases_changed (source, count * protected_width, changed_start, changed_end) ||
       aliases_changed (destination, count * protected_width, changed_start, changed_end))) return false;
  if (count <= SIZE_MAX / sizeof (float) &&
      aliases_changed (mask, count * sizeof (float), changed_start, changed_end)) return false;
  *changed = false;
  if (!width || count > GLIMS_LAB_LEVELS_MAX_SAMPLES || !settings ||
      (role != GLIMS_LAB_ROLE_L && role != GLIMS_LAB_ROLE_A && role != GLIMS_LAB_ROLE_B))
    return false;

  size_t bytes = count * width;
  uintptr_t source_end, destination_end, settings_end, mask_end = 0;
  if (!checked_end (source, bytes, &source_end) ||
      !checked_end (destination, bytes, &destination_end) ||
      !checked_end (settings, sizeof *settings, &settings_end) ||
      (mask && !checked_end (mask, count * sizeof (float), &mask_end))) return false;
  if (count && (!source || !destination)) return false;
  if (count && source != destination && overlaps (source, source_end, destination, destination_end))
    return false;
  if (count && mask && (overlaps (source, source_end, mask, mask_end) ||
                        overlaps (destination, destination_end, mask, mask_end))) return false;
  if (count && (overlaps (source, source_end, settings, settings_end) ||
                overlaps (destination, destination_end, settings, settings_end) ||
                (mask && overlaps (mask, mask_end, settings, settings_end)))) return false;

  GlimsLabLevels s;
  memcpy (&s, (const unsigned char *) (const void *) settings, sizeof s);
  if (!unit_value (s.low_input) || !unit_value (s.high_input) ||
      !unit_value (s.low_output) || !unit_value (s.high_output) ||
      !isfinite (s.gamma) || s.gamma < .1 || s.gamma > 10 ||
      s.clamp_input > 1 || s.clamp_output > 1) return false;
  if (!count) return true;

  const unsigned char *input = source;
  const unsigned char *mask_bytes = (const unsigned char *) mask;
  unsigned char staging[GLIMS_LAB_LEVELS_MAX_SAMPLES * sizeof (float)];
  for (size_t i = 0; i < count; i++)
    {
      float coverage = 1;
      if (mask) memcpy (&coverage, mask_bytes + i * sizeof coverage, sizeof coverage);
      if (!unit_value (coverage)) return false;
      if (coverage == 0)
        {
          memcpy (staging + i * width, input + i * width, width);
          continue;
        }
      if (format == GLIMS_LAB_FORMAT_FLOAT)
        {
          float value, result;
          memcpy (&value, input + i * width, sizeof value);
          if (!float_sample (role, &s, value, coverage, &result)) return false;
          memcpy (staging + i * width, &result, sizeof result);
        }
      else
        {
          /* Lab integer codes are affine in physical units, so normalized
           * Levels and weighted blending are exactly the scalar-code problem.
           * Reuse its compensated arithmetic and single final quantization. */
          GlimsComponentScalarFormat scalar = format == GLIMS_LAB_FORMAT_U8 ?
            GLIMS_COMPONENT_SCALAR_U8 : GLIMS_COMPONENT_SCALAR_U16;
          bool sample_changed;
          if (!glims_component_levels_row (scalar, &s, 1, input + i * width,
                                            &coverage, staging + i * width, &sample_changed))
            return false;
        }
    }
  bool any_changed = memcmp (source, staging, bytes) != 0;
  memcpy (destination, staging, bytes);
  *changed = any_changed;
  return true;
}
