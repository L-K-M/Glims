#include "bitmap-diffusion.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

bool
glims_bitmap_diffusion_begin (GlimsBitmapDiffusion *state, uint32_t width, uint32_t height)
{
  if (!state || state->current || state->next || !width || !height ||
      width > GLIMS_BITMAP_DIFFUSION_MAX_DIMENSION || height > GLIMS_BITMAP_DIFFUSION_MAX_DIMENSION)
    return false;
  size_t cells = (size_t) width + 2u;
  double *current = calloc (cells, sizeof *current);
  double *next = calloc (cells, sizeof *next);
  if (!current || !next) { free (current); free (next); return false; }
  *state = (GlimsBitmapDiffusion) { .width = width, .height = height,
                                    .current = current, .next = next };
  return true;
}

bool
glims_bitmap_diffusion_apply (GlimsBitmapDiffusion *state, uint32_t y, uint32_t x,
                              uint32_t count, const float *input, uint8_t *output)
{
  if (!state || !state->current || !state->next || !input || !output || !count ||
      y != state->next_y || x != state->next_x || y >= state->height ||
      x >= state->width || count > state->width - x)
    return false;
  for (uint32_t i = 0; i < count; i++)
    if (!isfinite (input[i]) || input[i] < 0.0f || input[i] > 1.0f)
      return false;
  for (uint32_t i = 0; i < count; i++)
    {
      size_t pos = (size_t) x + i + 1u;
      double corrected = (double) input[i] + state->current[pos];
      double quantized = corrected >= 0.5 ? 1.0 : 0.0;
      double error = corrected - quantized;
      output[i] = quantized != 0.0 ? 255 : 0;
      state->current[pos + 1u] += error * (7.0 / 16.0);
      state->next[pos - 1u] += error * (3.0 / 16.0);
      state->next[pos] += error * (5.0 / 16.0);
      state->next[pos + 1u] += error * (1.0 / 16.0);
    }
  state->next_x += count;
  if (state->next_x == state->width)
    {
      double *old = state->current;
      state->current = state->next;
      state->next = old;
      memset (state->next, 0, ((size_t) state->width + 2u) * sizeof *state->next);
      state->next_x = 0;
      state->next_y++;
    }
  return true;
}

void
glims_bitmap_diffusion_end (GlimsBitmapDiffusion *state)
{
  if (!state) return;
  free (state->current); free (state->next);
  *state = (GlimsBitmapDiffusion) { 0 };
}
