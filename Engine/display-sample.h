/* Private reusable spatial sampling before ICC/proof conversion. */
#ifndef GLIMS_DISPLAY_SAMPLE_H
#define GLIMS_DISPLAY_SAMPLE_H
#include "engine-private.h"

typedef struct GlimsDisplaySample GlimsDisplaySample;
/* Exact same-space straight RGBA float or YA float encoding is required.
 * Source may use another straight RGB/gray alpha precision/TRC in that space.
 * An associated source is accepted only in the exact matching linear float
 * format, copied without a Babl alpha-floor conversion. Negative extent origins
 * and empty extents are supported. Owns source/cache/native-validator refs. */
GlimsDisplaySample *glims_display_sample_new (GeglBuffer *source,
                                             const Babl *same_space_straight_linear_format);
/* Prepare once per serialized display epoch. Reuses only the exact source,
 * native/linear formats, extent and assigned native validator, with no sticky
 * failure. Replaces on change/failure; construction refusal clears *cache.
 * Source mutations are allowed BETWEEN epochs. Parent stops/flushes native
 * projection work before prepare, then forbids writes/async jobs/nested reads
 * through the last read. Destination/proof/scale are not source-cache keys. */
GlimsStatus glims_display_sample_prepare (GeglBuffer *source,
                                         const Babl *same_space_straight_linear_format,
                                         GlimsDisplaySample **cache);
/* Quiescent engine thread, before source image/preview teardown. Not a join. */
void glims_display_sample_free (GlimsDisplaySample *sample);
/* Synchronous engine thread only, no graph attachment or concurrent access.
 * Supports 2^-20<=scale<1 and 1<scale<2, existing 2^26 source-coordinate/512MiB
 * output caps. Global standard-center bilinear samples associated linear native
 * mip pixels through integer tile coordinates, avoiding native float ROI math.
 * Native levels0..4 are reused directly. Higher levels use sparse DOUBLE means
 * of intersecting level4 cells divided by the full block area including zeros;
 * their rounding can differ from native deeper mip recursion. No empty quadtree
 * traversal or image-sized scratch is needed. Source keys are rechecked;
 * a change since prepare refuses without output.
 *
 * Straight linear output may be unaligned; stride is in bytes. Writable range
 * must not alias source/cache/object storage. Invalid arguments leave output
 * untouched. A later runtime failure may leave earlier completed chunks; caller
 * discards failed scratch. Failure remains sticky until prepare replaces cache.
 * Caller also checks source-specific validator flags. Finite signed/extended
 * colors and alpha outside 0..1 are not clamped. True association/unassociation
 * refuses nonfinite or float-unrepresentable results; alpha 0 is positive zero.
 * Float association underflow can lose color. Extreme finite native mip sums
 * may overflow and return FAILED. */
GlimsStatus glims_display_sample_read (GlimsDisplaySample *sample, double scale,
                                      GlimsRect area, void *straight_linear, size_t stride);
#endif
