#ifndef GLIMS_TRAP_MATH_H
#define GLIMS_TRAP_MATH_H

/* Pure Image > Trap kernel for native CMYK component documents. No GEGL,
 * GIMP or facade dependency, so the standalone harness can compile it
 * alone.
 *
 * Ink is coverage, not intensity: a fully inked pixel has coverage 1 and
 * paper has coverage 0. Darkness is the model in docs/trap.md, which
 * orders yellow lighter than cyan, cyan lighter than magenta, and every
 * color lighter than black. A neighbour inside the disk of `width` whole
 * pixels is lighter when its darkness is more than 1/512 below the
 * pixel's, and only lighter neighbours spread their C, M and Y coverage.
 * K never enters the output and is never written. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_TRAP_MAX_WIDTH 16u
#define GLIMS_TRAP_PLANES 4u

/* Computes the trapped C, M and Y coverage of one inner rectangle.
 *
 * `tile` is borrowed input: `tile_width` * `tile_height` pixels of four
 * interleaved float coverages (C, M, Y, K) in canonical order, row-major
 * without padding, so pixel (x, y) starts at (y * tile_width + x) * 4.
 * The inner rectangle (`inner_x`, `inner_y`, `inner_width`,
 * `inner_height`, in tile coordinates) names the pixels the call writes.
 * `valid` is the canvas rectangle in tile coordinates: samples inside the
 * tile but outside `valid` stand off the canvas and are never read as
 * neighbours. Every argument is borrowed until return.
 *
 * `out` receives `inner_width` * `inner_height` pixels of three
 * interleaved float coverages (C, M, Y) in canonical order, row-major
 * without padding. `winner` receives the same pixel count of three
 * interleaved indices: for each plane the linear tile index of the pixel
 * whose coverage the output holds, so a caller can recover the winning
 * sample exactly without a second neighbourhood walk. Both may be NULL
 * only when the inner rectangle is empty.
 *
 * Each inner pixel considers the neighbours (qx - px)^2 + (qy - py)^2
 * <= width^2, excluding the pixel itself, restricted to `valid`, and
 * keeps for each of C, M and Y the larger of its own coverage and the
 * coverage of every lighter neighbour. On equal coverage the neighbour
 * scanned first (lower row, then lower column) wins. The tile is never
 * modified.
 *
 * Returns false on invalid arguments: NULL tile, NULL out or winner with
 * a non-empty inner rectangle, a tile above 2^31 pixels (the int32_t
 * `winner` indices would wrap), width 0 or above GLIMS_TRAP_MAX_WIDTH, an inner rectangle that is not inside
 * `valid`, or a `valid` rectangle that is not inside the tile. Samples
 * must be finite coverage values in [0, 1]; the kernel does not clamp or
 * sanitize them. */
bool glims_trap_inner (const float *tile,
                       size_t tile_width, size_t tile_height,
                       size_t inner_x, size_t inner_y,
                       size_t inner_width, size_t inner_height,
                       size_t valid_x, size_t valid_y,
                       size_t valid_width, size_t valid_height,
                       uint32_t width,
                       float *out, int32_t *winner);

#endif /* GLIMS_TRAP_MATH_H */
