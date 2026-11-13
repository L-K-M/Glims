#ifndef GLIMS_LAB_LEVELS_H
#define GLIMS_LAB_LEVELS_H

#include "lab-samples.h"
#include "component-levels.h"

/* Private analytic Levels on physical Lab samples. Endpoints are normalized
 * to the nominal axis interval: L* [0,100], a* and b* [-128,127]. This has
 * no ink/paper orientation. Gamma, endpoint and clamp domains and the equal
 * input endpoint fallback match GlimsComponentLevels. A normalized fallback
 * span of one means a whole physical axis interval, not one physical unit.
 */
typedef GlimsComponentLevels GlimsLabLevels;

#define GLIMS_LAB_LEVELS_MAX_SAMPLES 4096

/* Map normalized n = lightness/100 or (chroma+128)/255 through analytic Levels,
 * then blend the physical proposal with the source once at mask coverage.
 * No normalized float intermediate or 256-entry lookup approximation is used.
 * Integer output clips and quantizes only after blending; finite float output
 * may remain outside the nominal interval when the clamp flags permit it.
 * Exact identity preserves raw finite samples, including extended floats and
 * signed zero, unless a requested clamp changes them. Zero mask preserves
 * every source byte, including NaN and infinity. Affected nonfinite samples,
 * nonfinite arithmetic, and final float overflow refuse the complete row.
 *
 * Count is bounded above. Every pointer may be unaligned. Exact in-place
 * source/destination is supported; all other overlaps among settings, mask,
 * source, destination and changed refuse before writes. Settings and masks
 * are validated even for identities. Count zero permits NULL sample buffers
 * but still validates role, format and settings. On refusal destination stays
 * unchanged and changed becomes false unless it aliases protected storage.
 * Borrowed input memory must remain immutable and alive for the call.
 */
bool glims_lab_levels_row (GlimsLabRole role, GlimsLabFormat format,
                           const GlimsLabLevels *settings, size_t count,
                           const void *source, const float *mask,
                           void *destination, bool *changed);

#endif
