/* Private bounded, streaming grayscale error diffusion. No GIMP dependency. */
#ifndef GLIMS_BITMAP_DIFFUSION_H
#define GLIMS_BITMAP_DIFFUSION_H
#include <stdbool.h>
#include <stdint.h>

#define GLIMS_BITMAP_DIFFUSION_MAX_DIMENSION 30000u

typedef struct {
  uint32_t width, height, next_x, next_y;
  double *current, *next;
} GlimsBitmapDiffusion;

/* Initialize a zeroed, unused state. The state owns two padded rows of error
 * until end(); each dimension must be in 1..30000. No image is allocated. */
bool glims_bitmap_diffusion_begin (GlimsBitmapDiffusion *state, uint32_t width, uint32_t height);
/* Input contains finite grayscale samples in [0,1] with alpha handled by the
 * caller. Requests must cover each row in order, left to right, with no gaps.
 * Output is 0 (black) or 255 (white), using a 0.5 decision and Floyd-Steinberg
 * error weights. Input, output and state storage must not overlap. Refusals
 * validate the whole chunk before modifying output or the diffusion state. */
bool glims_bitmap_diffusion_apply (GlimsBitmapDiffusion *state, uint32_t y, uint32_t x,
                                    uint32_t count, const float *input, uint8_t *output);
/* Release owned rows. Safe on a zeroed state and safe to call repeatedly. */
void glims_bitmap_diffusion_end (GlimsBitmapDiffusion *state);
#endif
