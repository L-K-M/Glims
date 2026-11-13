#ifndef GLIMS_LAB_CURVES_H
#define GLIMS_LAB_CURVES_H

#include <stdbool.h>
#include <stddef.h>

#include "lab-samples.h"

#define GLIMS_LAB_CURVES_MAX_SAMPLES 4096u

/*
 * Private pure-C11 normalized lookup curves for one PHYSICAL Lab row.
 * This does not enable Lab Curves as an app feature.
 */
typedef struct {
  /* Settings table always exactly 256 finite normalized [0,1] values;
   * independent of role. Canonical identity is exact sample[i]==(double)i/255. */
  double samples[256];
} GlimsLabCurve;

/*
 * Apply normalized lookup curves to one physical Lab row.
 *
 * Contract (documented):
 * - Max 4096 samples, no heap allocation/I/O.
 * - Source/destination/mask/curve/changed may be unaligned.
 * - Exact in-place is allowed for source/destination.
 * - All other overlaps among source,dest,mask,curve,changed refuse before writes
 * - count==0 permits NULL source/dest/mask but requires valid role/format/curve/changed.
 * - Full staging/validation makes late failure atomic.
 * - changed is false on errors unless it overlaps protected input/output.
 *   Invalid format/count has no accepted sample range; exact aliases and
 *   any settings overlap are still protected.
 * - Settings table always exactly 256 finite normalized [0,1] values; independent of role.
 *   Canonical identity is exact sample[i]==(double)i/255.
 * - Validate all settings/masks even no-op.
 * - Mask NULL==full (all 1.0); finite unit masks only in [0,1].
 *
 * Processing per affected sample:
 * - Decode to physical double via unchanged lab-samples.
 * - Reject nonfinite affected float even identity.
 * - coverage==0 copies raw bytes (including NaN/Inf/-0).
 * - Identity preserves every finite raw encoding including extended float/-0.
 * - For nonidentity integer source, lookup position is raw U8 code or
 *   U16 quotient/257 + remainder/257, avoiding early U8 quantization.
 * - Float input position normalized by L/100 or (a_or_b+128)/255; out-of-nominal
 *   inputs use endpoint samples.
 * - Linear interpolation rounds subtraction, multiplication and addition
 *   separately in double; exact U8 table indexing;
 *   U16 fraction = remainder/257.
 * - Map normalized output to physical with fma(scale,lookup,offset) where
 *   L scale 100 offset 0, a/b scale 255 offset -128.
 * - No artificial native ink/full-ink orientation.
 * - If mapped physical target == decoded source preserve original bytes.
 * - Blend physical output using same explicit lab-fill rule
 *   fma(weight,target,(1-weight)*source), full weight exact target,
 *   repair roundoff to convex interval endpoints, then existing lab-samples
 *   encoding ONCE.
 * - Float must remain finite/in FLT_MAX. No gamut clipping.
 * - Represented-double arithmetic, not exact rational/Photoshop spline equivalence.
 * - Nonidentity float out-of-range maps endpoints; identity preserves them.
 * - Borrowed inputs remain alive and immutable until the call returns.
 */
bool glims_lab_curves_row(GlimsLabRole role,
                          GlimsLabFormat format,
                          const GlimsLabCurve *curve,
                          size_t count,
                          const void *source,
                          const float *mask,
                          void *destination,
                          bool *changed);

#endif /* GLIMS_LAB_CURVES_H */
