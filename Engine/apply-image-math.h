#ifndef GLIMS_APPLY_IMAGE_MATH_H
#define GLIMS_APPLY_IMAGE_MATH_H

/* Pure blend kernel for Image > Apply Image and Image > Calculations. No
 * GEGL, GIMP or GLib dependency beyond the facade's own enums, so the
 * standalone harness compiles it alone.
 *
 * Pixels are straight (non-premultiplied) nonlinear sRGB RGBA floats in
 * 0...1. The separable functions B(cb, cs) follow the W3C "Compositing and
 * Blending Level 1" specification
 * (https://www.w3.org/TR/compositing-1/#blending), with cb the backdrop
 * (target) and cs the source: normal, multiply, screen, overlay, darken,
 * lighten, hard-light, soft-light, difference and exclusion use the spec's
 * formulas. Add and Subtract are this command's own:
 * (cb +/- cs) / scale + offset, clamped like every other result. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "glims_engine.h"

/* The numeric fields shared by both commands' settings. The facade owns
 * the wire structs; this is the kernel-owned copy the engine validates and
 * passes to glims_ai_apply. */
typedef struct {
  uint32_t mode;             /* GlimsBlendMode */
  double   opacity;          /* finite (0,1] */
  double   scale;            /* finite [1,2], Add and Subtract only */
  double   offset;           /* finite [-1,1], Add and Subtract only */
  uint32_t invert_source;    /* exactly 0 or 1; inverts the source RGB */
  uint32_t invert_mask;      /* exactly 0 or 1; inverts the mask value */
} GlimsAIMath;

/* True when the settings satisfy every rule the facade promises: a known
 * mode, finite opacity inside (0,1], finite scale inside [1,2], finite
 * offset inside [-1,1] and exact 0/1 inversion flags. Scale and offset are
 * checked for every mode, including those that ignore them. */
bool glims_ai_settings_valid (const GlimsAIMath *math);

/* One channel's blend result B(cb, cs), clamped to [0,1]. Unknown modes
 * answer the source, which is never reachable through a validated struct. */
float glims_ai_blend (double backdrop, double source, uint32_t mode,
                      double scale, double offset);

/* Rec. 601 luma of nonlinear sRGB components, the same weights Color Range
 * uses: (299 r + 587 g + 114 b) / 1000, clamped to [0,1]. */
float glims_ai_luma (double red, double green, double blue);

/* Blends `count` pixels. `backdrop` and `source` are `count` RGBA floats;
 * `mask` and `selection` are `count` scalars or NULL (meaning all ones).
 * The result follows the per-pixel rule
 *   w = opacity * mask * selection * source alpha
 *   out.rgb = cb + w * (B(cb, cs) - cb)
 *   out.a = cb.a
 * Source Invert flips the source color before blending; mask Invert flips
 * the mask value before the selection limit. The target alpha is copied,
 * never blended. `out` must not alias `backdrop` or `source`. */
void glims_ai_apply (const GlimsAIMath *math,
                     const float *backdrop, const float *source,
                     const float *mask, const float *selection,
                     size_t count, float *out);

#endif /* GLIMS_APPLY_IMAGE_MATH_H */
