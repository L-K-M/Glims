/* Pure numeric ink-row calculation. No color-space conversion or allocation. */
#ifndef GLIMS_COMPONENT_SCALAR_H
#define GLIMS_COMPONENT_SCALAR_H
#include <stdbool.h>
#include <stddef.h>

typedef enum {
  GLIMS_COMPONENT_SCALAR_U8,
  GLIMS_COMPONENT_SCALAR_U16,
  GLIMS_COMPONENT_SCALAR_FLOAT
} GlimsComponentScalarFormat;

typedef enum {
  GLIMS_COMPONENT_SCALAR_FILL,
  GLIMS_COMPONENT_SCALAR_INVERT
} GlimsComponentScalarOperation;

/* Intensity 0 is ink, 1 is paper. Fill intensity/opacity must be finite [0,1];
 * Invert requires intensity=0, opacity=1. NULL mask means full coverage;
 * otherwise every mask sample must be finite [0,1]. Integer output rounds
 * nearest, half upward. Affected float samples must be finite but may be
 * outside [0,1]; no clipping. Zero coverage preserves raw bytes, including
 * nonfinite source values. Invalid input leaves destination unchanged and
 * clears *changed. Zero count accepts NULL source/destination, but parameters
 * and changed must still be valid. Source==destination is supported; all other
 * overlap among source, mask, destination and changed is unsupported. Scalar
 * source/destination need not be aligned. All borrowed memory lives until return. */
bool glims_component_scalar_row (GlimsComponentScalarFormat format,
                                 GlimsComponentScalarOperation operation,
                                 double intensity, double opacity, size_t count,
                                 const void *source, const float *mask,
                                 void *destination, bool *changed);
#endif
