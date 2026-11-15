/* Bounded Photoshop image resource 1066 preview table, independent of PSD I/O. */
#ifndef GLIMS_DUOTONE_PREVIEW_TABLE_H
#define GLIMS_DUOTONE_PREVIEW_TABLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_DUOTONE_PREVIEW_MAX_COLORS 4u
#define GLIMS_DUOTONE_PREVIEW_SAMPLES 256u

typedef struct {
  uint16_t space;
  uint16_t components[4];
} GlimsDuotoneAlternateColor;

typedef struct {
  unsigned color_count;
  GlimsDuotoneAlternateColor colors[GLIMS_DUOTONE_PREVIEW_MAX_COLORS];
  /* The source's ordered encoded Lab triples. Their mapping to image samples
   * is not established here; no conversion or ink-edit invalidation is done. */
  uint8_t lab[GLIMS_DUOTONE_PREVIEW_SAMPLES][3];
} GlimsDuotonePreviewTable;

/* Parses a complete resource 1066 payload, version 1, with at most four
 * alternate colors and exactly 256 Lab triples. Other valid layouts are
 * declined so callers may preserve them opaquely. Failure leaves out intact;
 * successful output owns its data and may overlap the input. */
bool glims_duotone_preview_table_parse (const uint8_t *bytes, size_t length,
                                       GlimsDuotonePreviewTable *out);
#endif
