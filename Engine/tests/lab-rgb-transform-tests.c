/* Independent forward oracle: do not derive constants from lab-transform.c.
 * Inputs are straight LINEAR sRGB, never display-encoded sRGB. */
#include "lab-transform.h"

#include <float.h>
#include <lcms2.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert (sizeof (float) == 4 && FLT_RADIX == 2 && FLT_MANT_DIG == 24 &&
                FLT_MAX_EXP == 128, "This contract requires binary32 floats");

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; \
  fprintf (stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)

/* Fixed before executing the producer. Ordinary LCMS compares physical Lab
 * units. The rounded independent Bradford/D50 colorants need a slightly
 * wider bound; neither bound is an observed-error-derived tolerance. */
static const double lcms_tolerance = 0.03;
static const double anchor_tolerance = 0.08;
static const double rgb_roundtrip_tolerance = 0.00002;
static const double lab_roundtrip_tolerance = 0.003;

static bool
near (double actual, double expected, double absolute)
{
  return isfinite (actual) && fabs (actual - expected) <= absolute;
}

static bool
filled (const unsigned char *bytes, size_t count, unsigned char value)
{
  for (size_t i = 0; i < count; i++)
    if (bytes[i] != value) return false;
  return true;
}

static double
cie_f (double value)
{
  /* CIE 1976 rational constants, including the signed linear branch. */
  return value > 216.0 / 24389.0 ? cbrt (value)
       : (24389.0 / 27.0 * value + 16.0) / 116.0;
}

static void
reference_lab (const float rgb[3], double lab[3])
{
  /* Standard sRGB colorants chromatically adapted D65 -> D50 by Bradford,
   * rounded to seven decimal places; D50 XYZ white is (0.96422,1,0.82521).
   * This is an independent XYZ/CIE reference, not producer coefficients.
   * No TRC is applied: the fixture's RGB samples are already linear. */
  const double x = 0.4360747 * rgb[0] + 0.3850649 * rgb[1] + 0.1430804 * rgb[2];
  const double y = 0.2225045 * rgb[0] + 0.7168786 * rgb[1] + 0.0606169 * rgb[2];
  const double z = 0.0139322 * rgb[0] + 0.0971045 * rgb[1] + 0.7141733 * rgb[2];
  const double fx = cie_f (x / 0.96422), fy = cie_f (y), fz = cie_f (z / 0.82521);
  lab[0] = 116.0 * fy - 16.0;
  lab[1] = 500.0 * (fx - fy);
  lab[2] = 200.0 * (fy - fz);
}

static void
check_anchors (const GlimsLabTransform *transform)
{
  /* Literal physical D50 anchors. Gray .18 is linear luminance, so its L*
   * is 49.496..., not the result of decoding or encoding a display TRC. */
  const struct { float rgb[3]; double lab[3]; } anchors[] = {
    {{0, 0, 0}, {0, 0, 0}}, {{1, 1, 1}, {100, 0, 0}},
    {{0.18f, 0.18f, 0.18f}, {49.4961076101, 0, 0}},
    {{0.5f, 0.5f, 0.5f}, {76.0692610142, 0, 0}},
    {{1, 0, 0}, {54.2917337686, 80.8124553180, 69.8850403235}},
    {{0, 1, 0}, {87.8181282394, -79.2872809299, 80.9902538861}},
    {{0, 0, 1}, {29.5675728636, 68.2986532657, -112.0294299129}}
  };
  for (size_t i = 0; i < sizeof anchors / sizeof *anchors; i++)
    {
      float actual[3] = {NAN, NAN, NAN};
      CHECK (glims_lab_transform_from_linear_rgb (transform, anchors[i].rgb, 1, actual));
      for (size_t c = 0; c < 3; c++) CHECK (near (actual[c], anchors[i].lab[c], anchor_tolerance));
    }

  /* Both neighbors of the CIE knee; the signed side must not clamp at zero.
   * Neutral L is independently 116*f(Y)-16. Check the slope by its value,
   * rather than comparing production forward and reverse implementations. */
  const float knee = (float) (216.0 / 24389.0);
  const float levels[] = {-1.0f, -0.001f, -FLT_MIN, -0.0f, 0.0f, FLT_MIN,
                         0.0031308f, nextafterf (knee, -INFINITY), knee,
                         nextafterf (knee, INFINITY), 0.04045f, 2.0f};
  float previous_knee = -INFINITY;
  for (size_t i = 0; i < sizeof levels / sizeof *levels; i++)
    {
      const float rgb[3] = {levels[i], levels[i], levels[i]};
      float lab[3] = {NAN, NAN, NAN};
      const double expected_l = levels[i] <= 216.0 / 24389.0
                              ? 24389.0 / 27.0 * levels[i]
                              : 116.0 * cbrt (levels[i]) - 16.0;
      CHECK (glims_lab_transform_from_linear_rgb (transform, rgb, 1, lab));
      CHECK (near (lab[0], expected_l, 0.0002));
      CHECK (near (lab[1], 0, 0.003) && near (lab[2], 0, 0.003));
      if (fabsf (levels[i]) == FLT_MIN)
        CHECK (near (lab[0], expected_l, fabs (expected_l) * 0.00002));
      if (i >= 7 && i <= 9) { CHECK (lab[0] >= previous_knee); previous_knee = lab[0]; }
    }
}

static void
check_lcms (const GlimsLabTransform *transform)
{
  cmsContext context = cmsCreateContext (NULL, NULL);
  cmsHPROFILE rgb = NULL, lab = NULL;
  cmsToneCurve *linear = NULL;
  cmsHTRANSFORM oracle = NULL;
  bool ready = context != NULL;
  if (ready)
    {
      rgb = cmsCreate_sRGBProfileTHR (context);
      lab = cmsCreateLab4ProfileTHR (context, NULL);
      linear = cmsBuildGamma (context, 1.0);
      ready = rgb && lab && linear;
    }
  if (ready)
    ready = cmsWriteTag (rgb, cmsSigRedTRCTag, linear) &&
            cmsWriteTag (rgb, cmsSigGreenTRCTag, linear) &&
            cmsWriteTag (rgb, cmsSigBlueTRCTag, linear);
  if (ready)
    oracle = cmsCreateTransformTHR (context, rgb, TYPE_RGB_DBL, lab, TYPE_Lab_DBL,
                                   INTENT_RELATIVE_COLORIMETRIC,
                                   cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE);
  CHECK (ready && oracle != NULL);
  if (oracle)
    {
      const float levels[] = {0, 0.0031308f, 0.18f, 0.5f, 1};
      double maximum_error = 0;
      for (size_t r = 0; r < 5; r++)
        for (size_t g = 0; g < 5; g++)
          for (size_t b = 0; b < 5; b++)
            {
              const float input[3] = {levels[r], levels[g], levels[b]};
              const double physical[3] = {input[0], input[1], input[2]};
              double expected[3]; float actual[3] = {NAN, NAN, NAN};
              cmsDoTransform (oracle, physical, expected, 1);
              CHECK (glims_lab_transform_from_linear_rgb (transform, input, 1, actual));
              for (size_t c = 0; c < 3; c++)
                {
                  const double error = fabs ((double) actual[c] - expected[c]);
                  if (isfinite (error) && error > maximum_error) maximum_error = error;
                  CHECK (near (actual[c], expected[c], lcms_tolerance));
                }
            }
      printf ("ordinary LCMS maximum absolute Lab difference %.9g; fixed tolerance %.9g\n",
              maximum_error, lcms_tolerance);
    }
  if (oracle) cmsDeleteTransform (oracle);
  if (linear) cmsFreeToneCurve (linear);
  if (lab) cmsCloseProfile (lab);
  if (rgb) cmsCloseProfile (rgb);
  if (context) cmsDeleteContext (context);
}

static void
check_extended_and_roundtrip (const GlimsLabTransform *transform)
{
  const float inputs[][3] = {
    {-0.01f, -0.01f, -0.01f}, {-0.125f, 0.25f, 1.5f},
    {4, 0.25f, 0.5f}, {0.2f, -1, 0.4f}, {-4, 0.5f, 8},
    {0, 0, 0}, {1, 1, 1}, {0.0031308f, 0.18f, 0.5f}, {0.05f, 0.6f, 0.9f}
  };
  bool negative_l = false, extended_l = false, extended_chroma = false;
  for (size_t i = 0; i < sizeof inputs / sizeof *inputs; i++)
    {
      float lab[3] = {NAN, NAN, NAN}, rgba[4] = {NAN, NAN, NAN, NAN};
      double expected[3]; reference_lab (inputs[i], expected);
      CHECK (glims_lab_transform_from_linear_rgb (transform, inputs[i], 1, lab));
      for (size_t c = 0; c < 3; c++)
        CHECK (near (lab[c], expected[c], anchor_tolerance + 0.0005 * fabs (expected[c])));
      negative_l |= lab[0] < 0; extended_l |= lab[0] > 100;
      extended_chroma |= fabs (lab[1]) > 128 || fabs (lab[2]) > 128;
      CHECK (glims_lab_transform_pixels (transform, lab, 1, rgba));
      CHECK (rgba[3] == 1.0f);
      for (size_t c = 0; c < 3; c++)
        CHECK (near (rgba[c], inputs[i][c], rgb_roundtrip_tolerance * fmax (1, fabs (inputs[i][c]))));
    }
  CHECK (negative_l && extended_l && extended_chroma);

  const float physical[][3] = {{0, 0, 0}, {8, 0, 0}, {50, -64, 127}, {110, 160, -160}, {-5, 0, 0}};
  for (size_t i = 0; i < sizeof physical / sizeof *physical; i++)
    {
      float rgba[4] = {NAN, NAN, NAN, NAN}, back[3] = {NAN, NAN, NAN};
      CHECK (glims_lab_transform_pixels (transform, physical[i], 1, rgba));
      CHECK (glims_lab_transform_from_linear_rgb (transform, rgba, 1, back));
      for (size_t c = 0; c < 3; c++) CHECK (near (back[c], physical[i][c], lab_roundtrip_tolerance));
    }

  /* A finite source is not itself grounds for refusal. Positive FLT_MAX
   * remains representable after CIE's cube root; its output must exceed the
   * nominal Lab range. This does not require reverse RGB rounding at FLT_MAX. */
  const float huge[3] = {FLT_MAX, FLT_MAX, FLT_MAX};
  float result[3] = {NAN, NAN, NAN};
  const double expected_l = 116.0 * cbrt ((double) FLT_MAX) - 16.0;
  CHECK (glims_lab_transform_from_linear_rgb (transform, huge, 1, result));
  CHECK (near (result[0], expected_l, expected_l * 0.00002));
  CHECK (isfinite (result[1]) && isfinite (result[2]) && result[0] > 100);
}

static void
check_atomicity_and_memory (const GlimsLabTransform *transform)
{
  const float valid[9] = {0.18f, 0.18f, 0.18f, 1, 0, 0, 0, 0, 1};
  float input[9]; unsigned char output[sizeof valid + 8], before[sizeof output];
  memset (before, 0xa5, sizeof before);
  const float invalid[] = {NAN, INFINITY, -INFINITY, -FLT_MAX};
  for (size_t bad = 0; bad < sizeof invalid / sizeof *invalid; bad++)
    for (size_t c = 0; c < 3; c++)
      {
        memcpy (input, valid, sizeof input); input[6 + c] = invalid[bad];
        memcpy (output, before, sizeof output);
        CHECK (!glims_lab_transform_from_linear_rgb (transform, input, 3, output + 3));
        CHECK (memcmp (output, before, sizeof output) == 0);
      }
  memcpy (input, valid, sizeof input);
  CHECK (glims_lab_transform_from_linear_rgb (transform, NULL, 0, NULL));
  CHECK (glims_lab_transform_from_linear_rgb (transform, output, 0, output));
  CHECK (!glims_lab_transform_from_linear_rgb (NULL, NULL, 0, NULL));
  CHECK (!glims_lab_transform_from_linear_rgb (NULL, input, 3, output));
  CHECK (!glims_lab_transform_from_linear_rgb (transform, NULL, 1, output));
  CHECK (!glims_lab_transform_from_linear_rgb (transform, input, 1, NULL));
  CHECK (!glims_lab_transform_from_linear_rgb (transform, input, 4097, output));
  CHECK (!glims_lab_transform_from_linear_rgb (transform, input, SIZE_MAX, output));
  CHECK (memcmp (output, before, sizeof output) == 0);
  CHECK (memcmp (input, valid, sizeof input) == 0);

  unsigned char src[sizeof valid + 2], dst[sizeof valid + 8], src_copy[sizeof src];
  float aligned[9], unaligned[9];
  memset (src, 0x5a, sizeof src); memcpy (src + 1, valid, sizeof valid); memcpy (src_copy, src, sizeof src);
  memset (dst, 0xa5, sizeof dst);
  CHECK (glims_lab_transform_from_linear_rgb (transform, valid, 3, aligned));
  const double expected_row[9] = {49.4961076101, 0, 0,
                                 54.2917337686, 80.8124553180, 69.8850403235,
                                 29.5675728636, 68.2986532657, -112.0294299129};
  for (size_t i = 0; i < 9; i++) CHECK (near (aligned[i], expected_row[i], anchor_tolerance));
  CHECK (glims_lab_transform_from_linear_rgb (transform, src + 1, 3, dst + 3));
  memcpy (unaligned, dst + 3, sizeof unaligned);
  CHECK (memcmp (unaligned, aligned, sizeof aligned) == 0);
  CHECK (filled (dst, 3, 0xa5) && filled (dst + 3 + sizeof valid, 5, 0xa5));
  CHECK (memcmp (src, src_copy, sizeof src) == 0);

  const int offsets[] = {-11, -1, 0, 1, 11};
  unsigned char pool[64], snapshot[sizeof pool];
  for (size_t i = 0; i < sizeof offsets / sizeof *offsets; i++)
    {
      memset (pool, 0xa5, sizeof pool); memcpy (pool + 24, valid, 3 * sizeof (float));
      memcpy (snapshot, pool, sizeof pool);
      CHECK (!glims_lab_transform_from_linear_rgb (transform, pool + 24, 1, pool + 24 + offsets[i]));
      CHECK (memcmp (pool, snapshot, sizeof pool) == 0);
    }
  /* Merely adjacent byte ranges are disjoint, even in the same allocation. */
  for (int direction = -1; direction <= 1; direction += 2)
    {
      memset (pool, 0xa5, sizeof pool); memcpy (pool + 24, valid, 3 * sizeof (float));
      unsigned char *destination = pool + 24 + direction * (int) (3 * sizeof (float));
      CHECK (glims_lab_transform_from_linear_rgb (transform, pool + 24, 1, destination));
      CHECK (memcmp (destination, aligned, 3 * sizeof (float)) == 0);
      CHECK (memcmp (pool + 24, valid, 3 * sizeof (float)) == 0);
      CHECK (filled (pool, 12, 0xa5) && filled (pool + 48, 16, 0xa5));
    }

  static float large[4096 * 3];
  static unsigned char large_output[sizeof large + 8];
  const double expected_l = 49.4961076101;
  for (size_t i = 0; i < sizeof large / sizeof *large; i++) large[i] = 0.18f;
  memset (large_output, 0xa5, sizeof large_output);
  CHECK (glims_lab_transform_from_linear_rgb (transform, large, 4096, large_output + 3));
  bool all_correct = true;
  for (size_t i = 0; i < 4096; i++)
    {
      float pixel[3]; memcpy (pixel, large_output + 3 + i * sizeof pixel, sizeof pixel);
      all_correct &= near (pixel[0], expected_l, 0.0002) && near (pixel[1], 0, 0.003) && near (pixel[2], 0, 0.003);
    }
  CHECK (all_correct);
  CHECK (filled (large_output, 3, 0xa5) && filled (large_output + 3 + sizeof large, 5, 0xa5));
  large[4096 * 3 - 1] = INFINITY;
  memset (large_output, 0xa5, sizeof large_output);
  CHECK (!glims_lab_transform_from_linear_rgb (transform, large, 4096, large_output + 3));
  CHECK (filled (large_output, sizeof large_output, 0xa5));
}

int
main (void)
{
  GlimsLabTransform *transform = glims_lab_transform_new ();
  CHECK (transform != NULL);
  if (!transform) return 1;
  check_anchors (transform);
  check_lcms (transform);
  check_extended_and_roundtrip (transform);
  check_atomicity_and_memory (transform);
  glims_lab_transform_free (transform);
  printf ("Lab RGB transform: %u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
