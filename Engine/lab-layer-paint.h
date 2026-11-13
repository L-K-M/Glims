#ifndef GLIMS_LAB_LAYER_PAINT_H
#define GLIMS_LAB_LAYER_PAINT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_LAB_LAYER_PAINT_MAX_WIDTH 4096u

/* Blend a constant physical Lab color over four straight-alpha U8 planes.
 * coverage is an optional row of unaligned floats in [0,1]; NULL means full
 * coverage. A zero effective opacity preserves all original bytes, including
 * hidden color under zero alpha. The output is staged: invalid input leaves
 * every destination byte untouched. Exact in-place source/destination pairs
 * are allowed; all other output overlaps are refused. */
bool glims_lab_layer_paint_row(size_t width, const uint8_t *const source[4],
                               const void *coverage, double lightness,
                               double a, double b, double opacity,
                               uint8_t *const destination[4], bool *changed);

#endif
