/* Selective Color kernel. Formula source: Clément Boesch,
 * "Understanding Selective Coloring in Adobe Photoshop",
 * https://blog.pkh.me/p/22-understanding-selective-coloring-in-adobe-photoshop.html
 * Implemented from the published math, not from FFmpeg's code. */
#include "selective-color-math.h"

#include <math.h>
#include <float.h>
#include <stdint.h>
#include <string.h>

bool
glims_selective_color_settings_validate (const GlimsSelectiveColorSettings *settings)
{
  if (!settings)
    return false;
  for (int i = 0; i < GLIMS_SELECTIVE_RANGE_COUNT; i++)
    {
      const GlimsSelectiveColorRange *r = &settings->ranges[i];
      const double v[4] = { r->c, r->m, r->y, r->k };
      for (int j = 0; j < 4; j++)
        if (!isfinite (v[j]) || v[j] < -1.0 || v[j] > 1.0)
          return false;
    }
  return true;
}

static double
clamp01 (double v)
{
  return v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v;
}

/* Range membership weight from the original pixel, per the blog's table. */
static double
range_weight (GlimsSelectiveColorRangeIndex index,
              float r, float g, float b, float lo, float mid, float hi)
{
  switch (index)
    {
    case GLIMS_SELECTIVE_RED:     return hi == r ? hi - mid : 0.0;
    case GLIMS_SELECTIVE_YELLOW:  return lo == b ? mid - lo : 0.0;
    case GLIMS_SELECTIVE_GREEN:   return hi == g ? hi - mid : 0.0;
    case GLIMS_SELECTIVE_CYAN:    return lo == r ? mid - lo : 0.0;
    case GLIMS_SELECTIVE_BLUE:    return hi == b ? hi - mid : 0.0;
    case GLIMS_SELECTIVE_MAGENTA: return lo == g ? mid - lo : 0.0;
    case GLIMS_SELECTIVE_WHITE:   return lo > 0.5f ? 2.0 * lo - 1.0 : 0.0;
    case GLIMS_SELECTIVE_BLACK:   return hi < 0.5f ? 1.0 - 2.0 * hi : 0.0;
    case GLIMS_SELECTIVE_NEUTRAL:
      /* Everything except pure black and pure white. */
      if ((r == 0.0f && g == 0.0f && b == 0.0f) ||
          (r == 1.0f && g == 1.0f && b == 1.0f))
        return 0.0;
      return 1.0 - fabs (hi - 0.5) - fabs (lo - 0.5);
    default:
      return 0.0;
    }
}

void
glims_selective_color_apply (const GlimsSelectiveColorSettings *settings,
                             const float *src, float *dst, size_t count)
{
  if (!settings || !src || !dst || count > SIZE_MAX / (4 * sizeof (float)))
    return;

  double nonzero = 0.0;
  for (int i = 0; i < GLIMS_SELECTIVE_RANGE_COUNT; i++)
    nonzero += fabs (settings->ranges[i].c) + fabs (settings->ranges[i].m) +
               fabs (settings->ranges[i].y) + fabs (settings->ranges[i].k);
  if (nonzero == 0.0)
    {
      /* Bit-exact fast path for zero settings, -0.0 and NaN included. */
      if (dst != src)
        memmove (dst, src, count * 4 * sizeof (float));
      return;
    }

  for (size_t p = 0; p < count; p++)
    {
      const float *in = src + p * 4;
      float       *out = dst + p * 4;
      float r = in[0], g = in[1], b = in[2];
      const float a = in[3];
      /* Babl's perceptual conversion can put normalized primaries one
       * float step above 1. Accept a narrow conversion-roundoff margin,
       * while leaving genuine HDR pixels outside the defined domain. */
      const float endpoint_tolerance = 4.f * FLT_EPSILON;

      if (!isfinite (r) || !isfinite (g) || !isfinite (b) ||
          r < -endpoint_tolerance || r > 1.0f + endpoint_tolerance ||
          g < -endpoint_tolerance || g > 1.0f + endpoint_tolerance ||
          b < -endpoint_tolerance || b > 1.0f + endpoint_tolerance)
        {
          if (out != in)
            memcpy (out, in, 4 * sizeof (float));
          continue;
        }

      r = (float) clamp01 (r);
      g = (float) clamp01 (g);
      b = (float) clamp01 (b);
      const float hi = fmaxf (fmaxf (r, g), b);
      const float lo = fminf (fminf (r, g), b);
      /* Select an existing channel; summing and subtracting fabricates
       * chroma for equal non-dyadic floats through rounding. */
      const float mid = fmaxf (fminf (r, g), fminf (fmaxf (r, g), b));
      const double orig[3] = { r, g, b };
      double delta[3] = { 0.0, 0.0, 0.0 };

      for (int i = 0; i < GLIMS_SELECTIVE_RANGE_COUNT; i++)
        {
          const double w = range_weight (i, r, g, b, lo, mid, hi);
          if (w <= 0.0)
            continue;
          const GlimsSelectiveColorRange *range = &settings->ranges[i];
          const double adjust[3] = { range->c, range->m, range->y };

          for (int ch = 0; ch < 3; ch++)
            {
              const double v = orig[ch];
              double raw = (-1.0 - adjust[ch]) * range->k - adjust[ch];
              if (settings->relative)
                raw *= 1.0 - v;
              if (raw < -v)
                raw = -v;
              else if (raw > 1.0 - v)
                raw = 1.0 - v;
              delta[ch] += raw * w;
            }
        }

      out[0] = (float) clamp01 (r + delta[0]);
      out[1] = (float) clamp01 (g + delta[1]);
      out[2] = (float) clamp01 (b + delta[2]);
      out[3] = a;
    }
}
