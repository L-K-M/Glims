/* Bounded Photoshop .ADO settings structure; does not claim PSD mode equivalence. */
#ifndef GLIMS_DUOTONE_OPTIONS_H
#define GLIMS_DUOTONE_OPTIONS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLIMS_DUOTONE_OPTIONS_SIZE 524u
#define GLIMS_DUOTONE_OPTIONS_MAX_INKS 4u
#define GLIMS_DUOTONE_OPTIONS_NAME_CAPACITY 63u
#define GLIMS_DUOTONE_OPTIONS_CURVE_POINTS 13u

typedef struct {
  uint8_t bytes[GLIMS_DUOTONE_OPTIONS_SIZE];
} GlimsDuotoneOptions;

typedef struct {
  uint16_t space;
  uint16_t components[4];
} GlimsDuotoneInkColor;

/* Accept exactly one version-1 .ADO structure. Active names and curve values
 * are checked; inactive fields, compatibility fields and overprints remain
 * opaque. On failure, out is unchanged. A successful parse owns its bytes. */
bool glims_duotone_options_parse (const uint8_t *bytes, size_t length,
                                  GlimsDuotoneOptions *out);
unsigned glims_duotone_options_count (const GlimsDuotoneOptions *options);
/* Names are raw Pascal-string bytes, not assumed to be UTF-8. Returned bytes
 * are borrowed from options and remain valid only until it changes. */
bool glims_duotone_options_name (const GlimsDuotoneOptions *options, unsigned ink,
                                 const uint8_t **bytes, size_t *length);
bool glims_duotone_options_color (const GlimsDuotoneOptions *options, unsigned ink,
                                  GlimsDuotoneInkColor *color);
bool glims_duotone_options_curve (const GlimsDuotoneOptions *options, unsigned ink,
                                  int16_t points[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS]);
/* Setters touch only the requested active field and leave compatibility and
 * overprint bytes intact. They do not validate color-space semantics or
 * recalculate overprint colors; a caller must address both before publishing
 * an edited file. Invalid arguments fail without mutation. Curve endpoints
 * are 0...1000; interior points additionally permit -1. */
bool glims_duotone_options_set_name (GlimsDuotoneOptions *options, unsigned ink,
                                     const uint8_t *bytes, size_t length);
bool glims_duotone_options_set_color (GlimsDuotoneOptions *options, unsigned ink,
                                      const GlimsDuotoneInkColor *color);
bool glims_duotone_options_set_curve (GlimsDuotoneOptions *options, unsigned ink,
                                      const int16_t points[GLIMS_DUOTONE_OPTIONS_CURVE_POINTS]);
#endif
