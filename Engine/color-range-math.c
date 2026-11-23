/* Pure Select > Color Range weight kernel; see color-range-math.h. */
#include "color-range-math.h"

#include <math.h>

static double
clamped (double value)
{
  return value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value;
}

bool
glims_cr_settings_valid (const GlimsCRSettings *settings)
{
  if (! settings)
    return false;
  if (settings->mode < GLIMS_CR_SAMPLED || settings->mode > GLIMS_CR_SHADOWS)
    return false;
  if (! isfinite (settings->fuzziness) ||
      settings->fuzziness < 0.0 || settings->fuzziness > 200.0)
    return false;
  if (settings->invert > 1)
    return false;
  if (settings->sample_count > GLIMS_CR_MAX_SAMPLES)
    return false;
  if (settings->sample_count && ! settings->samples)
    return false;

  bool has_add = false;

  for (size_t i = 0; i < settings->sample_count; i++)
    {
      const GlimsCRSample *sample = &settings->samples[i];

      if (! isfinite (sample->red) || ! isfinite (sample->green) ||
          ! isfinite (sample->blue) || sample->subtract > 1)
        return false;
      if (! sample->subtract)
        has_add = true;
    }

  if (settings->mode == GLIMS_CR_SAMPLED)
    return settings->sample_count > 0 && has_add;
  return settings->sample_count == 0;
}

/* The antialiased ramp GIMP's by-color selection uses, scaled by the
 * tolerance t: full weight inside d <= t, half at 1.25 t, none at 1.5 t. */
static double
sampled_ramp (double distance, double tolerance)
{
  double ramp = 1.5 - distance / tolerance;

  return ramp <= 0.0 ? 0.0 : ramp < 0.5 ? ramp * 2.0 : 1.0;
}

/* HSV hue in degrees and saturation of an already clamped color. Hue is 0
 * for a gray, where the saturation gate already makes every hue weight 0. */
static void
hue_and_saturation (const double rgb[3], double *hue, double *saturation)
{
  double maximum = rgb[0] > rgb[1] ? rgb[0] : rgb[1];
  double minimum = rgb[0] < rgb[1] ? rgb[0] : rgb[1];
  double delta;

  if (rgb[2] > maximum) maximum = rgb[2];
  if (rgb[2] < minimum) minimum = rgb[2];
  delta = maximum - minimum;

  *saturation = maximum <= 0.0 ? 0.0 : delta / maximum;
  if (delta <= 0.0)
    {
      *hue = 0.0;
      return;
    }

  if (maximum == rgb[0])
    *hue = 60.0 * fmod ((rgb[1] - rgb[2]) / delta, 6.0);
  else if (maximum == rgb[1])
    *hue = 60.0 * (((rgb[2] - rgb[0]) / delta) + 2.0);
  else
    *hue = 60.0 * (((rgb[0] - rgb[1]) / delta) + 4.0);

  if (*hue < 0.0)
    *hue += 360.0;
}

/* Clamps `value` to [0,1]; the gate's 0.02 floor and 0.08 transition are
 * the dialog's saturation threshold. */
static double
unit_range (double value)
{
  return value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value;
}

static double
fixed_hue_weight (const double rgb[3], double center)
{
  double hue, saturation, distance, sector, gate;

  hue_and_saturation (rgb, &hue, &saturation);
  distance = fabs (hue - center);
  if (distance > 180.0)
    distance = 360.0 - distance;

  /* Full weight within 15 degrees of the center, linear to 0 at 45. */
  sector = distance <= 15.0 ? 1.0 : distance >= 45.0 ? 0.0 : (45.0 - distance) / 30.0;
  /* Grays never match a hue range. */
  gate = unit_range ((saturation - 0.02) / 0.08);
  return sector * gate;
}

static double
fixed_luma_weight (const double rgb[3], uint32_t mode)
{
  /* Integer weights keep a gray exact: 0.5 gray is luma 0.5, not 0.49999. */
  double luma = (299.0 * rgb[0] + 587.0 * rgb[1] + 114.0 * rgb[2]) / 1000.0;

  switch (mode)
    {
    case GLIMS_CR_SHADOWS:
      return luma <= 0.25 ? 1.0 : luma >= 0.5 ? 0.0 : (0.5 - luma) / 0.25;
    case GLIMS_CR_HIGHLIGHTS:
      return luma >= 0.75 ? 1.0 : luma <= 0.5 ? 0.0 : (luma - 0.5) / 0.25;
    default:  /* GLIMS_CR_MIDTONES */
      if (luma <= 0.125 || luma >= 0.875)
        return 0.0;
      if (luma >= 0.375 && luma <= 0.625)
        return 1.0;
      return luma < 0.375 ? (luma - 0.125) / 0.25 : (0.875 - luma) / 0.25;
    }
}

float
glims_cr_weight (const float rgba[4], const GlimsCRSettings *settings,
                 const float *selection)
{
  double rgb[3] = { clamped (rgba[0]), clamped (rgba[1]), clamped (rgba[2]) };
  double weight;

  if (settings->mode == GLIMS_CR_SAMPLED)
    {
      double tolerance = settings->fuzziness / 200.0;

      if (tolerance < 1.0 / 512.0)
        tolerance = 1.0 / 512.0;

      double add = 0.0, subtract = 0.0;

      for (size_t i = 0; i < settings->sample_count; i++)
        {
          const GlimsCRSample *sample = &settings->samples[i];
          double distance = 0.0;

          distance = fabs (rgb[0] - clamped (sample->red));
          distance = fmax (distance, fabs (rgb[1] - clamped (sample->green)));
          distance = fmax (distance, fabs (rgb[2] - clamped (sample->blue)));

          if (sample->subtract)
            subtract = fmax (subtract, sampled_ramp (distance, tolerance));
          else
            add = fmax (add, sampled_ramp (distance, tolerance));
        }

      weight = add - subtract;
      if (weight < 0.0)
        weight = 0.0;
      else if (weight > 1.0)
        weight = 1.0;
    }
  else if (settings->mode <= GLIMS_CR_MAGENTAS)
    {
      static const double centers[] = { 0.0, 60.0, 120.0, 180.0, 240.0, 300.0 };

      weight = fixed_hue_weight (rgb, centers[settings->mode - GLIMS_CR_REDS]);
    }
  else
    {
      weight = fixed_luma_weight (rgb, settings->mode);
    }

  /* Transparency wins before Invert; Invert then the selection limit. */
  if (rgba[3] <= 0.0)
    weight = 0.0;
  if (settings->invert)
    weight = 1.0 - weight;
  if (selection)
    weight *= *selection;

  return (float) weight;
}

void
glims_cr_apply (const GlimsCRSettings *settings,
                const float *rgba, size_t count,
                const float *selection, float *out)
{
  for (size_t i = 0; i < count; i++)
    out[i] = glims_cr_weight (rgba + i * 4, settings, selection ? selection + i : NULL);
}
