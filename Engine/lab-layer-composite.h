#ifndef GLIMS_LAB_LAYER_COMPOSITE_H
#define GLIMS_LAB_LAYER_COMPOSITE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_LAB_LAYER_COMPOSITE_MAX_LAYERS 256u
#define GLIMS_LAB_LAYER_COMPOSITE_MAX_WIDTH 4096u

/*
 * One immutable U8 physical-Lab source layer row, in top-to-bottom order inside
 * the descriptor array passed to glims_lab_layer_composite_row. Each plane is a
 * row of width bytes (or NULL only when width == 0). Sample buffers may be
 * unaligned and may alias other sample buffers in the same or different
 * descriptors; they must remain readable for the duration of the call.
 *
 * Physical decoding is derived from raw bytes:
 *   L  = 100 * qL    / 255
 *   a  = qA - 128
 *   b  = qB - 128
 *   A  = qAlpha / 255
 * Effective layer alpha for compositing is A * opacity. The caller-owned bytes
 * are never rewritten or requantized.
 */
typedef struct {
  const uint8_t *l;
  const uint8_t *a;
  const uint8_t *b;
  const uint8_t *alpha;
  double opacity;
} GlimsLabLayerCompositeLayer;

/*
 * Composite an immutable array of layer_count U8 physical-Lab source rows over
 * transparency and write width interleaved straight/unpremultiplied physical
 * Lab pixels (L, a, b, alpha) as binary64 doubles to destination. destination
 * may be unaligned. The descriptor array is interpreted in top-to-bottom order.
 *
 * For each pixel, effective source alpha is (qAlpha / 255) * finite opacity in
 * [0, 1], decoded in binary64. The kernel accumulates front-to-back weights
 * until the result becomes opaque (accumulated alpha >= 1.0 in the binary64
 * accumulation), maintaining the normalized weighted color mean without tiny
 * color-times-alpha underflow. Effective alpha itself is computed in binary64
 * and may underflow to zero. The published alpha is clamped to [0, 1].
 * An entirely transparent result is the
 * canonical transparent black value (+0.0, +0.0, +0.0, +0.0). This is a derived
 * display composite only: no Photoshop bit-identity is claimed, and integer
 * display/storage encodings are out of scope.
 *
 * Validation is exhaustive before any sample access or destination write:
 *  - layer_count <= 256 and width <= 4096.
 *  - every descriptor opacity is finite and in [0, 1], even when width == 0,
 *    when the layer is effectively transparent, or when it is hidden under an
 *    already-opaque prefix.
 *  - layer_count == 0 accepts a NULL descriptor array and, for positive width,
 *    writes a fully transparent row.
 *  - width == 0 accepts NULL destination and NULL per-layer sample planes, but
 *    still requires a readable, properly aligned descriptor array when
 *    layer_count > 0 and still validates every descriptor opacity.
 *  - for width > 0, destination and every descriptor sample plane must be
 *    non-NULL.
 *  - checked uintptr address ranges must not overflow for the descriptor array,
 *    destination, and every sample plane of every descriptor.
 *  - destination must not overlap any sample plane of any descriptor or the
 *    descriptor array itself, even for late/invisible layers or zero-effective-
 *    alpha planes. Sample planes may alias one another.
 *
 * Invalid calls leave the whole destination range unchanged (width == 0 has no
 * destination range). The implementation performs no heap allocation and no
 * general memory-mapping probes. Caller-owned descriptor storage must be
 * properly aligned readable memory for layer_count descriptors; sample and
 * destination buffers need only satisfy the unaligned-byte access described
 * above and remain valid for the call.
 */
bool glims_lab_layer_composite_row(size_t layer_count,
                                   size_t width,
                                   const GlimsLabLayerCompositeLayer *layers,
                                   void *destination);

#endif
