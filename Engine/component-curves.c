#include "component-curves.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

/* Predictable rounding of the interpolation and coverage products. */
#pragma STDC FP_CONTRACT OFF

static bool
unit_value (double value)
{
  return isfinite (value) && value >= 0 && value <= 1;
}

/* Normalized [0,1] lookup between adjacent entries. Intensities outside
 * [0,1] read the endpoint entries: a nonidentity curve keeps its endpoint
 * values for extended float inputs. */
static double
curve_lookup (const GlimsComponentCurve *curve, double intensity)
{
  const double *samples = curve->samples;
  if (intensity <= 0) return samples[0];
  if (intensity >= 1) return samples[GLIMS_COMPONENT_CURVE_SAMPLES - 1];
  double position = intensity * (GLIMS_COMPONENT_CURVE_SAMPLES - 1);
  unsigned int index = (unsigned int) position;
  if (index >= GLIMS_COMPONENT_CURVE_SAMPLES - 1)
    return samples[GLIMS_COMPONENT_CURVE_SAMPLES - 1];
  double fraction = position - (double) index;
  return samples[index] + fraction * (samples[index + 1] - samples[index]);
}

/* U16 enters the table as quotient/257 and remainder/257 within the segment,
 * so the low bits interpolate instead of quantizing to U8 first. Weighing
 * the adjacent entries and scaling by 255 is the same interpolation as
 * remainder/257, evaluated without forming the rounded segment quotient. */
static double
curve_target_u16 (const GlimsComponentCurve *curve, uint16_t value)
{
  const double *samples = curve->samples;
  unsigned int index = value / 257;
  if (index >= GLIMS_COMPONENT_CURVE_SAMPLES - 1)
    return samples[GLIMS_COMPONENT_CURVE_SAMPLES - 1] * 65535;
  unsigned int rest = value % 257;
  return 255 * (samples[index] * (257 - rest) + samples[index + 1] * rest);
}

/* Evaluate one sample into result bytes. The same calculation runs in
 * preflight and publication so a bad late sample never partially writes. */
static bool
curve_sample (GlimsComponentScalarFormat format, const GlimsComponentCurve *curve,
              bool identity, double coverage, const unsigned char *source,
              size_t width, unsigned char result[sizeof (float)])
{
  memcpy (result, source, width);
  if (coverage == 0) return true;

  double scale = format == GLIMS_COMPONENT_SCALAR_U8 ? 255 :
                 format == GLIMS_COMPONENT_SCALAR_U16 ? 65535 : 1;
  double original;
  uint16_t value16 = 0;
  if (format == GLIMS_COMPONENT_SCALAR_U8)
    original = source[0];
  else if (format == GLIMS_COMPONENT_SCALAR_U16)
    {
      memcpy (&value16, source, sizeof value16);
      original = value16;
    }
  else
    {
      float value;
      memcpy (&value, source, sizeof value);
      if (!isfinite (value)) return false;
      original = value;
    }
  /* A canonical identity preserves every finite source encoding, including
   * extended float values and negative zero. */
  if (identity) return true;

  double target = format == GLIMS_COMPONENT_SCALAR_U8 ? curve->samples[source[0]] * 255 :
                  format == GLIMS_COMPONENT_SCALAR_U16 ? curve_target_u16 (curve, value16) :
                  curve_lookup (curve, original);
  /* A mapped value equal to the original preserves the source bytes. */
  if (target == original) return true;
  /* Full coverage keeps the exact endpoint instead of blending back. */
  double blended = coverage == 1 ? target : original + coverage * (target - original);
  if (!isfinite (blended)) return false;
  if (format == GLIMS_COMPONENT_SCALAR_FLOAT)
    {
      if (blended < -FLT_MAX || blended > FLT_MAX) return false;
      float output = (float) blended;
      memcpy (result, &output, sizeof output);
    }
  else
    {
      /* The blend stays inside the endpoint interval; only roundoff can
       * carry it outside, so bound it before the unsigned conversion. */
      if (blended < 0) blended = 0;
      if (blended > scale) blended = scale;
      if (format == GLIMS_COMPONENT_SCALAR_U8)
        result[0] = (uint8_t) floor (blended + .5);
      else
        {
          uint16_t output = (uint16_t) floor (blended + .5);
          memcpy (result, &output, sizeof output);
        }
    }
  return true;
}

bool
glims_component_curves_row (GlimsComponentScalarFormat  format,
                            const GlimsComponentCurve  *curve,
                            size_t                      count,
                            const void                 *source,
                            const float                *mask,
                            void                       *destination,
                            bool                       *changed)
{
  if (!changed) return false;
  *changed = false;
  if (!curve ||
      (format != GLIMS_COMPONENT_SCALAR_U8 && format != GLIMS_COMPONENT_SCALAR_U16 &&
       format != GLIMS_COMPONENT_SCALAR_FLOAT))
    return false;
  /* Every entry is validated even for a zero-length row. */
  bool identity = true;
  for (size_t i = 0; i < GLIMS_COMPONENT_CURVE_SAMPLES; i++)
    {
      if (!unit_value (curve->samples[i])) return false;
      if (curve->samples[i] != (double) i / (GLIMS_COMPONENT_CURVE_SAMPLES - 1))
        identity = false;
    }
  size_t width = format == GLIMS_COMPONENT_SCALAR_U8 ? sizeof (uint8_t) :
                 format == GLIMS_COMPONENT_SCALAR_U16 ? sizeof (uint16_t) : sizeof (float);
  if (count > SIZE_MAX / width || (mask && count > SIZE_MAX / sizeof *mask) ||
      (count && (!source || !destination)))
    return false;

  const unsigned char *input = source;
  unsigned char *output = destination;
  unsigned char result[sizeof (float)];
  /* Validate the complete row before publication. Inputs are borrowed and
   * immutable for this call, except the supported exact in-place buffer. */
  for (size_t i = 0; i < count; i++)
    {
      double coverage = mask ? mask[i] : 1;
      if (!unit_value (coverage) ||
          !curve_sample (format, curve, identity, coverage, input + i * width, width, result))
        return false;
    }
  for (size_t i = 0; i < count; i++)
    {
      double coverage = mask ? mask[i] : 1;
      (void) curve_sample (format, curve, identity, coverage, input + i * width, width, result);
      if (memcmp (input + i * width, result, width)) *changed = true;
      memcpy (output + i * width, result, width);
    }
  return true;
}
