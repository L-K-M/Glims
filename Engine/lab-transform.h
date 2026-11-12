/* Private D50 Lab/linear-sRGB primitives. Do not admit documents or edits. */
#ifndef GLIMS_LAB_TRANSFORM_H
#define GLIMS_LAB_TRANSFORM_H

#include <stdbool.h>
#include <stddef.h>

typedef struct GlimsLabTransform GlimsLabTransform;

/* Owns the D50-adapted linear-sRGB matrix matching Glims' component preview
 * space. Construction uses an isolated LittleCMS context; no global handlers
 * or settings are changed. Free accepts NULL. */
GlimsLabTransform *glims_lab_transform_new (void);
void glims_lab_transform_free (GlimsLabTransform *transform);

/* Interleaved physical binary32 L*,a*,b* -> straight linear-sRGB RGBA with
 * alpha one. Signed/extended values are retained, without gamut clipping.
 * Nonfinite input or an RGB result outside finite binary32 refuses the whole
 * row before writing. This intentionally refuses extreme, unrenderable Lab
 * values that remain valid authoritative samples in lab-samples.h.
 *
 * At most 4096 pixels per call. Zero count permits NULL buffers but still
 * requires a transform. Buffers may be unaligned; their ranges must not
 * overlap. No allocation or mutable state during conversion. */
bool glims_lab_transform_pixels (const GlimsLabTransform *transform,
                                 const void *lab, size_t count, void *rgba);

/* Interleaved straight linear-sRGB binary32 R,G,B -> physical D50 binary32
 * L*,a*,b*. The input is already linear: no transfer curve, alpha handling,
 * or clipping is applied. Finite signed/extended values are supported unless
 * the physical Lab result is outside finite binary32. Nonfinite input or an
 * unrepresentable result refuses the whole row before writing.
 *
 * At most 4096 pixels per call. Zero count permits NULL buffers but still
 * requires a transform. Buffers may be unaligned; their ranges must not
 * overlap or overflow the address space. All borrowed input and the transform
 * must remain alive and unchanged until return. No allocation or mutable
 * transform state during conversion. */
bool glims_lab_transform_from_linear_rgb (const GlimsLabTransform *transform,
                                          const void *rgb, size_t count,
                                          void *lab);

#endif
