/* Private scalar ink curve evaluation. No GIMP types or allocation. */
#ifndef GLIMS_COMPONENT_CURVES_H
#define GLIMS_COMPONENT_CURVES_H

#include "component-scalar.h"

#define GLIMS_COMPONENT_CURVE_SAMPLES 256

typedef struct
{
  double samples[GLIMS_COMPONENT_CURVE_SAMPLES];
} GlimsComponentCurve;

/* Each finite [0,1] sample gives output intensity at input i/255: 0 is full
 * ink and 1 is paper. Outputs need not be monotone. Between samples use linear
 * interpolation; nonidentity curves use their endpoint values outside [0,1].
 * A canonical identity (every sample exactly (double)i/255) preserves all
 * finite source bytes, including extended float values and negative zero.
 * This is a scalar lookup-table contract, not Photoshop spline equivalence.
 *
 * U8 addresses the table directly. U16 uses index value/257 and remainder/257
 * within that segment, avoiding an intermediate U8 quantization. Float uses
 * its normalized intensity. Interpolation and coverage blending use double
 * arithmetic. Apply coverage exactly once, then round integer output to
 * nearest with half ties upward; float output is converted once to float.
 * A NULL mask means full coverage. All mask values must be finite [0,1].
 * Zero coverage copies source bytes, even NaN/Inf/-0. Affected float samples
 * must be finite, even for identity. Validate the whole row before writing:
 * any invalid format/settings/count/mask/source value returns false, leaves
 * destination untouched and sets *changed=false. Otherwise changed reports
 * a raw-byte difference from the source. A mapped value equal to the original
 * preserves its source bytes. Zero count accepts NULL source/destination;
 * format, curve and changed must still be valid.
 *
 * No allocation. Exact source==destination is supported; other overlaps
 * among source, destination, mask, curve and changed are unsupported. Source
 * and destination may be unaligned. Borrowed inputs remain immutable during
 * the call, apart from the explicitly supported in-place destination.
 */
bool glims_component_curves_row (GlimsComponentScalarFormat  format,
                                const GlimsComponentCurve *curve,
                                size_t                     count,
                                const void                *source,
                                const float               *mask,
                                void                      *destination,
                                bool                      *changed);

#endif /* GLIMS_COMPONENT_CURVES_H */
