/* Standalone harness for the pure Selective Color kernel. Expected values
 * are hand-computed literals from the published formulas, not re-derivations
 * through the implementation. */
#include "selective-color-math.h"

#include <math.h>
#include <float.h>
#include <stdint.h>
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
same_pixel (const float *px, float r, float g, float b, float a)
{
  return px[0] == r && px[1] == g && px[2] == b && px[3] == a;
}

static int
same_bits (const float *x, const float *y, size_t n)
{
  return memcmp (x, y, n * sizeof (float)) == 0;
}

static float
bits_float (uint32_t bits)
{
  float f;
  memcpy (&f, &bits, sizeof (f));
  return f;
}

static GlimsSelectiveColorSettings
zeroed (int relative)
{
  GlimsSelectiveColorSettings s;
  memset (&s, 0, sizeof (s));
  s.relative = relative;
  return s;
}

static void
test_validate (void)
{
  GlimsSelectiveColorSettings s = zeroed (0);

  CHECK (glims_selective_color_settings_validate (&s), "validate: zeros ok");
  s.ranges[GLIMS_SELECTIVE_RED].c = 1.0;
  s.ranges[GLIMS_SELECTIVE_BLACK].k = -1.0;
  CHECK (glims_selective_color_settings_validate (&s), "validate: endpoints ok");
  s.ranges[GLIMS_SELECTIVE_GREEN].m = 1.0000001;
  CHECK (!glims_selective_color_settings_validate (&s), "validate: >1 rejected");
  s.ranges[GLIMS_SELECTIVE_GREEN].m = -1.5;
  CHECK (!glims_selective_color_settings_validate (&s), "validate: <-1 rejected");
  s.ranges[GLIMS_SELECTIVE_GREEN].m = NAN;
  CHECK (!glims_selective_color_settings_validate (&s), "validate: NaN rejected");
  s.ranges[GLIMS_SELECTIVE_GREEN].m = INFINITY;
  CHECK (!glims_selective_color_settings_validate (&s), "validate: Inf rejected");
  CHECK (!glims_selective_color_settings_validate (NULL), "validate: NULL rejected");
}

static void
test_zero_bit_exact (void)
{
  const GlimsSelectiveColorSettings s = zeroed (0);
  const float in[] = {
    0.0f, -0.0f, 0.5f, 1.0f,                 /* -0.0 must survive bit-exact */
    1.5f, 0.2f, 0.3f, 0.7f,                  /* HDR channel: passthrough anyway */
    NAN, 0.0f, 0.0f, 0.25f,                  /* NaN: passthrough */
    0.25f, 0.5f, 0.75f, bits_float (0x7f800001u), /* arbitrary alpha bits */
  };
  float out[16];

  memset (out, 0xAB, sizeof (out));
  glims_selective_color_apply (&s, in, out, 4);
  CHECK (same_bits (in, out, 16), "zero settings: out-of-place bit-exact");

  float inplace[16];
  memcpy (inplace, in, sizeof (in));
  glims_selective_color_apply (&s, inplace, inplace, 4);
  CHECK (same_bits (in, inplace, 16), "zero settings: in-place bit-exact");
}

static void
test_hand_literals (void)
{
  GlimsSelectiveColorSettings s;
  float out[4];

  /* pure red, reds C +0.5 absolute -> (0.5, 0, 0) */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_RED].c = 0.5;
  {
    const float in[4] = { 1.0f, 0.0f, 0.0f, 0.4f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.5f, 0.0f, 0.0f, 0.4f),
           "red C+.5 abs on pure red");
  }

  /* pure green, greens M +0.25 -> (0, 0.75, 0) */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_GREEN].m = 0.25;
  {
    const float in[4] = { 0.0f, 1.0f, 0.0f, 1.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.0f, 0.75f, 0.0f, 1.0f),
           "green M+.25 abs on pure green");
  }

  /* (0.75, 0.5, 0.25): red member, weight = hi-mid = 0.25 */
  {
    const float in[4] = { 0.75f, 0.5f, 0.25f, 0.0f };
    s = zeroed (0);
    s.ranges[GLIMS_SELECTIVE_RED].c = 0.5;
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.625f, 0.5f, 0.25f, 0.0f),
           "red C+.5 absolute on (0.75,0.5,0.25)");
    s.relative = true;
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.71875f, 0.5f, 0.25f, 0.0f),
           "red C+.5 relative on (0.75,0.5,0.25)");
  }

  /* neutral (0.5,0.5,0.5), weight 1; neutrals C +0.25 hits R */
  {
    const float in[4] = { 0.5f, 0.5f, 0.5f, 0.5f };
    s = zeroed (0);
    s.ranges[GLIMS_SELECTIVE_NEUTRAL].c = 0.25;
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.25f, 0.5f, 0.5f, 0.5f),
           "neutral C+.25 absolute on gray 0.5");
    s.relative = true;
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.375f, 0.5f, 0.5f, 0.5f),
           "neutral C+.25 relative on gray 0.5");
  }

  /* whites: (0.75 x3), weight 2*0.75-1 = 0.5; K +0.25, raw = -0.25 */
  {
    const float in[4] = { 0.75f, 0.75f, 0.75f, 1.0f };
    s = zeroed (0);
    s.ranges[GLIMS_SELECTIVE_WHITE].k = 0.25;
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.625f, 0.625f, 0.625f, 1.0f),
           "white K+.25 absolute");
  }

  /* blacks: (0.25 x3), weight 1-2*0.25 = 0.5; K -0.25, raw = +0.25 */
  {
    const float in[4] = { 0.25f, 0.25f, 0.25f, 1.0f };
    s = zeroed (0);
    s.ranges[GLIMS_SELECTIVE_BLACK].k = -0.25;
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.375f, 0.375f, 0.375f, 1.0f),
           "black K-.25 absolute");
  }
}

/* Every range reaches a pixel it owns; all adjustments are absolute. */
static void
test_each_range (void)
{
  GlimsSelectiveColorSettings s;
  float out[4];

  /* Dyadic fractions throughout so float results are exact.
   * yellow member: b is min. (0.75,0.75,0.25): w = mid-lo = 0.5.
   * Y +0.5 on B: raw -0.5 clamped to [-0.25, 0.75] -> -0.25,
   * delta -0.125 -> b 0.125. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_YELLOW].y = 0.5;
  {
    const float in[4] = { 0.75f, 0.75f, 0.25f, 0.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.75f, 0.75f, 0.125f, 0.0f),
           "yellow Y+.5 on (0.75,0.75,0.25)");
  }

  /* cyan member: r is min. (0.25,0.75,0.75): w = 0.5.
   * C +0.5 on R: raw -0.5 clamp -0.25, delta -0.125 -> r 0.125. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_CYAN].c = 0.5;
  {
    const float in[4] = { 0.25f, 0.75f, 0.75f, 0.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.125f, 0.75f, 0.75f, 0.0f),
           "cyan C+.5 on (0.25,0.75,0.75)");
  }

  /* magenta member: g is min. (0.75,0.25,0.75): w = 0.5, M +0.5 -> g .125. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_MAGENTA].m = 0.5;
  {
    const float in[4] = { 0.75f, 0.25f, 0.75f, 0.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.75f, 0.125f, 0.75f, 0.0f),
           "magenta M+.5 on (0.75,0.25,0.75)");
  }

  /* blue member: b is max. (0.25,0.5,0.75): w = hi-mid = 0.25.
   * blue C -0.5 on R: raw +0.5 clamp [-.25,.75] -> +0.5,
   * delta +0.125 -> r 0.375. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_BLUE].c = -0.5;
  {
    const float in[4] = { 0.25f, 0.5f, 0.75f, 0.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.375f, 0.5f, 0.75f, 0.0f),
           "blue C-.5 on (0.25,0.5,0.75)");
  }

  /* green member: (0.25,0.75,0.5): w = hi-mid = 0.25. green Y +0.5 on B:
   * raw -0.5 clamp [-0.5,0.5] -> -0.5, delta -0.125 -> b 0.375. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_GREEN].y = 0.5;
  {
    const float in[4] = { 0.25f, 0.75f, 0.5f, 0.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.25f, 0.75f, 0.375f, 0.0f),
           "green Y+.5 on (0.25,0.75,0.5)");
  }
}

/* C and K inside one range combine through raw = (-1-a)*k - a. */
static void
test_cmyk_interaction (void)
{
  float out[4];
  GlimsSelectiveColorSettings s = zeroed (0);
  const float in[4] = { 1.0f, 0.0f, 0.0f, 1.0f };

  s.ranges[GLIMS_SELECTIVE_RED].c = 0.5;
  s.ranges[GLIMS_SELECTIVE_RED].k = 0.25;
  /* raw = (-1-0.5)*0.25 - 0.5 = -0.875; w=1 -> r = 0.125 */
  glims_selective_color_apply (&s, in, out, 1);
  CHECK (same_pixel (out, 0.125f, 0.0f, 0.0f, 1.0f),
         "red C+.5 K+.25 interaction");
}

/* Deltas from several matching ranges accumulate against the original
 * pixel; no range sees another range's output. */
static void
test_overlap_accumulation (void)
{
  GlimsSelectiveColorSettings s = zeroed (0);
  const float in[4] = { 0.5f, 0.375f, 0.125f, 1.0f };
  float out[4];

  /* red member (hi=r, w=hi-mid=0.125) and yellow member (lo=b, w=0.25).
   * red C -0.5: raw +0.5 clamp [-0.5,0.5] -> +0.5, delta +0.0625.
   * yellow C +0.5: raw -0.5, delta -0.125. R: 0.5+0.0625-0.125 = 0.4375. */
  s.ranges[GLIMS_SELECTIVE_RED].c = -0.5;
  s.ranges[GLIMS_SELECTIVE_YELLOW].c = 0.5;
  glims_selective_color_apply (&s, in, out, 1);
  CHECK (same_pixel (out, 0.4375f, 0.375f, 0.125f, 1.0f),
         "red+yellow ranges accumulate on R");

  /* Same pixel is also neutral (w = 1-0-0.375 = 0.625) and neither white
   * nor black. neutral C +0.5 alone: raw -0.5, delta -0.3125 -> r .1875. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_NEUTRAL].c = 0.5;
  glims_selective_color_apply (&s, in, out, 1);
  CHECK (same_pixel (out, 0.1875f, 0.375f, 0.125f, 1.0f),
         "neutral range on chroma pixel");
}

/* Flat grays tie on max and min: RGB and CMY memberships all fire with
 * zero weight, so only white/black/neutral ranges matter. */
static void
test_ties_and_clamps (void)
{
  float out[4];
  GlimsSelectiveColorSettings s;
  const float gray[4] = { 0.375f, 0.375f, 0.375f, 1.0f };

  /* black member (hi<0.5, w=0.25) and neutral member (w=0.75).
   * black K +0.5: raw -0.5 clamp [-0.375,0.625] -> -0.375,
   * delta -0.09375 per channel. neutral C -0.5: raw +0.5,
   * delta +0.375 on R only. r = 0.375-0.09375+0.375 = 0.65625,
   * g/b = 0.28125. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_BLACK].k = 0.5;
  s.ranges[GLIMS_SELECTIVE_NEUTRAL].c = -0.5;
  glims_selective_color_apply (&s, gray, out, 1);
  CHECK (same_pixel (out, 0.65625f, 0.28125f, 0.28125f, 1.0f),
         "tied gray: black+neutral weights");

  /* Final clamp at 0: gray 0.5 is neutral with w=1; C +1 gives raw -1,
   * clamped to -0.5, delta -0.5 -> r hits exactly 0. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_NEUTRAL].c = 1.0;
  {
    const float in[4] = { 0.5f, 0.5f, 0.5f, 1.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.0f, 0.5f, 0.5f, 1.0f),
           "output clamps at 0");
  }

  /* Clamp at 1: neutral C -1 on the same gray -> raw +1 clamped to +0.5. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_NEUTRAL].c = -1.0;
  {
    const float in[4] = { 0.5f, 0.5f, 0.5f, 1.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 1.0f, 0.5f, 0.5f, 1.0f),
           "output clamps at 1");
  }

  /* black K -1 on 0.25 gray: raw +1 clamped to 1-v = 0.75,
   * delta +0.75*0.5 = +0.375 -> 0.625. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_BLACK].k = -1.0;
  {
    const float in[4] = { 0.25f, 0.25f, 0.25f, 1.0f };
    glims_selective_color_apply (&s, in, out, 1);
    CHECK (same_pixel (out, 0.625f, 0.625f, 0.625f, 1.0f),
           "black K-1 pushes gray up");
  }

  /* pure black and pure white are not neutral members; neutral K only. */
  s = zeroed (0);
  s.ranges[GLIMS_SELECTIVE_NEUTRAL].k = 1.0;
  {
    const float in[8] = { 0,0,0,1, 1,1,1,1 };
    float o[8];
    glims_selective_color_apply (&s, in, o, 2);
    CHECK (same_bits (in, o, 8),
           "pure black/white exclude neutral range");
  }
}

static void
test_alpha_and_passthrough (void)
{
  GlimsSelectiveColorSettings s = zeroed (0);
  float out[4];
  const uint32_t alpha_bits[] = { 0x00000000u, 0x80000000u, 0x7f800001u,
                                  0xffc00000u, 0x3f000000u };
  const float in[4] = { 1.0f, 0.0f, 0.0f, 0.0f };

  s.ranges[GLIMS_SELECTIVE_RED].c = 0.5; /* moves R to 0.5 */
  for (size_t i = 0; i < sizeof (alpha_bits) / sizeof (alpha_bits[0]); i++)
    {
      float px[4];
      memcpy (px, in, sizeof (px));
      px[3] = bits_float (alpha_bits[i]);
      glims_selective_color_apply (&s, px, out, 1);
      CHECK (out[0] == 0.5f && same_bits (&px[3], &out[3], 1),
             "alpha bit pattern preserved");
    }

  /* Non-finite / out-of-range RGB: whole pixel passes through untouched. */
  {
    const float bad[][4] = {
      { 1.5f, 0.0f, 0.0f, 0.3f },
      { -0.25f, 0.0f, 0.0f, 0.3f },
      { 0.0f, NAN, 0.0f, 0.3f },
      { 0.0f, 0.0f, INFINITY, 0.3f },
    };
    for (size_t i = 0; i < sizeof (bad) / sizeof (bad[0]); i++)
      {
        float o[4] = { -9, -9, -9, -9 };
        glims_selective_color_apply (&s, bad[i], o, 1);
        CHECK (same_bits (bad[i], o, 4), "HDR/NaN pixel passes through");
      }
  }
}

static void
test_inplace_matches_outofplace (void)
{
  GlimsSelectiveColorSettings s = zeroed (0);
  const float in[8] = { 0.75f, 0.5f, 0.25f, 0.9f,
                        0.2f, 0.8f, 0.8f, 0.1f };
  float a[8], b[8];

  s.ranges[GLIMS_SELECTIVE_RED].c = 0.5;
  s.ranges[GLIMS_SELECTIVE_CYAN].m = -0.4;
  s.ranges[GLIMS_SELECTIVE_NEUTRAL].k = 0.2;
  s.relative = true;

  glims_selective_color_apply (&s, in, a, 2);
  memcpy (b, in, sizeof (b));
  glims_selective_color_apply (&s, b, b, 2);
  CHECK (same_bits (a, b, 8), "in-place matches out-of-place");
  CHECK (!same_bits (in, a, 8), "settings actually changed pixels");

  /* src must not be written by out-of-place call. */
  memcpy (b, in, sizeof (b));
  glims_selective_color_apply (&s, b, a, 2);
  CHECK (same_bits (in, b, 8), "source buffer untouched");
}

int
main (void)
{
  {
    GlimsSelectiveColorSettings settings = zeroed (0);
    settings.ranges[GLIMS_SELECTIVE_RED].c = 0.5;
    const float gray[4] = { .7f, .7f, .7f, 1.f };
    float result[4];
    glims_selective_color_apply (&settings, gray, result, 1);
    CHECK (same_bits (gray, result, 4), "non-dyadic gray has no primary color weight");
  }
  {
    GlimsSelectiveColorSettings settings = zeroed (0);
    const float input[4] = { 1, 0, 0, 1 };
    float output[4] = { .25f, .25f, .25f, .25f };
    glims_selective_color_apply (&settings, input, output, SIZE_MAX);
    CHECK (same_pixel (output, .25f, .25f, .25f, .25f), "overflowing pixel count leaves buffers untouched");
  }
  {
    GlimsSelectiveColorSettings settings = zeroed (0);
    settings.ranges[GLIMS_SELECTIVE_RED].c = 0.5;
    const float converted[4] = { nextafterf(1.f, INFINITY), -FLT_EPSILON, 0.f, .25f };
    float result[4];
    glims_selective_color_apply (&settings, converted, result, 1);
    CHECK (same_pixel (result, .5f, 0.f, 0.f, .25f), "conversion roundoff at normalized endpoints still adjusts primaries");
    const float hdr[4] = { 1.f + 8.f * FLT_EPSILON, 0.f, 0.f, .5f };
    glims_selective_color_apply (&settings, hdr, result, 1);
    CHECK (same_bits (result, hdr, 4), "values beyond the endpoint roundoff tolerance remain HDR passthrough");
  }
  test_validate ();
  test_zero_bit_exact ();
  test_hand_literals ();
  test_each_range ();
  test_cmyk_interaction ();
  test_overlap_accumulation ();
  test_ties_and_clamps ();
  test_alpha_and_passthrough ();
  test_inplace_matches_outofplace ();

  printf ("%s\n", failures ? "FAILURES" : "all tests passed");
  return failures ? 1 : 0;
}
