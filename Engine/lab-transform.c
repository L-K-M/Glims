#include "lab-transform.h"

#include <float.h>
#include <lcms2.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct GlimsLabTransform {
  double xyz_to_rgb[3][3];
  double white[3];
  double rgb_to_xyz[3][3];
};

GlimsLabTransform *
glims_lab_transform_new (void)
{
  GlimsLabTransform *result = NULL;
  cmsContext context = cmsCreateContext (NULL, NULL);
  if (!context) return NULL;
  cmsToneCurve *curve = cmsBuildGamma (context, 1.0);
  if (!curve) { cmsDeleteContext (context); return NULL; }

  /* Same adjusted chromaticities as cmyk-transform.c and unmodified GIMP's
   * linear-sRGB profile. Its colorant tags include chromatic adaptation to
   * the D50 PCS, so the conversion must not apply adaptation a second time. */
  const cmsCIExyY white = { 0.3127, 0.3290, 1.0 };
  const cmsCIExyYTRIPLE primaries = {
    { 0.639998686, 0.330010138, 1.0 },
    { 0.300003784, 0.600003357, 1.0 },
    { 0.150002046, 0.059997204, 1.0 }
  };
  cmsToneCurve *curves[3] = { curve, curve, curve };
  cmsHPROFILE profile = cmsCreateRGBProfileTHR (context, &white, &primaries, curves);
  cmsFreeToneCurve (curve);
  if (!profile) { cmsDeleteContext (context); return NULL; }

  const cmsCIEXYZ *r = cmsReadTag (profile, cmsSigRedColorantTag);
  const cmsCIEXYZ *g = cmsReadTag (profile, cmsSigGreenColorantTag);
  const cmsCIEXYZ *b = cmsReadTag (profile, cmsSigBlueColorantTag);
  if (r && g && b)
    {
      const double m[3][3] = {
        { r->X, g->X, b->X }, { r->Y, g->Y, b->Y }, { r->Z, g->Z, b->Z }
      };
      double cofactors[3][3];
      for (int row = 0; row < 3; row++)
        for (int column = 0; column < 3; column++)
          cofactors[row][column] =
            m[(row + 1) % 3][(column + 1) % 3] * m[(row + 2) % 3][(column + 2) % 3] -
            m[(row + 1) % 3][(column + 2) % 3] * m[(row + 2) % 3][(column + 1) % 3];
      const double determinant = m[0][0] * cofactors[0][0] +
                                 m[0][1] * cofactors[0][1] +
                                 m[0][2] * cofactors[0][2];
      if (isfinite (determinant) && fabs (determinant) > 1e-12)
        {
          result = calloc (1, sizeof *result);
          if (result)
            {
              for (int row = 0; row < 3; row++)
                for (int column = 0; column < 3; column++)
                  result->xyz_to_rgb[row][column] = cofactors[column][row] / determinant;
              const cmsCIEXYZ *d50 = cmsD50_XYZ ();
              result->white[0] = d50->X;
              result->white[1] = d50->Y;
              result->white[2] = d50->Z;
              memcpy (result->rgb_to_xyz, m, sizeof m);
            }
        }
    }
  cmsCloseProfile (profile);
  cmsDeleteContext (context);
  return result;
}

void
glims_lab_transform_free (GlimsLabTransform *transform)
{
  free (transform);
}

/* CIE inverse f, ICC.1:2022 section 6.3.4. Double intermediates are deliberate:
 * LittleCMS' floating pipeline can overflow internally for finite Lab input
 * and return a finite RGB sentinel, which a final isfinite test cannot catch. */
static double
inverse_f (double value)
{
  return value > 6.0 / 29.0 ? value * value * value :
                             (108.0 / 841.0) * (value - 4.0 / 29.0);
}

static bool
convert_pixel (const GlimsLabTransform *transform, const unsigned char *source,
               float rgba[4])
{
  float lab[3];
  memcpy (lab, source, sizeof lab);
  if (!isfinite (lab[0]) || !isfinite (lab[1]) || !isfinite (lab[2])) return false;
  const double fy = ((double) lab[0] + 16.0) / 116.0;
  const double xyz[3] = {
    inverse_f (fy + (double) lab[1] / 500.0) * transform->white[0],
    (lab[0] > 8.0f ? fy * fy * fy : (double) lab[0] * 27.0 / 24389.0) * transform->white[1],
    inverse_f (fy - (double) lab[2] / 200.0) * transform->white[2]
  };
  for (int i = 0; i < 3; i++)
    {
      const double value = transform->xyz_to_rgb[i][0] * xyz[0] +
                           transform->xyz_to_rgb[i][1] * xyz[1] +
                           transform->xyz_to_rgb[i][2] * xyz[2];
      if (!isfinite (value) || fabs (value) > FLT_MAX) return false;
      rgba[i] = (float) value;
    }
  rgba[3] = 1.0f;
  return true;
}

bool
glims_lab_transform_pixels (const GlimsLabTransform *transform,
                            const void *lab, size_t count, void *rgba)
{
  if (!transform || count > 4096 || (count && (!lab || !rgba))) return false;
  if (!count) return true;
  const size_t input_size = count * 3 * sizeof (float);
  const size_t output_size = count * 4 * sizeof (float);
  const uintptr_t input = (uintptr_t) lab, output = (uintptr_t) rgba;
  if (input > UINTPTR_MAX - input_size || output > UINTPTR_MAX - output_size ||
      (input < output + output_size && output < input + input_size)) return false;

  const unsigned char *source = lab;
  unsigned char *destination = rgba;
  float pixel[4];
  for (size_t i = 0; i < count; i++)
    if (!convert_pixel (transform, source + i * 3 * sizeof (float), pixel)) return false;
  for (size_t i = 0; i < count; i++)
    {
      convert_pixel (transform, source + i * 3 * sizeof (float), pixel);
      memcpy (destination + i * sizeof pixel, pixel, sizeof pixel);
    }
  return true;
}

/* CIE forward f, paired with inverse_f above. The linear branch also covers
 * negative XYZ; taking a cube root of those values would change the model. */
static double
forward_f (double value)
{
  return value > 216.0 / 24389.0 ? cbrt (value) :
                                 (841.0 / 108.0) * value + 4.0 / 29.0;
}

static double
forward_f_difference (double first, double second)
{
  /* Cancel the shared intercept algebraically, not numerically. This retains
   * tiny signed chroma that adding then subtracting 4/29 would erase. */
  if (first <= 216.0 / 24389.0 && second <= 216.0 / 24389.0)
    return (841.0 / 108.0) * (first - second);
  return forward_f (first) - forward_f (second);
}

static bool
convert_linear_rgb_pixel (const GlimsLabTransform *transform,
                          const unsigned char *source, float lab[3])
{
  float rgb[3];
  memcpy (rgb, source, sizeof rgb);
  if (!isfinite (rgb[0]) || !isfinite (rgb[1]) || !isfinite (rgb[2])) return false;

  double xyz[3];
  for (int i = 0; i < 3; i++)
    xyz[i] = (transform->rgb_to_xyz[i][0] * (double) rgb[0] +
              transform->rgb_to_xyz[i][1] * (double) rgb[1] +
              transform->rgb_to_xyz[i][2] * (double) rgb[2]) / transform->white[i];

  const double values[3] = {
    /* Avoid subtracting the shared constant near black, including subnormals. */
    xyz[1] > 216.0 / 24389.0 ? 116.0 * cbrt (xyz[1]) - 16.0 :
                              (24389.0 / 27.0) * xyz[1],
    500.0 * forward_f_difference (xyz[0], xyz[1]),
    200.0 * forward_f_difference (xyz[1], xyz[2])
  };
  for (int i = 0; i < 3; i++)
    {
      if (!isfinite (values[i]) || fabs (values[i]) > FLT_MAX) return false;
      lab[i] = (float) values[i];
    }
  return true;
}

bool
glims_lab_transform_from_linear_rgb (const GlimsLabTransform *transform,
                                     const void *rgb, size_t count, void *lab)
{
  if (!transform || count > 4096 || (count && (!rgb || !lab))) return false;
  if (!count) return true;
  const size_t size = count * 3 * sizeof (float);
  const uintptr_t input = (uintptr_t) rgb, output = (uintptr_t) lab;
  if (input > UINTPTR_MAX - size || output > UINTPTR_MAX - size ||
      (input < output + size && output < input + size)) return false;

  const unsigned char *source = rgb;
  unsigned char *destination = lab;
  float pixel[3];
  for (size_t i = 0; i < count; i++)
    if (!convert_linear_rgb_pixel (transform, source + i * sizeof pixel, pixel)) return false;
  for (size_t i = 0; i < count; i++)
    {
      convert_linear_rgb_pixel (transform, source + i * sizeof pixel, pixel);
      memcpy (destination + i * sizeof pixel, pixel, sizeof pixel);
    }
  return true;
}
