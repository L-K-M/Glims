#ifndef GLIMS_COLOR_RANGE_MATH_H
#define GLIMS_COLOR_RANGE_MATH_H

/* Pure Select > Color Range weight kernel. No GEGL, GIMP or facade
 * dependency, so the standalone harness can compile it alone.
 *
 * Pixels are straight (non-premultiplied) nonlinear sRGB RGBA float
 * quadruples, channels clamped to [0,1] before comparison. Samples are
 * clamped the same way; they may hold finite values slightly outside the
 * range, as a wide-gamut source read does; a NaN channel counts as 0. A
 * fully transparent projection pixel has weight 0 before Invert, so Invert
 * selects it (docs/color-range.md). The ramp, the hue sectors and the luma bands
 * mirror the dialog's math in docs/color-range.md. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The dialog's modes, distinct from the facade enum so this header can be
 * included beside glims_engine.h without colliding with its constants. */
typedef enum {
  GLIMS_CR_SAMPLED = 1,
  GLIMS_CR_REDS,
  GLIMS_CR_YELLOWS,
  GLIMS_CR_GREENS,
  GLIMS_CR_CYANS,
  GLIMS_CR_BLUES,
  GLIMS_CR_MAGENTAS,
  GLIMS_CR_HIGHLIGHTS,
  GLIMS_CR_MIDTONES,
  GLIMS_CR_SHADOWS
} GlimsCRMode;

#define GLIMS_CR_MAX_SAMPLES 64u

typedef struct {
  double   red, green, blue;
  uint32_t subtract;             /* exactly 0 or 1 */
} GlimsCRSample;

typedef struct {
  uint32_t mode;                 /* GlimsCRMode */
  double   fuzziness;            /* finite 0...200; sampled modes only */
  uint32_t invert;               /* exactly 0 or 1 */
  size_t   sample_count;
  const GlimsCRSample *samples;  /* borrowed; NULL when sample_count is 0 */
} GlimsCRSettings;

/* True when the settings satisfy every rule the facade promises: a known
 * mode, finite fuzziness inside 0...200, an exact 0/1 invert, at most 64
 * finite samples, no samples in a fixed mode and at least one add sample in
 * Sampled Colors. */
bool glims_cr_settings_valid (const GlimsCRSettings *settings);

/* One pixel's weight after clamping, transparency, Invert and the optional
 * per-pixel selection limit (NULL, or a float in 0...1). */
float glims_cr_weight (const float rgba[4], const GlimsCRSettings *settings,
                       const float *selection);

/* Fills `out` with `count` weights from `rgba`, four floats per pixel.
 * `selection` is NULL or `count` floats. The buffers must not overlap. */
void glims_cr_apply (const GlimsCRSettings *settings,
                     const float *rgba, size_t count,
                     const float *selection, float *out);

#endif /* GLIMS_COLOR_RANGE_MATH_H */
