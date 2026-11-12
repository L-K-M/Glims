/* Standalone native checks. The vendor ICC argument is read in place, never
 * copied into the repository. The independent oracle feeds CMYK percentages
 * as doubles to LittleCMS with GIMP's separately constructed linear profile. */
#include "cmyk-transform.h"
#include <cairo.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <babl/babl.h>
#include <libgimpbase/gimpbase.h>
#include <libgimpcolor/gimpcolor.h>
#include <lcms2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c, message) do { gboolean ok = !!(c); checks++; failures += !ok; \
  printf("%s %s\n", ok ? "ok" : "FAIL", message); } while (0)
#define NEED(c) do { if (!(c)) { fprintf(stderr, "Fixture failure at %d\n", __LINE__); exit(2); } } while (0)

static void
reject (const guint8 *bytes, gsize size, const char *label)
{
  GError *error = NULL;
  GlimsCmykTransform *transform = glims_cmyk_transform_new (bytes, size, &error);
  CHECK (!transform && error, label);
  glims_cmyk_transform_free (transform);
  g_clear_error (&error);
}

static guint8 *
profile_bytes (cmsHPROFILE profile, cmsUInt32Number *size)
{
  NEED (profile && cmsSaveProfileToMem (profile, NULL, size));
  guint8 *bytes = g_malloc (*size);
  NEED (cmsSaveProfileToMem (profile, bytes, size));
  return bytes;
}

int main (int argc, char **argv)
{
  NEED (argc == 2);
  babl_init ();
  GError *error = NULL;
  gchar *icc = NULL;
  gsize size = 0;
  NEED (g_file_get_contents (argv[1], &icc, &size, &error));
  NEED (size >= 128 && size <= GLIMS_CMYK_ICC_MAX_BYTES);
  GlimsCmykTransform *transform = glims_cmyk_transform_new ((guint8 *) icc, size, &error);
  if (error) fprintf (stderr, "%s\n", error->message);
  NEED (transform && !error);
  CHECK (transform != NULL, "real CMYK profile constructs a private transform");

  cmsHPROFILE source = cmsOpenProfileFromMem (icc, (cmsUInt32Number) size);
  GimpColorProfile *destination = gimp_color_profile_new_rgb_srgb_linear ();
  NEED (source && destination);
  cmsHTRANSFORM oracle = cmsCreateTransform (source, TYPE_CMYK_DBL,
    gimp_color_profile_get_lcms_profile (destination), TYPE_RGB_DBL,
    INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_BLACKPOINTCOMPENSATION | cmsFLAGS_NOCACHE);
  NEED (oracle);
  /* The implementation must retain its own bytes after the caller releases
   * or changes them. The separately opened oracle has already parsed them. */
  memset (icc, 0xa5, size);
  g_free (icc);

  enum { N = GLIMS_CMYK_TRANSFORM_MAX_PIXELS };
  gfloat *input = g_new (gfloat, N * 4), *output = g_new (gfloat, N * 4);
  gfloat *original = g_new (gfloat, N * 4), *in_place = g_new (gfloat, N * 4);
  const gfloat patches[][4] = {
    {1,1,1,1}, {0,1,1,1}, {1,0,1,1}, {1,1,0,1}, {1,1,1,0},
    {0,0,1,1}, {.5f,1,1,1}, {1,1,1,.5f}, {.77f,.59f,.33f,.81f}, {0,0,0,0}
  };
  guint32 random = 0x1b9d3a57;
  for (gsize i = 0; i < N * 4; i++)
    { random = random * 1664525u + 1013904223u; input[i] = (random >> 8) / 16777215.0f; }
  memcpy (input, patches, sizeof patches);
  memcpy (original, input, N * 4 * sizeof *input);
  memcpy (in_place, input, N * 4 * sizeof *input);
  CHECK (glims_cmyk_transform_pixels (transform, input, N, output, &error) && !error,
         "4096 samples cross multiple bounded scratch chunks");
  double maximum = 0;
  gboolean finite = TRUE, opaque = TRUE;
  for (gsize i = 0; i < N; i++)
    {
      double percent[4], expected[3];
      for (guint c = 0; c < 4; c++) percent[c] = 100.0 * (1.0 - (double) input[i * 4 + c]);
      cmsDoTransform (oracle, percent, expected, 1);
      for (guint c = 0; c < 3; c++)
        {
          finite &= isfinite (output[i * 4 + c]) && isfinite (expected[c]);
          maximum = MAX (maximum, fabs (output[i * 4 + c] - expected[c]));
        }
      opaque &= output[i * 4 + 3] == 1.0f;
    }
  printf ("maximum linear-sRGB error versus independent double oracle: %.9g\n", maximum);
  CHECK (finite && maximum < 0.0002, "CMYK units/order and linear RGB agree with the independent oracle");
  CHECK (opaque, "opaque alpha is exactly one for every sample");
  CHECK (!memcmp (input, original, N * 4 * sizeof *input), "conversion preserves authoritative input samples");
  CHECK (glims_cmyk_transform_pixels (transform, in_place, N, in_place, &error) &&
         !memcmp (in_place, output, N * 4 * sizeof *output), "in-place output agrees across scratch chunk boundaries");
  CHECK (glims_cmyk_transform_pixels (transform, NULL, 0, NULL, &error) && !error,
         "zero samples require no buffer");

  const gfloat bad[] = { NAN, INFINITY, -INFINITY, -0.001f, 1.001f };
  for (guint i = 0; i < G_N_ELEMENTS (bad); i++)
    {
      memcpy (input, original, N * 4 * sizeof *input);
      input[N * 4 - 1] = bad[i];
      memset (output, 0x39, N * 4 * sizeof *output);
      memcpy (in_place, output, N * 4 * sizeof *output);
      CHECK (!glims_cmyk_transform_pixels (transform, input, N, output, &error) && error &&
             !memcmp (output, in_place, N * 4 * sizeof *output),
             "invalid final sample refuses before changing any destination byte");
      g_clear_error (&error);
    }
  CHECK (!glims_cmyk_transform_pixels (transform, NULL, 1, output, &error) && error,
         "missing input refuses"); g_clear_error (&error);
  CHECK (!glims_cmyk_transform_pixels (transform, original, 1, NULL, &error) && error,
         "missing output refuses"); g_clear_error (&error);
  CHECK (!glims_cmyk_transform_pixels (transform, original, G_MAXSIZE, output, &error) && error,
         "oversized counts refuse before arithmetic or reads"); g_clear_error (&error);
  CHECK (!glims_cmyk_transform_pixels (NULL, original, 1, output, &error) && error,
         "missing transform refuses"); g_clear_error (&error);

  reject (NULL, 128, "missing profile refuses");
  guint8 short_profile[128] = {0};
  reject (short_profile, 127, "short profile refuses");
  reject (short_profile, GLIMS_CMYK_ICC_MAX_BYTES + 1, "oversized profile refuses before reading bytes");
  reject (short_profile, sizeof short_profile, "invalid signature and declared size refuse");
  cmsHPROFILE rgb = cmsCreate_sRGBProfile ();
  cmsUInt32Number rgb_size;
  guint8 *rgb_bytes = profile_bytes (rgb, &rgb_size);
  reject (rgb_bytes, rgb_size, "RGB profile cannot masquerade as CMYK");
  reject (rgb_bytes, rgb_size - 1, "truncated profile refuses");
  g_free (rgb_bytes); cmsCloseProfile (rgb);
  cmsHPROFILE link = cmsCreateInkLimitingDeviceLink (cmsSigCmykData, 300);
  cmsUInt32Number link_size;
  guint8 *link_bytes = profile_bytes (link, &link_size);
  reject (link_bytes, link_size, "CMYK device-link profile refuses before preview conversion");
  g_free (link_bytes); cmsCloseProfile (link);

  glims_cmyk_transform_free (transform);
  glims_cmyk_transform_free (NULL);
  cmsDeleteTransform (oracle); cmsCloseProfile (source); g_object_unref (destination);
  g_free (input); g_free (original); g_free (output); g_free (in_place);
  babl_exit ();
  printf ("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
