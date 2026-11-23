/* Rows of a buffer read in its own format, for exports that refuse
 * transparent, out-of-range or not black and white pixels.
 *
 * Such checks must not judge babl-converted floats. Babl accepts any
 * conversion path whose measured error is within its tolerance, picks one
 * by timing and caches the choice where GIMP shares it, and some legal
 * paths read opaque white as 0.9999998 (Engine/tests/babl-path-seed.c).
 * Reading a buffer in its own format copies the stored samples, so the
 * checks below see the same values on every run. */
#ifndef GLIMS_STORED_PIXELS_H
#define GLIMS_STORED_PIXELS_H
#include <float.h>
#include <gegl.h>
#include "libgimpbase/gimpbase.h"

/* GIMP composites a projection in single-precision float, so one stored
 * above 16 bits per sample can hold white a float step from 1 (u32
 * 4294966784, double 1 + 2^-23). Endpoint checks allow a few float steps.
 * No u8 or u16 sample but the endpoint itself lies this close to one. */
#define GLIMS_STORED_ENDPOINT_TOLERANCE (4.0 * FLT_EPSILON)

typedef struct {
  GeglBuffer *buffer;          /* borrowed */
  const Babl *format;          /* the buffer's own format, alpha last */
  GimpComponentType type;
  guint components, pixel_bytes, capacity;
  /* To the space's non-linear gray when the image stores another encoding
   * (linear or perceptual); NULL when stored gray is already non-linear. */
  const Babl *gray_fish;
  guint8 *stored;
  double *decoded;             /* the last row: components per pixel */
  float *gray;                 /* the last row through gray_fish, Y'A pairs */
} GlimsStoredRows;

typedef enum {
  GLIMS_STORED_ANY_MODEL,      /* only glims_stored_rows_black_or_white */
  GLIMS_STORED_GRAY_VALUES,    /* a gray buffer; also report Y' values */
} GlimsStoredUse;

/* Prepares rows of at most capacity pixels for buffer, whose format must
 * be a GIMP storage format with alpha. False, with nothing to clear, when
 * the format is unsupported or memory runs out. */
gboolean glims_stored_rows_init (GlimsStoredRows *rows, GeglBuffer *buffer,
                                 guint capacity, GlimsStoredUse use);
/* Reads one row of 1..capacity pixels. */
void glims_stored_rows_read (GlimsStoredRows *rows, const GeglRectangle *row);
/* True when pixel i of the last row is opaque gray: stored gray within
 * [0,1] and alpha 1, both finite and within the endpoint tolerance. Sets
 * value to its gray in the space's non-linear encoding, clamped to [0,1].
 * Requires GLIMS_STORED_GRAY_VALUES. */
gboolean glims_stored_rows_opaque_gray (const GlimsStoredRows *rows, guint i, float *value);
/* True when pixel i of the last row is opaque and every color component
 * is black, or every one is white, within the endpoint tolerance. Black and
 * white are 0 and 1 in every encoding, so no conversion is involved. */
gboolean glims_stored_rows_black_or_white (const GlimsStoredRows *rows, guint i, gboolean *white);
/* Releases the row storage. Safe on a zeroed or cleared struct. */
void glims_stored_rows_clear (GlimsStoredRows *rows);
#endif
