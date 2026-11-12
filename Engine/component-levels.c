#include "component-levels.h"

#include <float.h>
#include <math.h>
#include <string.h>

/* Compensated products require separately rounded intermediates. */
#pragma STDC FP_CONTRACT OFF

static bool
unit_value (double value)
{
  return isfinite (value) && value >= 0 && value <= 1;
}

static double
bounded (double value, double high)
{
  return value < 0 ? 0 : value > high ? high : value;
}

/* Sum two products without discarding the low parts when their large terms
 * cancel. Inputs here are bounded after the shared power-of-two scaling. */
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
affine_coefficients (const GlimsComponentLevels *s, double scale, double coverage,
                     double *coefficient, double *constant)
{
  double denominator = s->high_input != s->low_input ? s->high_input - s->low_input : 1;
  double output_span = s->high_output - s->low_output;
  int exponent;
  (void) frexp (fmax (fabs (denominator), fabs (output_span)), &exponent);
  int shift = exponent < 0 ? -exponent : 0;
  double span = scalbn (denominator, shift);
  double output = scalbn (output_span, shift);
  *coefficient = product_sum (1 - coverage, span, coverage, output) / span;
  *constant = product_sum (s->low_output, span, -s->low_input, output) / span;
  *constant *= coverage * scale;
  return isfinite (*coefficient) && isfinite (*constant);
}

static bool
store_sample (GlimsComponentScalarFormat format, double value, double scale,
              unsigned char result[sizeof (float)])
{
  if (!isfinite (value)) return false;
  if (format == GLIMS_COMPONENT_SCALAR_FLOAT)
    {
      if (value < -FLT_MAX || value > FLT_MAX) return false;
      float output = (float) value;
      memcpy (result, &output, sizeof output);
    }
  else if (format == GLIMS_COMPONENT_SCALAR_U8)
    result[0] = (uint8_t) floor (bounded (value, scale) + .5);
  else
    {
      uint16_t output = (uint16_t) floor (bounded (value, scale) + .5);
      memcpy (result, &output, sizeof output);
    }
  return true;
}

/* Semantic reference: pinned GIMP 3.2.8 app/operations/gimpoperationlevels.c:95,
 * gimp_operation_levels_map. This owns scalar precision, not GIMP/RGB bitwise
 * equivalence. Gamma-one mappings stay in native integer sample units. */
static bool
levels_sample (GlimsComponentScalarFormat format, const GlimsComponentLevels *s,
               double coverage, const unsigned char *source, size_t width,
               unsigned char result[sizeof (float)])
{
  memcpy (result, source, width);
  if (coverage == 0) return true;

  double original;
  if (format == GLIMS_COMPONENT_SCALAR_U8)
    original = source[0];
  else if (format == GLIMS_COMPONENT_SCALAR_U16)
    {
      uint16_t value;
      memcpy (&value, source, sizeof value);
      original = value;
    }
  else
    {
      float value;
      memcpy (&value, source, sizeof value);
      if (!isfinite (value)) return false;
      original = value;
    }

  double scale = format == GLIMS_COMPONENT_SCALAR_U8 ? 255 :
                 format == GLIMS_COMPONENT_SCALAR_U16 ? 65535 : 1;
  double input_span = s->high_input - s->low_input;
  double denominator = input_span != 0 ? input_span : 1;
  double output_span = s->high_output - s->low_output;

  /* Cancel exact identity algebra before evaluation, including reversed
   * ranges. Clamps still apply outside their respective identity regions.
   * Copying keeps negative zero and avoids one-ULP phantom edits. */
  if (s->gamma == 1 && input_span != 0 &&
      s->low_input == s->low_output && s->high_input == s->high_output &&
      (!s->clamp_input ||
       (original >= fmin (s->low_input, s->high_input) * scale &&
        original <= fmax (s->low_input, s->high_input) * scale)) &&
      (!s->clamp_output || (original >= 0 && original <= scale)))
    return true;

  double target;
  bool constant_region = false;
  /* Centered evaluation is accurate near the input endpoint, where expanding
   * the affine terms would subtract huge nearly equal coefficients. Elsewhere
   * the compensated affine form avoids losing a small output to cancellation. */
  bool use_affine = fabs (original - s->low_input * scale) >= fabs (original) * .5;
  if (s->gamma == 1)
    {
      double coordinate = (original - s->low_input * scale) / denominator;
      if (!isfinite (coordinate)) return false;
      if (s->clamp_input)
        {
          double limited = bounded (coordinate, scale);
          double other_endpoint = input_span != 0 ? s->high_input : s->low_input + 1;
          constant_region = limited != coordinate ||
            original < fmin (s->low_input, other_endpoint) * scale ||
            original > fmax (s->low_input, other_endpoint) * scale;
          coordinate = limited;
        }
      double product = coordinate * output_span;
      if (!isfinite (product)) return false;
      target = s->low_output * scale + product;
      if (format == GLIMS_COMPONENT_SCALAR_FLOAT && !constant_region && use_affine)
        {
          double coefficient, constant;
          if (affine_coefficients (s, scale, 1, &coefficient, &constant))
            target = fma (coefficient, original, constant);
        }
    }
  else
    {
      double coordinate = (original / scale - s->low_input) / denominator;
      if (!isfinite (coordinate)) return false;
      if (s->clamp_input) coordinate = bounded (coordinate, 1);
      if (coordinate > 0)
        {
          coordinate = pow (coordinate, 1 / s->gamma);
          if (!isfinite (coordinate)) return false;
        }
      double product = coordinate * output_span;
      if (!isfinite (product)) return false;
      double mapped = s->low_output + product;
      if (!isfinite (mapped)) return false;
      if (s->clamp_output) mapped = bounded (mapped, 1);
      target = mapped * scale;
    }
  if (!isfinite (target)) return false;
  if (s->clamp_output)
    {
      double limited = bounded (target, scale);
      constant_region = constant_region || limited != target;
      target = limited;
    }

  if (format != GLIMS_COMPONENT_SCALAR_FLOAT && s->gamma == 1 && !constant_region)
    {
      /* Integer half ties must be rounded only after the complete weighted
       * rational expression. Dividing a slope first can move 3568.5 below
       * the tie even when every endpoint and mask is an exact binary fraction. */
      int exponent;
      (void) frexp (fmax (fabs (denominator), fabs (output_span)), &exponent);
      int shift = exponent < 0 ? -exponent : 0;
      double span = scalbn (denominator, shift);
      double output = scalbn (output_span, shift);
      /* A subnormal denominator would discard the intercept before division.
       * The already evaluated centered target remains usable in that case. */
      if (fabs (span) >= DBL_MIN)
        {
          double coefficient = product_sum (1 - coverage, span, coverage, output);
          double intercept = product_sum (s->low_output, span, -s->low_input, output);
          double numerator = product_sum (coefficient, original, coverage * scale, intercept);
          return store_sample (format, numerator / span, scale, result);
        }
    }

  if (target == original) return true;
  double blended = target;
  if (coverage != 1)
    {
      if (s->gamma == 1 && !constant_region && use_affine)
        {
          /* Keep the affine constant separate: half-covered inversion must
           * yield .5 even at +/-FLT_MAX, where 1-I itself loses the 1. */
          /* Combine the weighted spans BEFORE division. Dividing the slope
           * first rounds an exact cancelling coefficient away from zero, then
           * amplifies that error by a potentially huge finite float sample. */
          double coefficient, constant;
          if (affine_coefficients (s, scale, coverage, &coefficient, &constant))
            blended = fma (coefficient, original, constant);
          else
            blended = (1 - coverage) * original + coverage * target;
        }
      else
        blended = (1 - coverage) * original + coverage * target;
    }
  return store_sample (format, blended, scale, result);
}

bool
glims_component_levels_row (GlimsComponentScalarFormat format,
                            const GlimsComponentLevels *settings, size_t count,
                            const void *source, const float *mask,
                            void *destination, bool *changed)
{
  if (!changed) return false;
  *changed = false;
  if (!settings ||
      (format != GLIMS_COMPONENT_SCALAR_U8 && format != GLIMS_COMPONENT_SCALAR_U16 &&
       format != GLIMS_COMPONENT_SCALAR_FLOAT) ||
      !unit_value (settings->low_input) || !unit_value (settings->high_input) ||
      !unit_value (settings->low_output) || !unit_value (settings->high_output) ||
      !isfinite (settings->gamma) || settings->gamma < .1 || settings->gamma > 10 ||
      settings->clamp_input > 1 || settings->clamp_output > 1)
    return false;
  size_t width = format == GLIMS_COMPONENT_SCALAR_U8 ? sizeof (uint8_t) :
                 format == GLIMS_COMPONENT_SCALAR_U16 ? sizeof (uint16_t) : sizeof (float);
  if (count > SIZE_MAX / width || (mask && count > SIZE_MAX / sizeof *mask) ||
      (count && (!source || !destination))) return false;

  const unsigned char *input = source;
  unsigned char *output = destination;
  unsigned char result[sizeof (float)];
  /* Validate the complete row before publication. Inputs are borrowed and
   * immutable for this call, except the supported exact in-place buffer. */
  for (size_t i = 0; i < count; i++)
    {
      double coverage = mask ? mask[i] : 1;
      if (!unit_value (coverage) ||
          !levels_sample (format, settings, coverage, input + i * width, width, result))
        return false;
    }
  for (size_t i = 0; i < count; i++)
    {
      double coverage = mask ? mask[i] : 1;
      (void) levels_sample (format, settings, coverage, input + i * width, width, result);
      if (memcmp (input + i * width, result, width)) *changed = true;
      memcpy (output + i * width, result, width);
    }
  return true;
}
