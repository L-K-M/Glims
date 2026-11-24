/* Pure Image > Adjust > Replace Color kernel; see replace-color-math.h.
 *
 * The color transform copies GIMP's Hue-Saturation master range with overlap
 * 0: app/operations/gimpoperationhuesaturation.c, map_hue, map_saturation,
 * map_lightness and gimp_operation_hue_saturation_process. The HSL conversion
 * copies babl's HSLA float conversion (babl/extensions/HSL.c,
 * rgb_nonlinear_to_hsl_step and hsl_to_rgb_nonlinear_step), so the round trip
 * agrees with the engine's own hue-saturation operation. */
#include "replace-color-math.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

/* babl's HSL conversion uses this epsilon for "equal" channels. */
#define GLIMS_REPLACE_COLOR_EPSILON 1.0e-10

static double
clamped (double value)
{
  return value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value;
}

bool
glims_replace_color_settings_valid (const GlimsReplaceColorSettings *settings)
{
  if (! settings)
    return false;
  if (! isfinite (settings->fuzziness) ||
      settings->fuzziness < 0.0 || settings->fuzziness > 200.0)
    return false;
  if (settings->sample_count > GLIMS_REPLACE_COLOR_MAX_SAMPLES)
    return false;
  if (! isfinite (settings->hue) ||
      settings->hue < -180.0 || settings->hue > 180.0)
    return false;
  if (! isfinite (settings->saturation) ||
      settings->saturation < -100.0 || settings->saturation > 100.0)
    return false;
  if (! isfinite (settings->lightness) ||
      settings->lightness < -100.0 || settings->lightness > 100.0)
    return false;

  for (uint32_t i = 0; i < settings->sample_count; i++)
    {
      const GlimsCRSample *sample = &settings->samples[i];

      if (! isfinite (sample->red) || ! isfinite (sample->green) ||
          ! isfinite (sample->blue) || sample->subtract > 1)
        return false;
    }

  return true;
}

/* babl's rgb_nonlinear_to_hsl_step, float variant. Hue is 0...1, saturation
 * and lightness 0...1; a gray has hue and saturation 0. */
static void
rgb_to_hsla (const float rgb[3], float out[3])
{
  float red   = (float) clamped (rgb[0]);
  float green = (float) clamped (rgb[1]);
  float blue  = (float) clamped (rgb[2]);
  float maximum = red > green ? red : green;
  float minimum = red < green ? red : green;
  float hue, saturation, lightness;
  int   cpn_max;

  if (blue > maximum) maximum = blue;
  if (blue < minimum) minimum = blue;

  if (maximum - red < GLIMS_REPLACE_COLOR_EPSILON)
    cpn_max = 0;
  else if (maximum - green < GLIMS_REPLACE_COLOR_EPSILON)
    cpn_max = 1;
  else
    cpn_max = 2;

  lightness = (maximum + minimum) / 2.0f;

  if (maximum - minimum < GLIMS_REPLACE_COLOR_EPSILON)
    {
      hue = saturation = 0.0f;
    }
  else
    {
      float diff = maximum - minimum;
      float sum  = maximum + minimum;

      saturation = lightness > 0.5f ? diff / (2.0f - sum) : diff / sum;
      switch (cpn_max)
        {
        case 0: hue = (green - blue) / diff + (green < blue ? 6.0f : 0.0f); break;
        case 1: hue = (blue - red) / diff + 2.0f; break;
        default: hue = (red - green) / diff + 4.0f; break;
        }
      hue /= 6.0f;
    }

  out[0] = hue;
  out[1] = saturation;
  out[2] = lightness;
}

/* babl's hue2cpn. */
static float
hue2cpn (float p, float q, float hue)
{
  if (hue < 0.0f) hue += 1.0f;
  if (hue > 1.0f) hue -= 1.0f;
  if (hue < 1.0f / 6.0f) return p + (q - p) * 6.0f * hue;
  if (hue < 1.0f / 2.0f) return q;
  if (hue < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - hue) * 6.0f;
  return p;
}

/* babl's hsl_to_rgb_nonlinear_step, float variant. */
static void
hsla_to_rgb (const float hsl[3], float out[3])
{
  float hue        = hsl[0];
  float saturation = hsl[1];
  float lightness  = hsl[2];

  if (saturation < 1.0e-7f)
    {
      out[0] = out[1] = out[2] = lightness;
      return;
    }

  {
    float q = lightness < 0.5f
      ? lightness * (1.0f + saturation)
      : lightness + saturation - lightness * saturation;
    float p = 2.0f * lightness - q;

    hue = fmodf (hue, 1.0f);
    if (hue < 0.0f) hue += 1.0f;

    out[0] = hue2cpn (p, q, hue + 1.0f / 3.0f);
    out[1] = hue2cpn (p, q, hue);
    out[2] = hue2cpn (p, q, hue - 1.0f / 3.0f);
  }
}

/* The master range with overlap 0. GIMP's map_hue adds
 * (hue[ALL] + hue[range]) / 2; the master range leaves every per-range
 * correction at 0, so the shift is hue[ALL] / 2. */
static void
map_master (const GlimsReplaceColorSettings *settings, float hsl[3])
{
  float hue      = (float) (settings->hue / 180.0);
  float saturation = (float) (settings->saturation / 100.0);
  float lightness  = (float) (settings->lightness / 100.0);

  hsl[0] += hue * 0.5f;
  if (hsl[0] < 0.0f)
    hsl[0] += 1.0f;
  else if (hsl[0] > 1.0f)
    hsl[0] -= 1.0f;

  hsl[1] *= saturation + 1.0f;
  hsl[1] = (float) clamped (hsl[1]);

  if (lightness < 0.0f)
    hsl[2] *= lightness + 1.0f;
  else
    hsl[2] += lightness * (1.0f - hsl[2]);
}

void
glims_replace_color_apply (const GlimsReplaceColorSettings *settings,
                           const float *src, float *dst, size_t count)
{
  GlimsCRSettings kernel;

  if (! settings || ! src || ! dst || count > SIZE_MAX / (4 * sizeof (float)))
    return;

  kernel.mode = GLIMS_CR_SAMPLED;
  kernel.fuzziness = settings->fuzziness;
  kernel.invert = 0;
  kernel.sample_count = settings->sample_count;
  kernel.samples = settings->sample_count ? settings->samples : NULL;

  for (size_t i = 0; i < count; i++)
    {
      const float *in = src + i * 4;
      float       *out = dst + i * 4;
      float        hsl[3], mapped[3];
      float        weight;

      /* Transparency wins, then the non-finite pass-through policy. */
      if (in[3] <= 0.0f || ! isfinite (in[0]) || ! isfinite (in[1]) ||
          ! isfinite (in[2]))
        {
          if (out != in)
            memcpy (out, in, 4 * sizeof (float));
          continue;
        }

      weight = glims_cr_weight (in, &kernel, NULL);
      if (weight <= 0.0f)
        {
          if (out != in)
            memcpy (out, in, 4 * sizeof (float));
          continue;
        }

      rgb_to_hsla (in, hsl);
      map_master (settings, hsl);
      hsla_to_rgb (hsl, mapped);

      out[0] = in[0] + weight * (mapped[0] - in[0]);
      out[1] = in[1] + weight * (mapped[1] - in[1]);
      out[2] = in[2] + weight * (mapped[2] - in[2]);
      out[3] = in[3];
    }
}
