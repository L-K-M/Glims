#include "lab-transform.h"

#include <float.h>
#include <lcms2.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; \
  fprintf (stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int
main (void)
{
  GlimsLabTransform *transform = glims_lab_transform_new ();
  CHECK (transform != NULL);
  if (!transform) return 1;

  /* Independently constructed LittleCMS transform: standard built-in sRGB
   * chromaticities with linear tone curves, rather than copying the production
   * matrix/profile construction. Small colorant differences are expected. */
  cmsContext context = cmsCreateContext (NULL, NULL);
  cmsHPROFILE lab_profile = cmsCreateLab4ProfileTHR (context, NULL);
  cmsHPROFILE rgb_profile = cmsCreate_sRGBProfileTHR (context);
  cmsToneCurve *linear = cmsBuildGamma (context, 1.0);
  CHECK (context && lab_profile && rgb_profile && linear);
  if (!context || !lab_profile || !rgb_profile || !linear) return 2;
  CHECK (cmsWriteTag (rgb_profile, cmsSigRedTRCTag, linear));
  CHECK (cmsWriteTag (rgb_profile, cmsSigGreenTRCTag, linear));
  CHECK (cmsWriteTag (rgb_profile, cmsSigBlueTRCTag, linear));
  cmsFreeToneCurve (linear);
  cmsHTRANSFORM oracle = cmsCreateTransformTHR (context, lab_profile, TYPE_Lab_DBL,
    rgb_profile, TYPE_RGB_DBL, INTENT_RELATIVE_COLORIMETRIC,
    cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE);
  CHECK (oracle != NULL);
  if (!oracle) return 2;

  const float lightness[] = {-5, 0, 4, 8, 8.000001f, 25, 50, 100, 110};
  const float chroma[] = {-160, -128, -64, -1, 0, 1, 64, 127, 160};
  double maximum_error = 0;
  bool negative = false, extended = false;
  for (size_t l = 0; l < sizeof lightness / sizeof *lightness; l++)
    for (size_t a = 0; a < sizeof chroma / sizeof *chroma; a++)
      for (size_t b = 0; b < sizeof chroma / sizeof *chroma; b++)
        {
          float input[3] = {lightness[l], chroma[a], chroma[b]}, output[4];
          double expected[3], physical[3] = {input[0], input[1], input[2]};
          cmsDoTransform (oracle, physical, expected, 1);
          CHECK (glims_lab_transform_pixels (transform, input, 1, output));
          CHECK (output[3] == 1.0f);
          for (int c = 0; c < 3; c++)
            {
              double error = fabs ((double) output[c] - expected[c]);
              if (error > maximum_error) maximum_error = error;
              CHECK (error <= 0.0003 * fmax (1.0, fabs (expected[c])));
              negative |= output[c] < 0;
              extended |= output[c] > 1;
            }
        }
  CHECK (negative && extended);

  /* Independent analytic neutral oracles: CIE L=8 boundary and L=50 cube. */
  const float neutrals[] = {0, 8, 50, 100};
  const double luminance[] = {0, 216.0 / 24389.0, 0.18418651851244416, 1};
  for (size_t i = 0; i < 4; i++)
    {
      float input[3] = {neutrals[i], 0, 0}, output[4];
      CHECK (glims_lab_transform_pixels (transform, input, 1, output));
      for (int c = 0; c < 3; c++) CHECK (fabs (output[c] - luminance[i]) < 0.00002);
    }

  float input[6] = {50, -64, 127, 100, 0, 0};
  unsigned char output[8 * sizeof (float)], untouched[sizeof output];
  memset (untouched, 0xa5, sizeof untouched);
  const float invalid[] = {NAN, INFINITY, -INFINITY, FLT_MAX};
  for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++)
    {
      input[3] = invalid[i];
      memcpy (output, untouched, sizeof output);
      CHECK (!glims_lab_transform_pixels (transform, input, 2, output));
      CHECK (memcmp (output, untouched, sizeof output) == 0);
    }
  input[3] = 50; input[4] = FLT_MAX;
  CHECK (!glims_lab_transform_pixels (transform, input, 2, output));
  CHECK (memcmp (output, untouched, sizeof output) == 0);
  input[4] = 0; input[5] = -FLT_MAX;
  CHECK (!glims_lab_transform_pixels (transform, input, 2, output));
  CHECK (memcmp (output, untouched, sizeof output) == 0);

  /* Negative L follows CIE's linear branch, so even -FLT_MAX can yield
   * representable RGB. Refusal is based on the result, not a nominal clamp. */
  const float negative_lightness[3] = {-FLT_MAX, 0, 0};
  float negative_rgb[4];
  CHECK (glims_lab_transform_pixels (transform, negative_lightness, 1, negative_rgb));
  for (int c = 0; c < 3; c++) CHECK (isfinite (negative_rgb[c]) && negative_rgb[c] < 0);
  const double negative_luminance = -(double) FLT_MAX * 27.0 / 24389.0;
  for (int c = 0; c < 3; c++) CHECK (fabs (negative_rgb[c] / negative_luminance - 1.0) < 0.00002);
  CHECK (negative_rgb[3] == 1);

  CHECK (glims_lab_transform_pixels (transform, NULL, 0, NULL));
  CHECK (!glims_lab_transform_pixels (NULL, NULL, 0, NULL));
  CHECK (!glims_lab_transform_pixels (transform, NULL, 1, output));
  CHECK (!glims_lab_transform_pixels (transform, input, 1, NULL));
  CHECK (!glims_lab_transform_pixels (transform, input, 4097, output));
  CHECK (!glims_lab_transform_pixels (transform, input, SIZE_MAX, output));
  CHECK (!glims_lab_transform_pixels (transform, output, 1, output));
  CHECK (!glims_lab_transform_pixels (transform, output, 1, output + 1));
  CHECK (!glims_lab_transform_pixels (transform, output + 1, 1, output));
  CHECK (memcmp (output, untouched, sizeof output) == 0);

  unsigned char unaligned_input[14], unaligned_output[18];
  const float unaligned_values[3] = {50, -128, 127};
  float aligned_output[4];
  memset (unaligned_input, 0x5a, sizeof unaligned_input);
  memset (unaligned_output, 0xa5, sizeof unaligned_output);
  memcpy (unaligned_input + 1, unaligned_values, sizeof unaligned_values);
  CHECK (glims_lab_transform_pixels (transform, unaligned_values, 1, aligned_output));
  CHECK (glims_lab_transform_pixels (transform, unaligned_input + 1, 1, unaligned_output + 1));
  CHECK (memcmp (aligned_output, unaligned_output + 1, sizeof aligned_output) == 0);
  CHECK (unaligned_output[0] == 0xa5 && unaligned_output[17] == 0xa5);
  CHECK (unaligned_input[0] == 0x5a && unaligned_input[13] == 0x5a);

  float batch[4096 * 3], results[4096 * 4];
  for (size_t i = 0; i < 4096; i++) memcpy (batch + i * 3, unaligned_values, sizeof unaligned_values);
  CHECK (glims_lab_transform_pixels (transform, batch, 4096, results));
  for (size_t i = 0; i < 4096; i++) CHECK (memcmp (results + i * 4, aligned_output, sizeof aligned_output) == 0);

  cmsDeleteTransform (oracle);
  cmsCloseProfile (rgb_profile); cmsCloseProfile (lab_profile);
  cmsDeleteContext (context);
  glims_lab_transform_free (transform);
  glims_lab_transform_free (NULL);
  printf ("Lab transform: %u checks, %u failures; maximum LCMS absolute difference %.9g\n",
          checks, failures, maximum_error);
  return failures ? 1 : 0;
}
