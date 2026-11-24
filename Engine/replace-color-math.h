#ifndef GLIMS_REPLACE_COLOR_MATH_H
#define GLIMS_REPLACE_COLOR_MATH_H

/* Pure Image > Adjust > Replace Color kernel. No GEGL, GIMP or facade
 * dependency, so the standalone harness can compile it alone.
 *
 * Pixels are straight (non-premultiplied) nonlinear sRGB RGBA float
 * quadruples. The per-pixel weight comes from the Select > Color Range
 * kernel (color-range-math.h), sampled mode, no Invert and no selection
 * limit. The color transform mirrors GIMP's Hue-Saturation master range
 * (app/operations/gimpoperationhuesaturation.c, map_hue, map_saturation,
 * map_lightness and gimp_operation_hue_saturation_process) with overlap 0.
 *
 * Alpha is copied bit-for-bit. A fully transparent pixel and a pixel with a
 * non-finite RGB channel pass through unchanged, the same input policy
 * selective-color-math.h documents. With no add sample every weight is 0,
 * so the operation is the identity. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "color-range-math.h"

#define GLIMS_REPLACE_COLOR_MAX_SAMPLES 8u

typedef struct {
  double       fuzziness;   /* finite 0...200; default 40 */
  uint32_t     sample_count; /* 0...GLIMS_REPLACE_COLOR_MAX_SAMPLES */
  GlimsCRSample samples[GLIMS_REPLACE_COLOR_MAX_SAMPLES]; /* sRGB */
  double       hue;         /* finite -180...180 degrees */
  double       saturation;  /* finite -100...100 percent */
  double       lightness;   /* finite -100...100 percent */
} GlimsReplaceColorSettings;

/* True when every field satisfies the operation's property bounds. A list
 * with no add sample is valid: it makes the operation the identity. */
bool glims_replace_color_settings_valid (const GlimsReplaceColorSettings *settings);

/* count is a pixel count; each buffer holds 4*count floats. dst may equal
 * src for in-place processing; otherwise the buffers must not overlap.
 * Settings must already have passed validation. Neither buffer may be NULL
 * when count > 0. Impossible byte counts are refused without touching either
 * buffer. */
void glims_replace_color_apply (const GlimsReplaceColorSettings *settings,
                                const float *src, float *dst, size_t count);

#endif /* GLIMS_REPLACE_COLOR_MATH_H */
