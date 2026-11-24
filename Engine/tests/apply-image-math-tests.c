/* Standalone harness for the pure Apply Image / Calculations kernel.
 * Expected values are hand-computed literals from docs/apply-image.md,
 * not re-derivations through the implementation. */
#include "apply-image-math.h"

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

static bool
near (float actual, double expected)
{
  return fabsf (actual - (float) expected) <= 1e-6f;
}

static void
check_mode (const char *name, uint32_t mode, double scale, double offset,
            const float cb[3], const float cs[3], const double expected[3])
{
  float got[3];
  char  text[96];

  for (int c = 0; c < 3; c++)
    got[c] = glims_ai_blend (cb[c], cs[c], mode, scale, offset);
  snprintf (text, sizeof text, "%s: pair blends to the spec values", name);
  CHECK (near (got[0], expected[0]) && near (got[1], expected[1]) &&
         near (got[2], expected[2]), text);
}

static void
test_validate (void)
{
  GlimsAIMath math = { GLIMS_BLEND_NORMAL, 1.0, 1.0, 0.0, 0, 0 };

  CHECK (glims_ai_settings_valid (&math), "validate: defaults are valid");
  CHECK (! glims_ai_settings_valid (NULL), "validate: NULL is refused");

  math.opacity = 0.0;
  CHECK (! glims_ai_settings_valid (&math), "validate: opacity 0 is refused");
  math.opacity = 1.0001;
  CHECK (! glims_ai_settings_valid (&math), "validate: opacity above 1 is refused");
  math.opacity = NAN;
  CHECK (! glims_ai_settings_valid (&math), "validate: NaN opacity is refused");
  math.opacity = 1.0;

  math.scale = 0.99;
  CHECK (! glims_ai_settings_valid (&math), "validate: scale below 1 is refused");
  math.scale = 2.01;
  CHECK (! glims_ai_settings_valid (&math), "validate: scale above 2 is refused");
  math.scale = INFINITY;
  CHECK (! glims_ai_settings_valid (&math), "validate: infinite scale is refused");
  math.scale = 2.0;

  math.offset = -1.01;
  CHECK (! glims_ai_settings_valid (&math), "validate: offset below -1 is refused");
  math.offset = 1.01;
  CHECK (! glims_ai_settings_valid (&math), "validate: offset above 1 is refused");
  math.offset = NAN;
  CHECK (! glims_ai_settings_valid (&math), "validate: NaN offset is refused");
  math.offset = 0.0;

  math.mode = GLIMS_BLEND_SUBTRACT + 1;
  CHECK (! glims_ai_settings_valid (&math), "validate: an unknown mode is refused");
  math.mode = GLIMS_BLEND_ADD;
  CHECK (glims_ai_settings_valid (&math), "validate: Add with scale 2 is valid");
  math.invert_source = 2;
  CHECK (! glims_ai_settings_valid (&math), "validate: source invert 2 is refused");
  math.invert_source = 0;
  math.invert_mask = 2;
  CHECK (! glims_ai_settings_valid (&math), "validate: mask invert 2 is refused");
  math.invert_mask = 0;
}

static void
test_modes_first_pair (void)
{
  static const float cb[3] = { 0.2f, 0.4f, 0.6f };
  static const float cs[3] = { 0.5f, 0.8f, 0.25f };

  check_mode ("normal", GLIMS_BLEND_NORMAL, 1.0, 0.0, cb, cs,
              (const double[]) { 0.5, 0.8, 0.25 });
  check_mode ("multiply", GLIMS_BLEND_MULTIPLY, 1.0, 0.0, cb, cs,
              (const double[]) { 0.1, 0.32, 0.15 });
  check_mode ("screen", GLIMS_BLEND_SCREEN, 1.0, 0.0, cb, cs,
              (const double[]) { 0.6, 0.88, 0.7 });
  check_mode ("overlay", GLIMS_BLEND_OVERLAY, 1.0, 0.0, cb, cs,
              (const double[]) { 0.2, 0.64, 0.4 });
  check_mode ("soft-light", GLIMS_BLEND_SOFT_LIGHT, 1.0, 0.0, cb, cs,
              (const double[]) { 0.2, 0.5394733192, 0.48 });
  check_mode ("hard-light", GLIMS_BLEND_HARD_LIGHT, 1.0, 0.0, cb, cs,
              (const double[]) { 0.2, 0.76, 0.3 });
  check_mode ("darken", GLIMS_BLEND_DARKEN, 1.0, 0.0, cb, cs,
              (const double[]) { 0.2, 0.4, 0.25 });
  check_mode ("lighten", GLIMS_BLEND_LIGHTEN, 1.0, 0.0, cb, cs,
              (const double[]) { 0.5, 0.8, 0.6 });
  check_mode ("difference", GLIMS_BLEND_DIFFERENCE, 1.0, 0.0, cb, cs,
              (const double[]) { 0.3, 0.4, 0.35 });
  check_mode ("exclusion", GLIMS_BLEND_EXCLUSION, 1.0, 0.0, cb, cs,
              (const double[]) { 0.5, 0.56, 0.55 });
  check_mode ("add", GLIMS_BLEND_ADD, 2.0, 0.5, cb, cs,
              (const double[]) { 0.85, 1.0, 0.925 });
  check_mode ("subtract", GLIMS_BLEND_SUBTRACT, 1.0, 0.0, cb, cs,
              (const double[]) { 0.0, 0.0, 0.35 });
}

static void
test_modes_second_pair (void)
{
  static const float cb[3] = { 0.75f, 0.1f, 0.9f };
  static const float cs[3] = { 0.15f, 0.6f, 0.35f };

  check_mode ("normal", GLIMS_BLEND_NORMAL, 1.0, 0.0, cb, cs,
              (const double[]) { 0.15, 0.6, 0.35 });
  check_mode ("multiply", GLIMS_BLEND_MULTIPLY, 1.0, 0.0, cb, cs,
              (const double[]) { 0.1125, 0.06, 0.315 });
  check_mode ("screen", GLIMS_BLEND_SCREEN, 1.0, 0.0, cb, cs,
              (const double[]) { 0.7875, 0.64, 0.935 });
  check_mode ("overlay", GLIMS_BLEND_OVERLAY, 1.0, 0.0, cb, cs,
              (const double[]) { 0.575, 0.12, 0.87 });
  check_mode ("soft-light", GLIMS_BLEND_SOFT_LIGHT, 1.0, 0.0, cb, cs,
              (const double[]) { 0.61875, 0.1392, 0.873 });
  check_mode ("hard-light", GLIMS_BLEND_HARD_LIGHT, 1.0, 0.0, cb, cs,
              (const double[]) { 0.225, 0.28, 0.63 });
  check_mode ("darken", GLIMS_BLEND_DARKEN, 1.0, 0.0, cb, cs,
              (const double[]) { 0.15, 0.1, 0.35 });
  check_mode ("lighten", GLIMS_BLEND_LIGHTEN, 1.0, 0.0, cb, cs,
              (const double[]) { 0.75, 0.6, 0.9 });
  check_mode ("difference", GLIMS_BLEND_DIFFERENCE, 1.0, 0.0, cb, cs,
              (const double[]) { 0.6, 0.5, 0.55 });
  check_mode ("exclusion", GLIMS_BLEND_EXCLUSION, 1.0, 0.0, cb, cs,
              (const double[]) { 0.675, 0.58, 0.62 });
  check_mode ("add", GLIMS_BLEND_ADD, 1.5, -0.25, cb, cs,
              (const double[]) { 0.35, 0.2166666667, 0.5833333333 });
  check_mode ("subtract", GLIMS_BLEND_SUBTRACT, 2.0, 0.5, cb, cs,
              (const double[]) { 0.8, 0.25, 0.775 });
}

static void
test_apply_weight_mask_invert (void)
{
  GlimsAIMath math = { GLIMS_BLEND_NORMAL, 1.0, 1.0, 0.0, 0, 0 };
  const float target[4] = { 0.2f, 0.4f, 0.6f, 1.0f };
  const float source[4] = { 0.5f, 0.8f, 0.25f, 1.0f };
  float out[4];

  /* opacity 0.25, mask 0.5: w = 0.125. */
  math.opacity = 0.25;
  glims_ai_apply (&math, target, source, (const float[]) { 0.5f }, NULL, 1, out);
  CHECK (near (out[0], 0.2375) && near (out[1], 0.45) && near (out[2], 0.55625) &&
         out[3] == 1.0f, "apply: opacity and mask multiply the weight");

  /* A half-transparent source carries half the weight at full opacity. */
  math.opacity = 1.0;
  glims_ai_apply (&math, target,
                  (const float[]) { 0.5f, 0.8f, 0.25f, 0.5f }, NULL, NULL, 1, out);
  CHECK (near (out[0], 0.35) && near (out[1], 0.6) && near (out[2], 0.425),
         "apply: source coverage scales the weight");

  /* The target alpha is copied, never blended. */
  glims_ai_apply (&math, (const float[]) { 0.2f, 0.4f, 0.6f, 0.5f },
                  (const float[]) { 0.5f, 0.8f, 0.25f, 0.0f }, NULL, NULL, 1, out);
  CHECK (near (out[0], 0.2) && near (out[1], 0.4) && near (out[2], 0.6) &&
         out[3] == 0.5f, "apply: a transparent source changes nothing");

  /* Invert flips the source color before blending. */
  math.invert_source = 1;
  glims_ai_apply (&math, target, source, NULL, NULL, 1, out);
  CHECK (near (out[0], 0.5) && near (out[1], 0.2) && near (out[2], 0.75),
         "apply: source Invert blends 1 - cs");
  math.invert_source = 0;

  /* Mask Invert flips the mask value; opacity still multiplies it. */
  math.opacity = 0.5;
  math.invert_mask = 1;
  glims_ai_apply (&math, target, source, (const float[]) { 0.25f }, NULL, 1, out);
  CHECK (near (out[0], 0.3125) && near (out[1], 0.55) && near (out[2], 0.46875),
         "apply: mask Invert applies before the opacity product");
  math.opacity = 1.0;
  math.invert_mask = 0;

  /* The selection limit is an independent multiplier. */
  glims_ai_apply (&math, target, source, NULL, (const float[]) { 0.5f }, 1, out);
  CHECK (near (out[0], 0.35) && near (out[1], 0.6) && near (out[2], 0.425),
         "apply: the selection limit weights the result");
}

static void
test_apply_batch (void)
{
  GlimsAIMath math = { GLIMS_BLEND_MULTIPLY, 1.0, 1.0, 0.0, 0, 0 };
  const float target[8] = {
    0.2f, 0.4f, 0.6f, 1.0f,
    1.0f, 1.0f, 1.0f, 1.0f,
  };
  const float source[8] = {
    0.5f, 0.8f, 0.25f, 1.0f,
    0.0f, 0.5f, 1.0f, 1.0f,
  };
  const float mask[2] = { 1.0f, 0.5f };
  float out[8];

  glims_ai_apply (&math, target, source, mask, NULL, 2, out);
  CHECK (near (out[0], 0.1) && near (out[1], 0.32) && near (out[2], 0.15) &&
         near (out[4], 0.5) && near (out[5], 0.75) && near (out[6], 1.0) &&
         out[3] == 1.0f && out[7] == 1.0f,
         "batch: each pixel keeps its own mask and alpha");
}

static void
test_luma (void)
{
  CHECK (near (glims_ai_luma (1.0, 0.0, 0.0), 0.299) &&
         near (glims_ai_luma (0.0, 1.0, 0.0), 0.587) &&
         near (glims_ai_luma (0.0, 0.0, 1.0), 0.114),
         "luma: the Rec. 601 weights on nonlinear components");
  CHECK (glims_ai_luma (2.0, 2.0, 2.0) == 1.0f,
         "luma: out-of-range components clamp to the unit range");
}

int
main (void)
{
  test_validate ();
  test_modes_first_pair ();
  test_modes_second_pair ();
  test_apply_weight_mask_invert ();
  test_apply_batch ();
  test_luma ();

  if (failures)
    {
      printf ("FAILED: %d apply-image-math check(s)\n", failures);
      return 1;
    }
  printf ("PASSED: apply-image-math checks\n");
  return 0;
}
