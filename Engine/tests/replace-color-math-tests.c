/* Standalone harness for the pure Replace Color kernel. Expected values are
 * hand-computed literals from docs/replace-color.md, not re-derivations
 * through the implementation. */
#include "replace-color-math.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(cond, text)                                                \
  do {                                                                   \
    const int ok_ = (cond);                                              \
    printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text);                     \
    if (!ok_) failures++;                                                \
  } while (0)

static int
close_to (float actual, float wanted)
{
  return fabsf (actual - wanted) <= 1e-6f;
}

static GlimsReplaceColorSettings
settings (void)
{
  GlimsReplaceColorSettings value;

  memset (&value, 0, sizeof value);
  value.fuzziness = 40.0;
  return value;
}

static void
test_validate (void)
{
  GlimsReplaceColorSettings value = settings ();
  GlimsCRSample samples[GLIMS_REPLACE_COLOR_MAX_SAMPLES + 1];

  CHECK (glims_replace_color_settings_valid (&value),
         "validate: the default list with no sample is valid");
  CHECK (! glims_replace_color_settings_valid (NULL), "validate: NULL is refused");

  value.fuzziness = 200.0;
  CHECK (glims_replace_color_settings_valid (&value), "validate: fuzziness 200 is valid");
  value.fuzziness = 200.0001;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: fuzziness 200.0001 is refused");
  value.fuzziness = NAN;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: NaN fuzziness is refused");
  value.fuzziness = 40.0;

  value.hue = 180.0;
  CHECK (glims_replace_color_settings_valid (&value), "validate: hue 180 is valid");
  value.hue = -180.0;
  CHECK (glims_replace_color_settings_valid (&value), "validate: hue -180 is valid");
  value.hue = 180.0001;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: hue 180.0001 is refused");
  value.hue = 0.0;

  value.saturation = 100.0;
  CHECK (glims_replace_color_settings_valid (&value), "validate: saturation 100 is valid");
  value.saturation = -100.0001;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: saturation -100.0001 is refused");
  value.saturation = 0.0;

  value.lightness = -100.0;
  CHECK (glims_replace_color_settings_valid (&value), "validate: lightness -100 is valid");
  value.lightness = 100.0001;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: lightness 100.0001 is refused");
  value.lightness = 0.0;

  for (size_t i = 0; i < GLIMS_REPLACE_COLOR_MAX_SAMPLES + 1; i++)
    samples[i] = (GlimsCRSample) { 0.5, 0.5, 0.5, 0 };
  value.sample_count = GLIMS_REPLACE_COLOR_MAX_SAMPLES;
  memcpy (value.samples, samples, sizeof value.samples);
  CHECK (glims_replace_color_settings_valid (&value), "validate: eight samples are valid");

  value.sample_count = GLIMS_REPLACE_COLOR_MAX_SAMPLES + 1;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: nine samples are refused");
  value.sample_count = 1;
  value.samples[0].red = INFINITY;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: an infinite sample is refused");
  value.samples[0].red = 0.5;
  value.samples[0].subtract = 2;
  CHECK (! glims_replace_color_settings_valid (&value), "validate: subtract 2 is refused");
}

static void
test_zero_weight (void)
{
  GlimsReplaceColorSettings value = settings ();
  const float pixel[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
  float out[4];

  value.hue = 180.0;
  glims_replace_color_apply (&value, pixel, out, 1);
  CHECK (out[0] == pixel[0] && out[1] == pixel[1] && out[2] == pixel[2] &&
         out[3] == pixel[3],
         "zero weight: no sample leaves the pixel unchanged");

  value.sample_count = 1;
  value.samples[0] = (GlimsCRSample) { 0.0f, 1.0f, 0.0f, 0 };
  value.fuzziness = 0.0;
  glims_replace_color_apply (&value, pixel, out, 1);
  CHECK (out[0] == pixel[0] && out[1] == pixel[1] && out[2] == pixel[2],
         "zero weight: a color outside the ramp leaves the pixel unchanged");
}

static void
test_full_weight (void)
{
  GlimsReplaceColorSettings value = settings ();
  const float red[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
  float out[4];

  value.fuzziness = 0.0;
  value.sample_count = 1;
  value.samples[0] = (GlimsCRSample) { 1.0f, 0.0f, 0.0f, 0 };

  value.hue = 180.0;
  glims_replace_color_apply (&value, red, out, 1);
  CHECK (close_to (out[0], 0.0f) && close_to (out[1], 1.0f) &&
         close_to (out[2], 1.0f) && out[3] == 1.0f,
         "full weight: hue 180 turns pure red cyan");

  value.hue = 0.0;
  value.saturation = -100.0;
  glims_replace_color_apply (&value, red, out, 1);
  CHECK (close_to (out[0], 0.5f) && close_to (out[1], 0.5f) &&
         close_to (out[2], 0.5f) && out[3] == 1.0f,
         "full weight: saturation -100 turns pure red mid gray");

  value.saturation = 0.0;
  value.lightness = 100.0;
  glims_replace_color_apply (&value, red, out, 1);
  CHECK (close_to (out[0], 1.0f) && close_to (out[1], 1.0f) &&
         close_to (out[2], 1.0f),
         "full weight: lightness 100 turns pure red white");

  value.lightness = -100.0;
  glims_replace_color_apply (&value, red, out, 1);
  CHECK (close_to (out[0], 0.0f) && close_to (out[1], 0.0f) &&
         close_to (out[2], 0.0f),
         "full weight: lightness -100 turns pure red black");
}

static void
test_half_weight (void)
{
  GlimsReplaceColorSettings value = settings ();
  /* Fuzziness 100 gives t = 0.5; d = 0.625 is 1.25 t, so w = 0.5. */
  const float pixel[4] = { 0.625f, 0.0f, 0.0f, 1.0f };
  float out[4];

  value.fuzziness = 100.0;
  value.sample_count = 1;
  value.samples[0] = (GlimsCRSample) { 0.0f, 0.0f, 0.0f, 0 };
  value.hue = 180.0;
  glims_replace_color_apply (&value, pixel, out, 1);
  CHECK (close_to (out[0], 0.3125f) && close_to (out[1], 0.3125f) &&
         close_to (out[2], 0.3125f) && out[3] == 1.0f,
         "half weight: the blend lands halfway between input and mapping");
}

static void
test_pass_through (void)
{
  GlimsReplaceColorSettings value = settings ();
  float transparent[4] = { 1.0f, 0.0f, 0.0f, 0.0f };
  float nonfinite[4] = { NAN, 0.0f, 0.0f, 1.0f };
  float out[4];

  value.fuzziness = 0.0;
  value.sample_count = 1;
  value.samples[0] = (GlimsCRSample) { 1.0f, 0.0f, 0.0f, 0 };
  value.hue = 180.0;

  glims_replace_color_apply (&value, transparent, out, 1);
  CHECK (out[0] == transparent[0] && out[1] == transparent[1] &&
         out[2] == transparent[2] && out[3] == transparent[3],
         "pass through: a fully transparent pixel is unchanged");

  glims_replace_color_apply (&value, nonfinite, out, 1);
  CHECK (isnan (out[0]) && out[1] == nonfinite[1] && out[2] == nonfinite[2] &&
         out[3] == nonfinite[3],
         "pass through: a non-finite pixel is unchanged");

  nonfinite[0] = INFINITY;
  glims_replace_color_apply (&value, nonfinite, out, 1);
  CHECK (isinf (out[0]) && out[1] == nonfinite[1],
         "pass through: an infinite pixel is unchanged");
}

static void
test_subtract (void)
{
  GlimsReplaceColorSettings value = settings ();
  const float red[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
  float out[4];

  value.fuzziness = 0.0;
  value.sample_count = 2;
  value.samples[0] = (GlimsCRSample) { 1.0f, 0.0f, 0.0f, 0 };
  value.samples[1] = (GlimsCRSample) { 1.0f, 0.0f, 0.0f, 1 };
  value.hue = 180.0;
  glims_replace_color_apply (&value, red, out, 1);
  CHECK (out[0] == red[0] && out[1] == red[1] && out[2] == red[2],
         "subtract: a matching subtract sample cancels the add");

  value.samples[1] = (GlimsCRSample) { 0.0f, 1.0f, 0.0f, 1 };
  glims_replace_color_apply (&value, red, out, 1);
  CHECK (close_to (out[0], 0.0f) && close_to (out[1], 1.0f) &&
         close_to (out[2], 1.0f),
         "subtract: a far subtract sample does not reach the add");
}

static void
test_sample_count (void)
{
  GlimsReplaceColorSettings value = settings ();
  const float green[4] = { 0.0f, 1.0f, 0.0f, 1.0f };
  float out[4];

  value.fuzziness = 0.0;
  value.sample_count = 1;
  value.samples[0] = (GlimsCRSample) { 1.0f, 0.0f, 0.0f, 0 };
  value.samples[1] = (GlimsCRSample) { 0.0f, 1.0f, 0.0f, 0 };
  value.hue = 180.0;
  glims_replace_color_apply (&value, green, out, 1);
  CHECK (out[0] == green[0] && out[1] == green[1] && out[2] == green[2],
         "sample count: only the first entries are compared");
}

static void
test_in_place (void)
{
  GlimsReplaceColorSettings value = settings ();
  float pixel[8] = {
    1.0f, 0.0f, 0.0f, 1.0f,
    0.0f, 0.0f, 0.0f, 1.0f,
  };
  float wanted[8];

  value.fuzziness = 0.0;
  value.sample_count = 1;
  value.samples[0] = (GlimsCRSample) { 1.0f, 0.0f, 0.0f, 0 };
  value.hue = 180.0;
  memcpy (wanted, pixel, sizeof pixel);
  glims_replace_color_apply (&value, wanted, wanted, 2);
  glims_replace_color_apply (&value, pixel, pixel, 2);
  CHECK (memcmp (pixel, wanted, sizeof pixel) == 0,
         "in place: dst may equal src");
}

int
main (void)
{
  test_validate ();
  test_zero_weight ();
  test_full_weight ();
  test_half_weight ();
  test_pass_through ();
  test_subtract ();
  test_sample_count ();
  test_in_place ();

  if (failures)
    {
      printf ("FAILED: %d replace-color-math check(s)\n", failures);
      return 1;
    }
  printf ("PASSED: replace-color-math checks\n");
  return 0;
}
