#ifndef GLIMS_LAB_FILL_H
#define GLIMS_LAB_FILL_H

#include <stdbool.h>
#include <stddef.h>

#include "lab-samples.h"

#define GLIMS_LAB_FILL_MAX_COUNT 4096u

/*
 * Fill/blend one row of encoded Lab samples in the role/format's encoded
 * representation.
 *
 * For each sample i the effective weight is:
 *   w = (double)opacity * (double)(mask ? mask[i] : 1.0f)
 * computed in binary64. If w == 0.0 the encoded output byte(s) for sample i
 * are an exact copy of source[i] (raw bytes, including encoded NaN or -0.0 for
 * float samples) and the corresponding source sample value is not required to
 * be finite. If w > 0.0 the affected source sample must be finite and
 * representable by glims_lab_decode_row for role/format; its decoded physical
 * value p_i is blended with the requested physical_value v as:
 *   out_i = fma(w, v, (1.0 - w) * p_i)
 * with all terms evaluated in binary64. Roundoff outside the mathematical
 * convex interval [min(p_i,v),max(p_i,v)] is repaired to the nearest endpoint;
 * this is not Lab gamut/nominal clipping. Full weight (w == 1.0) writes the
 * exact requested endpoint v (after validation), avoiding cancellation through
 * the p_i term. Integer formats encode once from out_i using the same
 * mathematical half-up quantization and nominal ranges as glims_lab_encode_row
 * (no claim of exact Photoshop compatibility). Float format stores the finite
 * physical result by C conversion to float without clipping.
 *
 * Validation is exhaustive before any destination write:
 *  - role/format must be valid for lab-samples.
 *  - count <= 4096.
 *  - physical_value and opacity must be finite; opacity in [0, 1].
 *  - integer targets: L in [0,100], chroma in [-128,127]; float target
 *    magnitude <= FLT_MAX.
 *  - changed must be non-NULL.
 *  - count == 0 permits NULL source/destination/mask but still validates the
 *    settings above.
 *  - for count > 0, source and destination must be non-NULL; mask may be NULL
 *    (meaning 1.0 for every sample).
 *  - every mask value, when mask is present, must be finite and in [0,1],
 *    even when opacity is 0.
 *  - affected source samples (w > 0) must decode/validate as finite physical
 *    Lab samples for the role/format.
 *  - checked uintptr address ranges must not overflow for source, destination,
 *    mask, and changed.
 *  - source and destination may be the same range (in-place). Any other overlap
 *    between source and destination ranges is refused.
 *  - overlaps between source or destination ranges and the mask or changed
 *    objects are refused, including mask-vs-changed.
 *  - a changed pointer aliased with any source/destination sample byte or mask
 *    byte is refused without writing *changed (exception to the invalid-setting
 *    changed-clearing rule, because writing it would violate source/destination
 *    preservation).
 *  - invalid format or count > 4096 declares no accepted sample range; these
 *    settings fail before any buffer access. Exact pointer aliases with changed
 *    remain refused without writing; otherwise changed is cleared. Full range
 *    alias protection requires a valid format and bounded count.
 *
 * On a valid call *changed reports whether any output byte differs from the
 * corresponding source byte. On invalid settings with a non-aliased changed
 * object, *changed is cleared to false when possible without writing protected
 * ranges; NULL/aliased changed is refused without writing destination or
 * *changed. Late invalid input after a valid prefix leaves the entire
 * destination range unchanged. No heap allocation is performed. Source,
 * destination, mask and changed memory must remain valid (unaligned scalar
 * buffers are supported) and unaliased as
 * required for the duration of the call; no reentrancy or concurrency contract
 * is provided beyond that stability.
 */
bool glims_lab_fill_row(GlimsLabRole role,
                        GlimsLabFormat format,
                        double physical_value,
                        double opacity,
                        size_t count,
                        const void *source,
                        const float *mask,
                        void *destination,
                        bool *changed);

#endif
