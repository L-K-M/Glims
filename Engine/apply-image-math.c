/* Pure blend kernel for Image > Apply Image and Image > Calculations;
 * see apply-image-math.h. */
#include "apply-image-math.h"

#include <math.h>

static double
unit (double value)
{
  return value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value;
}

/* W3C hard-light, threshold on the source. */
static double
hard_light (double backdrop, double source)
{
  return source <= 0.5
    ? 2.0 * backdrop * source
    : 1.0 - 2.0 * (1.0 - backdrop) * (1.0 - source);
}

/* W3C soft-light: a quadratic ramp below half source, the spec's cubic or
 * square-root curve above it. */
static double
soft_light (double backdrop, double source)
{
  if (source <= 0.5)
    return backdrop - (1.0 - 2.0 * source) * backdrop * (1.0 - backdrop);

  double d = backdrop <= 0.25
    ? ((16.0 * backdrop - 12.0) * backdrop + 4.0) * backdrop
    : sqrt (backdrop);

  return backdrop + (2.0 * source - 1.0) * (d - backdrop);
}

bool
glims_ai_settings_valid (const GlimsAIMath *math)
{
  if (! math)
    return false;
  if (math->mode > GLIMS_BLEND_SUBTRACT)
    return false;
  if (! isfinite (math->opacity) || math->opacity <= 0.0 || math->opacity > 1.0)
    return false;
  if (! isfinite (math->scale) || math->scale < 1.0 || math->scale > 2.0)
    return false;
  if (! isfinite (math->offset) || math->offset < -1.0 || math->offset > 1.0)
    return false;
  if (math->invert_source > 1 || math->invert_mask > 1)
    return false;
  return true;
}

float
glims_ai_blend (double backdrop, double source, uint32_t mode,
                double scale, double offset)
{
  double cb = unit (backdrop), cs = unit (source), b;

  switch (mode)
    {
    case GLIMS_BLEND_NORMAL:
      b = cs;
      break;
    case GLIMS_BLEND_MULTIPLY:
      b = cb * cs;
      break;
    case GLIMS_BLEND_SCREEN:
      b = cb + cs - cb * cs;
      break;
    case GLIMS_BLEND_OVERLAY:
      /* Overlay is hard-light with its arguments swapped. */
      b = hard_light (cs, cb);
      break;
    case GLIMS_BLEND_SOFT_LIGHT:
      b = soft_light (cb, cs);
      break;
    case GLIMS_BLEND_HARD_LIGHT:
      b = hard_light (cb, cs);
      break;
    case GLIMS_BLEND_DARKEN:
      b = cb < cs ? cb : cs;
      break;
    case GLIMS_BLEND_LIGHTEN:
      b = cb > cs ? cb : cs;
      break;
    case GLIMS_BLEND_DIFFERENCE:
      b = fabs (cb - cs);
      break;
    case GLIMS_BLEND_EXCLUSION:
      b = cb + cs - 2.0 * cb * cs;
      break;
    case GLIMS_BLEND_ADD:
      b = (cb + cs) / scale + offset;
      break;
    case GLIMS_BLEND_SUBTRACT:
      b = (cb - cs) / scale + offset;
      break;
    default:
      b = cs;
      break;
    }

  return (float) unit (b);
}

float
glims_ai_luma (double red, double green, double blue)
{
  return (float) unit ((299.0 * red + 587.0 * green + 114.0 * blue) / 1000.0);
}

void
glims_ai_apply (const GlimsAIMath *math,
                const float *backdrop, const float *source,
                const float *mask, const float *selection,
                size_t count, float *out)
{
  double opacity = math->opacity;

  for (size_t i = 0; i < count; i++)
    {
      const float *cb = backdrop + i * 4;
      const float *cs = source + i * 4;
      float target[4] = { unit (cb[0]), unit (cb[1]), unit (cb[2]), unit (cb[3]) };
      float src[4] = { unit (cs[0]), unit (cs[1]), unit (cs[2]), unit (cs[3]) };
      float weight = mask ? unit (mask[i]) : 1.0f;
      float blended[3];

      if (math->invert_source)
        {
          src[0] = 1.0f - src[0];
          src[1] = 1.0f - src[1];
          src[2] = 1.0f - src[2];
        }
      if (math->invert_mask)
        weight = 1.0f - weight;
      if (selection)
        weight *= unit (selection[i]);

      weight *= (float) opacity * src[3];

      for (int c = 0; c < 3; c++)
        blended[c] = glims_ai_blend (target[c], src[c], math->mode,
                                     math->scale, math->offset);

      for (int c = 0; c < 3; c++)
        out[i * 4 + c] = target[c] + weight * (blended[c] - target[c]);
      out[i * 4 + 3] = target[3];
    }
}
