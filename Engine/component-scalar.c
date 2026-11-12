#include "component-scalar.h"
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

/* Calculate one sample into bytes. The same calculation in preflight and
 * publication keeps a bad late sample from partially changing the row. */
static bool
sample (GlimsComponentScalarFormat format, GlimsComponentScalarOperation operation,
        double intensity, double weight, const unsigned char *source,
        unsigned char result[sizeof (float)], size_t width)
{
  memcpy (result, source, width);
  if (weight == 0) return true;
  double scale = format == GLIMS_COMPONENT_SCALAR_U8 ? 255 :
                 format == GLIMS_COMPONENT_SCALAR_U16 ? 65535 : 1;
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
  /* Keep integer arithmetic in native sample units. Normalizing and scaling
   * again can turn an exact half-integer into a value just below the tie. */
  double target = operation == GLIMS_COMPONENT_SCALAR_INVERT ? scale - original : intensity * scale;
  /* At full coverage, subtraction can erase a small target when the source
   * is a large finite float. Preserve the exact endpoint of the blend. */
  double blended = weight == 1 ? target : original + weight * (target - original);
  /* Invert's algebraic form retains the constant contribution when large
   * opposite values cancel. Half coverage must yield .5 at every finite I. */
  if (operation == GLIMS_COMPONENT_SCALAR_INVERT)
    blended = original * (1 - 2 * weight) + weight * scale;
  if (!isfinite (blended)) return false;
  if (format == GLIMS_COMPONENT_SCALAR_FLOAT)
    {
      if (blended < -FLT_MAX || blended > FLT_MAX) return false;
      float value = (float) blended;
      memcpy (result, &value, sizeof value);
    }
  else
    {
      /* Integer endpoints are bounded; limit possible arithmetic roundoff
       * before converting to an unsigned integer. Float is never clipped. */
      if (blended < 0) blended = 0;
      if (blended > scale) blended = scale;
      if (format == GLIMS_COMPONENT_SCALAR_U8)
        result[0] = (uint8_t) floor (blended + .5);
      else
        {
          uint16_t value = (uint16_t) floor (blended + .5);
          memcpy (result, &value, sizeof value);
        }
    }
  return true;
}

bool
glims_component_scalar_row (GlimsComponentScalarFormat format,
                             GlimsComponentScalarOperation operation,
                             double intensity, double opacity, size_t count,
                             const void *source, const float *mask,
                             void *destination, bool *changed)
{
  if (!changed) return false;
  *changed = false;
  if ((format != GLIMS_COMPONENT_SCALAR_U8 && format != GLIMS_COMPONENT_SCALAR_U16 &&
       format != GLIMS_COMPONENT_SCALAR_FLOAT) ||
      (operation != GLIMS_COMPONENT_SCALAR_FILL && operation != GLIMS_COMPONENT_SCALAR_INVERT) ||
      !isfinite (intensity) || intensity < 0 || intensity > 1 ||
      !isfinite (opacity) || opacity < 0 || opacity > 1 ||
      (operation == GLIMS_COMPONENT_SCALAR_INVERT && (intensity != 0 || opacity != 1)))
    return false;
  size_t width = format == GLIMS_COMPONENT_SCALAR_U8 ? sizeof (uint8_t) :
                 format == GLIMS_COMPONENT_SCALAR_U16 ? sizeof (uint16_t) : sizeof (float);
  if (count > SIZE_MAX / width || (mask && count > SIZE_MAX / sizeof *mask) ||
      (count && (!source || !destination))) return false;
  const unsigned char *input = source;
  unsigned char *output = destination;
  unsigned char result[sizeof (float)];
  for (size_t i = 0; i < count; i++)
    {
      double coverage = mask ? mask[i] : 1;
      if (!isfinite (coverage) || coverage < 0 || coverage > 1 ||
          !sample (format, operation, intensity, opacity * coverage, input + i * width, result, width))
        return false;
    }
  for (size_t i = 0; i < count; i++)
    {
      double coverage = mask ? mask[i] : 1;
      (void) sample (format, operation, intensity, opacity * coverage, input + i * width, result, width);
      if (memcmp (input + i * width, result, width)) *changed = true;
      memcpy (output + i * width, result, width);
    }
  return true;
}
