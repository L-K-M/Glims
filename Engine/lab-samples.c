#include "lab-samples.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

_Static_assert(CHAR_BIT == 8 && sizeof(float) == 4 && sizeof(double) == 8 &&
               FLT_RADIX == 2 && FLT_MANT_DIG == 24 && FLT_MAX_EXP == 128 &&
               DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024,
               "Lab samples require binary32 and binary64 storage");

size_t
glims_lab_sample_size(GlimsLabFormat format)
{
  switch (format) {
  case GLIMS_LAB_FORMAT_U8: return sizeof(uint8_t);
  case GLIMS_LAB_FORMAT_U16: return sizeof(uint16_t);
  case GLIMS_LAB_FORMAT_FLOAT: return sizeof(float);
  default: return 0;
  }
}

static bool
row_valid(GlimsLabRole role, size_t count, const void *source, void *destination,
          size_t source_width, size_t destination_width)
{
  if ((role != GLIMS_LAB_ROLE_L && role != GLIMS_LAB_ROLE_A &&
       role != GLIMS_LAB_ROLE_B) || !source_width || !destination_width ||
      count > SIZE_MAX / source_width || count > SIZE_MAX / destination_width)
    return false;
  if (!count) return true;
  if (!source || !destination) return false;

  size_t source_bytes = count * source_width;
  size_t destination_bytes = count * destination_width;
  uintptr_t first = (uintptr_t)source, second = (uintptr_t)destination;
  if (source_bytes > UINTPTR_MAX - first ||
      destination_bytes > UINTPTR_MAX - second)
    return false;
  return first + source_bytes <= second || second + destination_bytes <= first;
}

/* Sign of the exact distance from the half boundary below code q.
 * All constants are small exact integers. A single correctly rounded FMA
 * retains the deciding bits: do not add 128 to chroma before this comparison.
 * A nonzero distance near these boundaries cannot underflow binary64. */
static double
lower_boundary(double value, GlimsLabRole role, unsigned maximum, unsigned q)
{
  if (role == GLIMS_LAB_ROLE_L)
    return fma(value, (double)maximum, 50.0 - 100.0 * q);
  double factor = maximum == 255 ? 2.0 : 514.0;
  return fma(value, factor, 128.0 * factor + 1.0 - 2.0 * q);
}

static unsigned
quantize(double value, GlimsLabRole role, unsigned maximum)
{
  /* Bounded input makes this estimate at most one code from the exact result.
   * Only the boundary comparisons determine a tie, not this approximation. */
  double scaled = role == GLIMS_LAB_ROLE_L ? value * maximum / 100.0 :
                  (value + 128.0) * (maximum == 255 ? 1.0 : 257.0);
  unsigned q = (unsigned)floor(scaled + 0.5);
  if (q > 0 && lower_boundary(value, role, maximum, q) < 0) return q - 1;
  if (q < maximum && lower_boundary(value, role, maximum, q + 1) >= 0) return q + 1;
  return q;
}

bool
glims_lab_decode_row(GlimsLabRole role, GlimsLabFormat format, size_t count,
                     const void *source, void *destination)
{
  size_t width = glims_lab_sample_size(format);
  if (!row_valid(role, count, source, destination, width, sizeof(double)))
    return false;
  const unsigned char *input = source;
  unsigned char *output = destination;

  /* Integer encodings have no invalid bit patterns. Float needs a complete
   * validation pass before publication, including the final sample. */
  if (format == GLIMS_LAB_FORMAT_FLOAT) {
    for (size_t i = 0; i < count; i++) {
      float value;
      memcpy(&value, input + i * width, sizeof(value));
      if (!isfinite(value)) return false;
    }
  }
  for (size_t i = 0; i < count; i++) {
    double value;
    if (format == GLIMS_LAB_FORMAT_FLOAT) {
      float encoded;
      memcpy(&encoded, input + i * width, sizeof(encoded));
      value = encoded;
    } else {
      unsigned q;
      if (format == GLIMS_LAB_FORMAT_U8) q = input[i];
      else {
        uint16_t encoded;
        memcpy(&encoded, input + i * width, sizeof(encoded));
        q = encoded;
      }
      if (role == GLIMS_LAB_ROLE_L)
        value = 100.0 * q / (format == GLIMS_LAB_FORMAT_U8 ? 255.0 : 65535.0);
      else
        value = q / (format == GLIMS_LAB_FORMAT_U8 ? 1.0 : 257.0) - 128.0;
    }
    memcpy(output + i * sizeof(double), &value, sizeof(value));
  }
  return true;
}

bool
glims_lab_encode_row(GlimsLabRole role, GlimsLabFormat format, size_t count,
                     const void *source, void *destination)
{
  size_t width = glims_lab_sample_size(format);
  if (!row_valid(role, count, source, destination, sizeof(double), width))
    return false;
  const unsigned char *input = source;
  unsigned char *output = destination;

  for (size_t i = 0; i < count; i++) {
    double value;
    memcpy(&value, input + i * sizeof(double), sizeof(value));
    if (!isfinite(value)) return false;
    if (format == GLIMS_LAB_FORMAT_FLOAT) {
      if (fabs(value) > FLT_MAX) return false;
    } else if (role == GLIMS_LAB_ROLE_L) {
      if (value < 0 || value > 100) return false;
    } else if (value < -128 || value > 127) return false;
  }
  for (size_t i = 0; i < count; i++) {
    double value;
    memcpy(&value, input + i * sizeof(double), sizeof(value));
    if (format == GLIMS_LAB_FORMAT_FLOAT) {
      float encoded = (float)value;
      memcpy(output + i * width, &encoded, sizeof(encoded));
    } else if (format == GLIMS_LAB_FORMAT_U8) {
      uint8_t encoded = (uint8_t)quantize(value, role, 255);
      memcpy(output + i * width, &encoded, sizeof(encoded));
    } else {
      uint16_t encoded = (uint16_t)quantize(value, role, 65535);
      memcpy(output + i * width, &encoded, sizeof(encoded));
    }
  }
  return true;
}
