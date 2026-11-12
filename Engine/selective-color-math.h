#ifndef GLIMS_SELECTIVE_COLOR_MATH_H
#define GLIMS_SELECTIVE_COLOR_MATH_H

/* Pure Photoshop-style Selective Color pixel kernel. No GEGL dependency.
 *
 * Math follows the conclusion of Clément Boesch's reverse engineering of
 * Adobe Photoshop's Selective Color adjustment:
 * https://blog.pkh.me/p/22-understanding-selective-coloring-in-adobe-photoshop.html
 * (same math as FFmpeg's vf_selectivecolor; this is an original
 * implementation written from the published formulas).
 *
 * Pixels are straight (non-premultiplied) perceptual RGBA float quadruples,
 * channels normalized to [0,1]. Alpha is copied bit-for-bit. Membership and
 * weights are computed from the original pixel only; deltas from every
 * matching range accumulate against the original channels, then the result
 * is clamped to [0,1]. Conversion roundoff within 4 * FLT_EPSILON of
 * either endpoint is normalized before adjusting. A pixel with any
 * non-finite RGB or a channel further outside [0,1] passes through unchanged: the PS formula is defined on
 * normalized input only, so HDR/NaN handling is an explicit policy. */

#include <stdbool.h>
#include <stddef.h>

typedef struct {
  double c, m, y, k; /* each in [-1, 1] */
} GlimsSelectiveColorRange;

typedef enum {
  GLIMS_SELECTIVE_RED = 0,
  GLIMS_SELECTIVE_YELLOW,
  GLIMS_SELECTIVE_GREEN,
  GLIMS_SELECTIVE_CYAN,
  GLIMS_SELECTIVE_BLUE,
  GLIMS_SELECTIVE_MAGENTA,
  GLIMS_SELECTIVE_WHITE,
  GLIMS_SELECTIVE_NEUTRAL,
  GLIMS_SELECTIVE_BLACK,
  GLIMS_SELECTIVE_RANGE_COUNT
} GlimsSelectiveColorRangeIndex;

typedef struct {
  GlimsSelectiveColorRange ranges[GLIMS_SELECTIVE_RANGE_COUNT];
  bool                   relative; /* Photoshop "Relative" vs "Absolute" */
} GlimsSelectiveColorSettings;

/* True when every adjustment is finite and inside [-1,1]. */
bool glims_selective_color_settings_validate (const GlimsSelectiveColorSettings *settings);

/* count is a pixel count; each buffer holds 4*count floats. dst may equal
 * src for in-place processing; otherwise the buffers must not overlap.
 * Settings must already have passed validation. Neither buffer may be NULL
 * when count > 0. Impossible byte counts are refused without touching either
 * buffer. */
void glims_selective_color_apply (const GlimsSelectiveColorSettings *settings,
                                  const float *src, float *dst, size_t count);

#endif /* GLIMS_SELECTIVE_COLOR_MATH_H */
