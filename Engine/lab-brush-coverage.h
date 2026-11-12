#ifndef GLIMS_LAB_BRUSH_COVERAGE_H
#define GLIMS_LAB_BRUSH_COVERAGE_H

#include <stdbool.h>
#include <stddef.h>

/*
 * Glims brush coverage accumulation (Glims coverage rule only; this does not
 * claim Photoshop parity or native/engine bit parity).
 *
 * All three arrays are native IEEE binary32 sample sequences and may be
 * unaligned; every sample access is performed with memcpy.
 *
 * For each sample i:
 *   - previous[i] must be finite and in [0, 1].
 *   - generated_mask[i] must be finite; finite values outside [0, 1] are
 *     intentionally clamped before use (actual native mask undershoot such as
 *     -0x1.172ap-53 has been observed).
 *   - output_i = fma(1.0 - (double)previous_i, (double)clamped_mask_i,
 *                    (double)previous_i), rounded once to float.
 *
 * If the clamped mask is exactly 0, destination[i] receives the exact previous
 * bits copied unchanged, including negative zero. A full mask produces 1, and
 * previous 1 remains 1. This function performs arithmetic coverage accumulation
 * only; it does not apply selection or opacity multiplication.
 *
 * Validation/behavior:
 *  - count == 0 succeeds with NULL pointers and performs no accesses.
 *  - count > 4096 is refused.
 *  - for nonzero count all three pointers are required.
 *  - checked uintptr end ranges for previous, generated_mask and destination
 *    must not wrap before any access.
 *  - the destination range must be disjoint from BOTH input ranges; the two
 *    input ranges may overlap each other.
 *  - all inputs/results are validated before the first destination write; on
 *    any invalid/nonfinite input or result the entire destination range is left
 *    unchanged, even if the bad sample is last.
 *  - no heap allocation is performed and no input buffer is mutated.
 *
 * Storage contract: previous, generated_mask and destination must remain valid
 * (readable/writable as required), unmodified by other agents, and stable for
 * the duration of the call. No reentrancy or concurrency contract is provided.
 */
bool glims_lab_brush_coverage(size_t count, const void *previous,
                              const void *generated_mask, void *destination);

#endif
