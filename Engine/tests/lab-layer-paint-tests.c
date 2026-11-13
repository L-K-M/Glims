#include "lab-layer-paint.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main(void)
{
  uint8_t input[4][4] = { {0, 64, 128, 255}, {9, 128, 255, 1},
                           {7, 128, 0, 1}, {0, 0, 128, 255} };
  uint8_t original[sizeof input]; memcpy(original, input, sizeof input);
  uint8_t output[4][4]; memset(output, 0xa5, sizeof output);
  const uint8_t *source[4] = {input[0], input[1], input[2], input[3]};
  uint8_t *destination[4] = {output[0], output[1], output[2], output[3]};
  float masks[4] = {0, 1, .5f, 1};
  bool changed = false;
  CHECK(glims_lab_layer_paint_row(4, source, masks, 100, 127, -128, 1, destination, &changed));
  CHECK(changed && !memcmp(input, original, sizeof input));
  for (unsigned c = 0; c < 4; c++) CHECK(output[c][0] == input[c][0]);
  CHECK(output[0][1] == 255 && output[1][1] == 255 && output[2][1] == 0 && output[3][1] == 255);
  CHECK(output[0][3] == 255 && output[1][3] == 255 && output[2][3] == 0 && output[3][3] == 255);
  CHECK(output[3][2] == 192); /* 0.5 over 128/255 alpha. */
  CHECK(output[0][2] == 213 && output[1][2] == 255 && output[2][2] == 0);

  /* Zero opacity preserves invisible stored color, without creating a change. */
  memset(output, 0xa5, sizeof output); changed = true;
  CHECK(glims_lab_layer_paint_row(4, source, NULL, 50, 0, 0, 0, destination, &changed));
  CHECK(!changed && !memcmp(input, output, sizeof input));
  changed = true;
  CHECK(glims_lab_layer_paint_row(1, source, NULL, 50, 0, 0, 1.0/1024, destination, &changed));
  CHECK(!changed && output[0][0] == input[0][0] && output[3][0] == 0);

  /* Late invalid coverage cannot leak any partial output. */
  masks[3] = NAN; memset(output, 0xa5, sizeof output); changed = true;
  CHECK(!glims_lab_layer_paint_row(4, source, masks, 50, 0, 0, 1, destination, &changed));
  uint8_t sentinel[sizeof output]; memset(sentinel, 0xa5, sizeof sentinel);
  CHECK(!memcmp(output, sentinel, sizeof output) && !changed);
  masks[3] = 1;
  CHECK(!glims_lab_layer_paint_row(4, source, masks, INFINITY, 0, 0, 1, destination, &changed));
  CHECK(!memcmp(output, sentinel, sizeof output));
  CHECK(!glims_lab_layer_paint_row(GLIMS_LAB_LAYER_PAINT_MAX_WIDTH + 1u, source, NULL, 50, 0, 0, 1, destination, &changed));

  /* Matching in-place pairs are allowed; cross-plane/output aliasing is not. */
  uint8_t *in_place[4] = {input[0], input[1], input[2], input[3]};
  CHECK(glims_lab_layer_paint_row(4, source, masks, 100, 127, -128, 1, in_place, &changed));
  CHECK(changed && !memcmp(input[0], (uint8_t[]){0,255,213,255}, 4));
  memcpy(input, original, sizeof input);
  destination[1] = output[0]; memset(output, 0xa5, sizeof output);
  CHECK(!glims_lab_layer_paint_row(4, source, NULL, 50, 0, 0, 1, destination, &changed));
  CHECK(!memcmp(output, sentinel, sizeof output));
  destination[1] = output[1]; destination[0] = input[1];
  CHECK(!glims_lab_layer_paint_row(4, source, NULL, 50, 0, 0, 1, destination, &changed));
  CHECK(!memcmp(input, original, sizeof input));
  destination[0] = output[0];
  CHECK(!glims_lab_layer_paint_row(4, source, NULL, 50, 0, 0, 1, destination, (bool *)&output[0][0]));
  CHECK(!memcmp(output, sentinel, sizeof output));
  CHECK(!glims_lab_layer_paint_row(4, source, masks, 50, 0, 0, 1, destination, (bool *)&input[0][0]));
  CHECK(!memcmp(input, original, sizeof input));
  destination[3] = (uint8_t *)masks;
  CHECK(!glims_lab_layer_paint_row(4, source, masks, 50, 0, 0, 1, destination, &changed));
  CHECK(masks[0] == 0 && masks[3] == 1);
  destination[3] = output[3];
  unsigned char unaligned[sizeof masks + 1]; memcpy(unaligned + 1, masks, sizeof masks);
  CHECK(glims_lab_layer_paint_row(4, source, unaligned + 1, 100, 127, -128, 1, destination, &changed));
  CHECK(changed && output[3][1] == 255 && output[3][2] == 192);
  const uint8_t *empty_sources[4] = {NULL, NULL, NULL, NULL};
  uint8_t *empty_destinations[4] = {NULL, NULL, NULL, NULL}; changed = true;
  CHECK(glims_lab_layer_paint_row(0, empty_sources, NULL, 50, 0, 0, 1, empty_destinations, &changed) && !changed);
  printf("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
