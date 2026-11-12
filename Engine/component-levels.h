/* Pure numeric component levels row calculation. No allocation.
 *
 * Semantic reference (scalar mapping):
 *   pinned GIMP 3.2.8 app/operations/gimpoperationlevels.c:95
 *   gimp_operation_levels_map
 *
 * This kernel owns scalar precision and does not claim bitwise GIMP/RGB
 * equivalence.
 */
#ifndef GLIMS_COMPONENT_LEVELS_H
#define GLIMS_COMPONENT_LEVELS_H

#include "component-scalar.h"
#include <stdint.h>

typedef struct
{
  double   low_input;
  double   high_input;
  double   gamma;
  double   low_output;
  double   high_output;
  uint32_t clamp_input;
  uint32_t clamp_output;
} GlimsComponentLevels;

/* Intensity 0 is ink, 1 is paper. Endpoint fields must be finite [0,1], gamma
 * finite [0.1,10], and clamp flags exactly 0 or 1. All endpoint combinations are
 * permitted, including reversed or equal input/output endpoints.
 *
 * Mapping: t = (I-low_input)/(high_input-low_input) if unequal, else
 * I-low_input. Optional input clamp to [0,1]. If gamma!=1 and t>0 then
 * pow(t,1/gamma); negative or zero t is unchanged. Output is
 * low_output + t*(high_output-low_output) with optional output clamp to [0,1].
 * The mapped value is blended with the original exactly once at mask coverage
 * (NULL mask means full coverage).
 *
 * Zero coverage preserves source bytes exactly, including NaN, -0 and Inf. All
 * mask samples must be finite [0,1], even when settings are an identity. Any
 * affected source sample must be finite. Any non-finite arithmetic intermediate
 * or result, or final float overflow, rejects the entire row before any
 * destination write; destination is unchanged and *changed is false on failure.
 *
 * Zero count accepts NULL source/destination, but format, settings and changed
 * must still be valid. count*sample-size and mask byte-count overflow are
 * rejected. No allocation; fixed locals only.
 *
 * Source == destination is supported. Every other overlap among source, mask,
 * destination, settings and changed is unsupported. Source and
 * destination may be unaligned (values are loaded/stored via memcpy). *changed
 * is computed by raw-byte comparison. Borrowed memory is only read/written
 * during this call.
 *
 * Integer results are bounded [0,255/65535] and rounded to nearest, half up.
 * Float results may remain finite extended values; clamping applies to the
 * mapped target before coverage blending, not to the original sample. Identity
 * mappings must preserve finite source bytes (including -0) and avoid phantom
 * history, but clamps must still affect out-of-range float values.
 */
bool glims_component_levels_row (GlimsComponentScalarFormat   format,
                                 const GlimsComponentLevels  *settings,
                                 size_t                       count,
                                 const void                  *source,
                                 const float                 *mask,
                                 void                        *destination,
                                 bool                        *changed);

#endif /* GLIMS_COMPONENT_LEVELS_H */
