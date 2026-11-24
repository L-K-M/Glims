/* Standalone harness for the pure Select > Color Range kernel. Expected
 * values are hand-computed literals from docs/color-range.md, not
 * re-derivations through the implementation. */
#include "color-range-math.h"

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

static GlimsCRSettings
settings (uint32_t mode, double fuzziness, uint32_t invert)
{
  GlimsCRSettings value;

  memset (&value, 0, sizeof value);
  value.mode = mode;
  value.fuzziness = fuzziness;
  value.invert = invert;
  value.sample_count = 0;
  value.samples = NULL;
  return value;
}

static void
test_validate (void)
{
  GlimsCRSample samples[GLIMS_CR_MAX_SAMPLES + 1];
  GlimsCRSettings value = settings (GLIMS_CR_SAMPLED, 40, 0);

  CHECK (glims_cr_settings_valid (&value) == false,
         "validate: Sampled Colors without a sample is refused");

  value.sample_count = 1;
  value.samples = samples;
  samples[0] = (GlimsCRSample) { 0.5, 0.5, 0.5, 0 };
  CHECK (glims_cr_settings_valid (&value), "validate: one add sample is valid");

  samples[0].subtract = 1;
  CHECK (! glims_cr_settings_valid (&value),
         "validate: Sampled Colors without an add sample is refused");

  samples[0].subtract = 0;
  value.fuzziness = 200;
  CHECK (glims_cr_settings_valid (&value), "validate: fuzziness 200 is valid");
  value.fuzziness = 201;
  CHECK (! glims_cr_settings_valid (&value), "validate: fuzziness 201 is refused");
  value.fuzziness = NAN;
  CHECK (! glims_cr_settings_valid (&value), "validate: NaN fuzziness is refused");
  value.fuzziness = 0;
  value.invert = 1;
  CHECK (glims_cr_settings_valid (&value), "validate: fuzziness 0 and invert 1 are valid");
  value.invert = 2;
  CHECK (! glims_cr_settings_valid (&value), "validate: invert 2 is refused");
  value.invert = 0;
  value.mode = 0;
  CHECK (! glims_cr_settings_valid (&value), "validate: an unknown mode is refused");
  value.mode = GLIMS_CR_REDS;
  CHECK (! glims_cr_settings_valid (&value),
         "validate: a fixed range with a sample is refused");
  value.sample_count = 0;
  value.samples = NULL;
  CHECK (glims_cr_settings_valid (&value), "validate: a fixed range without samples is valid");
  for (size_t i = 0; i < GLIMS_CR_MAX_SAMPLES + 1; i++)
    samples[i] = (GlimsCRSample) { 0, 0, 0, 0 };
  value.mode = GLIMS_CR_SAMPLED;
  value.sample_count = GLIMS_CR_MAX_SAMPLES + 1;
  value.samples = samples;
  CHECK (! glims_cr_settings_valid (&value), "validate: 65 samples are refused");
  value.sample_count = GLIMS_CR_MAX_SAMPLES;
  CHECK (glims_cr_settings_valid (&value), "validate: 64 add samples are valid");
  samples[63].red = INFINITY;
  CHECK (! glims_cr_settings_valid (&value), "validate: an infinite sample is refused");
  CHECK (! glims_cr_settings_valid (NULL), "validate: NULL is refused");
}

static void
test_sampled_ramp (void)
{
  GlimsCRSample samples[3];
  GlimsCRSettings value = settings (GLIMS_CR_SAMPLED, 100, 0);

  /* tolerance t = 100/200 = 0.5: d = t is 1, d = 1.25 t is 0.5, d >= 1.5 t
   * is 0. All distances stay inside the clamped [0,1] unit cube. */
  samples[0] = (GlimsCRSample) { 0.0, 0.0, 0.0, 0 };
  value.sample_count = 1;
  value.samples = samples;
  CHECK (glims_cr_weight ((const float[]) { 0.5f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 1.0f,
         "sampled: d = t has full weight");
  CHECK (glims_cr_weight ((const float[]) { 0.625f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 0.5f,
         "sampled: d = 1.25 t has half weight");
  CHECK (glims_cr_weight ((const float[]) { 0.75f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 0.0f,
         "sampled: d = 1.5 t has no weight");
  CHECK (glims_cr_weight ((const float[]) { 1.0f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 0.0f,
         "sampled: past the ramp has no weight");

  /* Fuzziness 0 keeps the 1/512 floor, so an exact match still selects. */
  value.fuzziness = 0;
  CHECK (glims_cr_weight ((const float[]) { 0.0f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 1.0f,
         "sampled: F = 0 matches an exact color");
  CHECK (glims_cr_weight ((const float[]) { 0.004f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 0.0f,
         "sampled: F = 0 rejects a color beyond 1.5/512");

  /* Two adds union by their maximum: the first only reaches 0.6 here, the
   * second is well inside its own ramp. */
  samples[0] = (GlimsCRSample) { 0.0, 0.0, 0.0, 0 };
  samples[1] = (GlimsCRSample) { 0.8, 0.8, 0.8, 0 };
  value.fuzziness = 100;
  value.sample_count = 2;
  CHECK (glims_cr_weight ((const float[]) { 0.6f, 0.6f, 0.6f, 1.0f }, &value, NULL) == 1.0f,
         "sampled: a second add raises the union to full weight");

  /* A subtract sample removes only its own contribution. */
  samples[2] = (GlimsCRSample) { 0.0f, 0.0f, 0.0f, 1 };
  value.sample_count = 3;
  CHECK (glims_cr_weight ((const float[]) { 0.0f, 0.0f, 0.0f, 1.0f }, &value, NULL) == 0.0f,
         "sampled: a subtract sample cancels the matching add");
  CHECK (glims_cr_weight ((const float[]) { 1.0f, 1.0f, 1.0f, 1.0f }, &value, NULL) == 1.0f,
         "sampled: the subtract sample does not reach the other add");
}

static void
test_fixed_hue (void)
{
  GlimsCRSettings reds = settings (GLIMS_CR_REDS, 40, 0);
  GlimsCRSettings yellows = settings (GLIMS_CR_YELLOWS, 40, 0);
  GlimsCRSettings magentas = settings (GLIMS_CR_MAGENTAS, 40, 0);

  /* HSV 350 degrees: 10 degrees from Reds across the 0/360 seam. */
  CHECK (glims_cr_weight ((const float[]) { 1.0f, 0.0f, 1.0f / 6.0f, 1.0f }, &reds, NULL) == 1.0f,
         "hue: 350 degrees is 10 from Reds");
  /* HSV 60 degrees. */
  CHECK (glims_cr_weight ((const float[]) { 1.0f, 1.0f, 0.0f, 1.0f }, &yellows, NULL) == 1.0f,
         "hue: 60 degrees is the Yellows center");
  /* HSV 300 degrees. */
  CHECK (glims_cr_weight ((const float[]) { 1.0f, 0.0f, 1.0f, 1.0f }, &magentas, NULL) == 1.0f,
         "hue: 300 degrees is the Magentas center");
  /* 45 degrees from Yellows is outside the sector. HSV 15 degrees is
   * (1, 0.25, 0). */
  CHECK (glims_cr_weight ((const float[]) { 1.0f, 0.25f, 0.0f, 1.0f }, &yellows, NULL) == 0.0f,
         "hue: 45 degrees from Yellows is outside the sector");
  /* Every hue range ignores a gray. */
  for (uint32_t mode = GLIMS_CR_REDS; mode <= GLIMS_CR_MAGENTAS; mode++)
    {
      GlimsCRSettings value = settings (mode, 40, 0);
      char text[64];

      snprintf (text, sizeof text, "hue: mode %u ignores a gray", mode);
      CHECK (glims_cr_weight ((const float[]) { 0.5f, 0.5f, 0.5f, 1.0f }, &value, NULL) == 0.0f,
             text);
    }
  /* A nearly gray red sits below the saturation gate. */
  CHECK (glims_cr_weight ((const float[]) { 0.51f, 0.5f, 0.5f, 1.0f }, &reds, NULL) == 0.0f,
         "hue: a barely saturated color stays outside the gate");
}

static void
test_fixed_luma (void)
{
  GlimsCRSettings shadows = settings (GLIMS_CR_SHADOWS, 40, 0);
  GlimsCRSettings highlights = settings (GLIMS_CR_HIGHLIGHTS, 40, 0);
  GlimsCRSettings midtones = settings (GLIMS_CR_MIDTONES, 40, 0);
  float gray;

  gray = 0.25f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &shadows, NULL) == 1.0f,
         "luma: Shadows keeps L = 0.25");
  gray = 0.5f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &shadows, NULL) == 0.0f,
         "luma: Shadows drops L = 0.5");
  gray = 0.375f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &shadows, NULL) == 0.5f,
         "luma: Shadows halves at L = 0.375");

  gray = 0.75f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &highlights, NULL) == 1.0f,
         "luma: Highlights keeps L = 0.75");
  gray = 0.5f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &highlights, NULL) == 0.0f,
         "luma: Highlights drops L = 0.5");
  gray = 0.625f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &highlights, NULL) == 0.5f,
         "luma: Highlights halves at L = 0.625");

  gray = 0.125f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &midtones, NULL) == 0.0f,
         "luma: Midtones drops L = 0.125");
  gray = 0.875f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &midtones, NULL) == 0.0f,
         "luma: Midtones drops L = 0.875");
  gray = 0.375f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &midtones, NULL) == 1.0f,
         "luma: Midtones keeps L = 0.375");
  gray = 0.625f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &midtones, NULL) == 1.0f,
         "luma: Midtones keeps L = 0.625");
  gray = 0.25f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &midtones, NULL) == 0.5f,
         "luma: Midtones halves at L = 0.25");
  gray = 0.75f;
  CHECK (glims_cr_weight ((const float[]) { gray, gray, gray, 1.0f }, &midtones, NULL) == 0.5f,
         "luma: Midtones halves at L = 0.75");
}

static void
test_transparency_invert_selection (void)
{
  GlimsCRSample sample = { 0.0, 0.0, 0.0, 0 };
  GlimsCRSettings value = settings (GLIMS_CR_SAMPLED, 100, 0);
  float matching[4] = { 0.0f, 0.0f, 0.0f, 1.0f };

  value.sample_count = 1;
  value.samples = &sample;

  matching[3] = 0.0f;
  CHECK (glims_cr_weight (matching, &value, NULL) == 0.0f,
         "transparency: a fully transparent pixel has no weight");
  value.invert = 1;
  CHECK (glims_cr_weight (matching, &value, NULL) == 1.0f,
         "transparency: Invert applies after the transparency rule");
  value.invert = 0;

  matching[3] = 1.0f;
  CHECK (glims_cr_weight (matching, &value, NULL) == 1.0f,
         "invert: a matching color starts at full weight");
  value.invert = 1;
  CHECK (glims_cr_weight (matching, &value, NULL) == 0.0f,
         "invert: the matching color is inverted away");
  matching[0] = 1.0f;
  CHECK (glims_cr_weight (matching, &value, NULL) == 1.0f,
         "invert: a far color becomes selected");

  matching[0] = 0.0f;
  matching[3] = 1.0f;
  value.invert = 0;
  CHECK (glims_cr_weight (matching, &value, (const float[]) { 0.5f }) == 0.5f,
         "selection: a soft selection scales the weight");
  CHECK (glims_cr_weight (matching, &value, (const float[]) { 0.0f }) == 0.0f,
         "selection: an unselected pixel contributes nothing");

  /* A NaN channel clamps to 0 like a negative one, in every mode. */
  matching[0] = NAN;
  CHECK (glims_cr_weight (matching, &value, NULL) == 1.0f,
         "nan: a NaN channel matches a black sample as 0 does");
  value = settings (GLIMS_CR_REDS, 40, 0);
  CHECK (glims_cr_weight ((const float[]) { 1.0f, NAN, NAN, 1.0f }, &value, NULL) == 1.0f,
         "nan: NaN green and blue read as pure red in a hue range");
  value = settings (GLIMS_CR_SHADOWS, 40, 0);
  CHECK (glims_cr_weight ((const float[]) { NAN, NAN, NAN, 1.0f }, &value, NULL) == 1.0f,
         "nan: an all-NaN pixel reads as black in a luma band");
  CHECK (glims_cr_weight ((const float[]) { 0.0f, 0.0f, 0.0f, NAN }, &value, NULL) == 0.0f,
         "nan: a NaN alpha counts as transparent");
}

static void
test_apply_batch (void)
{
  GlimsCRSample sample = { 0.0, 0.0, 0.0, 0 };
  GlimsCRSettings value = settings (GLIMS_CR_SAMPLED, 100, 0);
  const float pixels[8] = {
    0.0f, 0.0f, 0.0f, 1.0f,
    1.0f, 1.0f, 1.0f, 1.0f,
  };
  const float selection[2] = { 1.0f, 0.5f };
  float out[2];

  value.sample_count = 1;
  value.samples = &sample;
  glims_cr_apply (&value, pixels, 2, selection, out);
  CHECK (out[0] == 1.0f && out[1] == 0.0f,
         "batch: the selection limit applies per pixel");
}

int
main (void)
{
  test_validate ();
  test_sampled_ramp ();
  test_fixed_hue ();
  test_fixed_luma ();
  test_transparency_invert_selection ();
  test_apply_batch ();

  if (failures)
    {
      printf ("FAILED: %d color-range-math check(s)\n", failures);
      return 1;
    }
  printf ("PASSED: color-range-math checks\n");
  return 0;
}
