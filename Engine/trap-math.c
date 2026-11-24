/* Pure Image > Trap kernel; see trap-math.h and docs/trap.md. */
#include "trap-math.h"

/* One pixel's display-independent darkness from its four coverages:
 * R = (1-c)(1-k), G = (1-m)(1-k), B = (1-y)(1-k), then
 * D = 1 - (0.2126 R + 0.7152 G + 0.0722 B). */
static double
trap_darkness (const float *sample)
{
  double k = 1.0 - (double) sample[3];
  double r = (1.0 - (double) sample[0]) * k;
  double g = (1.0 - (double) sample[1]) * k;
  double b = (1.0 - (double) sample[2]) * k;
  double l = 0.2126 * r + 0.7152 * g + 0.0722 * b;

  return 1.0 - l;
}

bool
glims_trap_inner (const float *tile,
                  size_t tile_width, size_t tile_height,
                  size_t inner_x, size_t inner_y,
                  size_t inner_width, size_t inner_height,
                  size_t valid_x, size_t valid_y,
                  size_t valid_width, size_t valid_height,
                  uint32_t width,
                  float *out, int32_t *winner)
{
  if (! tile || ((! out || ! winner) && inner_width && inner_height))
    return false;
  /* `winner` holds int32_t linear indices, so a tile above 2^31 pixels would
   * wrap them; refuse it instead of corrupting the indices silently. The
   * double product cannot overflow size_t on any supported platform. */
  if ((double) tile_width * (double) tile_height > (double) INT32_MAX)
    return false;
  if (! width || width > GLIMS_TRAP_MAX_WIDTH)
    return false;
  if (valid_x > tile_width || valid_y > tile_height ||
      valid_width > tile_width - valid_x || valid_height > tile_height - valid_y)
    return false;
  if (inner_x < valid_x || inner_y < valid_y ||
      inner_width > valid_width || inner_x - valid_x > valid_width - inner_width ||
      inner_height > valid_height || inner_y - valid_y > valid_height - inner_height)
    return false;

  int radius = (int) width;
  int limit = radius * radius;

  for (size_t row = 0; row < inner_height; row++)
    {
      ptrdiff_t cy = (ptrdiff_t) (inner_y + row);
      ptrdiff_t dy_low = (ptrdiff_t) valid_y - cy;
      ptrdiff_t dy_high = (ptrdiff_t) (valid_y + valid_height) - 1 - cy;

      if (dy_low < -radius) dy_low = -radius;
      if (dy_high > radius) dy_high = radius;

      for (size_t column = 0; column < inner_width; column++)
        {
          ptrdiff_t cx = (ptrdiff_t) (inner_x + column);
          size_t self = (size_t) cy * tile_width + (size_t) cx;
          const float *p = tile + self * GLIMS_TRAP_PLANES;
          float *dst = out + (row * inner_width + column) * 3;
          int32_t *who = winner + (row * inner_width + column) * 3;
          double darkness = trap_darkness (p);
          double lighter = darkness - 1.0 / 512.0;
          double best[3] = { p[0], p[1], p[2] };
          size_t index[3] = { self, self, self };
          ptrdiff_t dx_low = (ptrdiff_t) valid_x - cx;
          ptrdiff_t dx_high = (ptrdiff_t) (valid_x + valid_width) - 1 - cx;

          if (dx_low < -radius) dx_low = -radius;
          if (dx_high > radius) dx_high = radius;

          for (ptrdiff_t dy = dy_low; dy <= dy_high; dy++)
            {
              const float *q = tile + (size_t) (cy + dy) * tile_width * GLIMS_TRAP_PLANES;
              ptrdiff_t edge = limit - dy * dy;

              for (ptrdiff_t dx = dx_low; dx <= dx_high; dx++)
                {
                  const float *sample;
                  size_t plane;

                  if ((dx == 0 && dy == 0) || dx * dx > edge)
                    continue;
                  sample = q + (size_t) (cx + dx) * GLIMS_TRAP_PLANES;
                  if (trap_darkness (sample) >= lighter)
                    continue;
                  for (plane = 0; plane < 3; plane++)
                    if ((double) sample[plane] > best[plane])
                      {
                        best[plane] = sample[plane];
                        index[plane] = (size_t) (cy + dy) * tile_width + (size_t) (cx + dx);
                      }
                }
            }

          dst[0] = (float) best[0];
          dst[1] = (float) best[1];
          dst[2] = (float) best[2];
          who[0] = (int32_t) index[0];
          who[1] = (int32_t) index[1];
          who[2] = (int32_t) index[2];
        }
    }

  return true;
}
