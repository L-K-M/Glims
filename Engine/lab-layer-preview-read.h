/* Private alpha-correct sampling of the derived layered Lab preview. */
#ifndef GLIMS_LAB_LAYER_PREVIEW_READ_H
#define GLIMS_LAB_LAYER_PREVIEW_READ_H

#include "lab-layer-preview.h"

/* Engine thread only, with all source writes and other validation jobs finished.
 * Revalidates the carrier, consumes pending damage, then reads scaled image
 * coordinates using associated linear RGB. Unassociation happens AFTER spatial
 * filtering, with no alpha floor, clipping, transfer curve or ICC conversion.
 * Magnification between 1x and 2x uses bounded adapter-owned bilinear sampling
 * at global pixel centers. Other scales use GEGL's ordinary reduction/nearest
 * policy. Native BOX drops one corner, and native upscaled BILINEAR lacks the
 * required left/top sample halo; neither path is used in that zoom interval.
 * Output is straight linear-sRGB RGBA binary32; alpha zero is canonical +0 RGBA.
 * Very small alpha can lose color precision in the derived associated-float
 * cache. Authoritative Lab and alpha samples are never changed by this read.
 *
 * Scale and coordinate limits match the ordinary adapter renderer. Positive
 * dimensions and writable row strides are required; output may be unaligned.
 * The entire addressed output span is bounded to GLIMS_MAX_PIXEL_BUFFER_BYTES
 * and must not alias cache/native objects or their storage. Invalid arguments
 * leave output/cache untouched. Other failures may follow completed output
 * chunks: callers MUST discard the whole output unless the result is OK.
 * No document is adopted, and no image-sized scratch allocation is made. */
GlimsStatus glims_lab_layer_preview_read (GimpImage *image,
                                         GlimsLabLayerPreview **preview,
                                         double scale, GlimsRect area,
                                         void *rgba, size_t stride);

#endif
