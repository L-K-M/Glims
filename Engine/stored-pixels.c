/* Rows of a buffer read in its own format; see stored-pixels.h. */
#include "engine-private.h"
#include "stored-pixels.h"
#include <cairo.h>
#include <math.h>
#include <string.h>
#include "gegl/gimp-babl.h"
#include "gegl/gimptilehandlervalidate.h"

static guint
component_bytes (GimpComponentType type)
{
  switch (type)
    {
    case GIMP_COMPONENT_TYPE_U8:     return 1;
    case GIMP_COMPONENT_TYPE_U16:
    case GIMP_COMPONENT_TYPE_HALF:   return 2;
    case GIMP_COMPONENT_TYPE_U32:
    case GIMP_COMPONENT_TYPE_FLOAT:  return 4;
    case GIMP_COMPONENT_TYPE_DOUBLE: return 8;
    }
  return 0;
}

static const char *
component_name (GimpComponentType type)
{
  switch (type)
    {
    case GIMP_COMPONENT_TYPE_U8:     return "u8";
    case GIMP_COMPONENT_TYPE_U16:    return "u16";
    case GIMP_COMPONENT_TYPE_HALF:   return "half";
    case GIMP_COMPONENT_TYPE_U32:    return "u32";
    case GIMP_COMPONENT_TYPE_FLOAT:  return "float";
    case GIMP_COMPONENT_TYPE_DOUBLE: return "double";
    }
  return NULL;
}

/* IEEE 754 binary16, including subnormals, infinities and NaN. */
static double
half_value (guint16 bits)
{
  int exponent = (bits >> 10) & 0x1f, mantissa = bits & 0x3ff;
  double value = exponent == 0  ? ldexp (mantissa, -24) :
                 exponent == 31 ? (mantissa ? NAN : INFINITY) :
                 ldexp (mantissa | 0x400, exponent - 25);
  return bits & 0x8000 ? -value : value;
}

static void
decode (const GlimsStoredRows *rows, gsize samples)
{
  const guint8 *in = rows->stored;
  double *out = rows->decoded;
  for (gsize i = 0; i < samples; i++)
    switch (rows->type)
      {
      case GIMP_COMPONENT_TYPE_U8:
        out[i] = in[i] / 255.0;
        break;
      case GIMP_COMPONENT_TYPE_U16:
        {
          guint16 v;
          memcpy (&v, in + 2 * i, sizeof v);
          out[i] = v / 65535.0;
          break;
        }
      case GIMP_COMPONENT_TYPE_HALF:
        {
          guint16 v;
          memcpy (&v, in + 2 * i, sizeof v);
          out[i] = half_value (v);
          break;
        }
      case GIMP_COMPONENT_TYPE_U32:
        {
          guint32 v;
          memcpy (&v, in + 4 * i, sizeof v);
          out[i] = v / 4294967295.0;
          break;
        }
      case GIMP_COMPONENT_TYPE_FLOAT:
        {
          float v;
          memcpy (&v, in + 4 * i, sizeof v);
          out[i] = v;
          break;
        }
      case GIMP_COMPONENT_TYPE_DOUBLE:
        memcpy (out + i, in + 8 * i, sizeof *out);
        break;
      }
}

gboolean
glims_stored_rows_init (GlimsStoredRows *rows, GeglBuffer *buffer,
                       guint capacity, GlimsStoredUse use)
{
  const Babl *format = buffer ? gegl_buffer_get_format (buffer) : NULL;
  GimpComponentType type;
  guint size, components;
  const Babl *space, *gray = NULL;

  *rows = (GlimsStoredRows) { .buffer = buffer, .capacity = capacity };
  if (!format || !capacity || !babl_format_has_alpha (format)) return FALSE;

  type = gimp_babl_format_get_component_type (format);
  size = component_bytes (type);
  components = (guint) babl_format_get_n_components (format);
  if (!size || components < 2 ||
      (guint) babl_format_get_bytes_per_pixel (format) != size * components ||
      (use == GLIMS_STORED_GRAY_VALUES && components != 2))
    return FALSE;

  rows->format = format;
  rows->type = type;
  rows->components = components;
  rows->pixel_bytes = size * components;

  if (use == GLIMS_STORED_GRAY_VALUES)
    {
      /* Formats are unique per encoding and space, so a stored format equal
       * to non-linear gray of its own type already holds the values. */
      gchar *stored_gray = g_strdup_printf ("Y'A %s", component_name (type));
      const Babl *same;
      space = babl_format_get_space (format);
      gray = space ? babl_format_with_space ("Y'A float", space) : babl_format ("Y'A float");
      same = space ? babl_format_with_space (stored_gray, space) : babl_format (stored_gray);
      g_free (stored_gray);
      if (!gray) return FALSE;
      if (same != format) rows->gray_fish = babl_fish (format, gray);
    }

  rows->stored = g_try_malloc ((gsize) capacity * rows->pixel_bytes);
  rows->decoded = g_try_new (double, (gsize) capacity * components);
  if (rows->gray_fish) rows->gray = g_try_new (float, (gsize) capacity * 2);
  if (!rows->stored || !rows->decoded || (rows->gray_fish && !rows->gray))
    {
      glims_stored_rows_clear (rows);
      return FALSE;
    }
  return TRUE;
}

void
glims_stored_rows_read (GlimsStoredRows *rows, const GeglRectangle *row)
{
  guint count = (guint) row->width;
  g_return_if_fail (row->height == 1 && row->width >= 1 && count <= rows->capacity);

  if (count == 1)
    {
      /* GEGL's one-pixel shortcut can bypass projection tile validation. */
      GimpTileHandlerValidate *validate = gimp_tile_handler_validate_get_assigned (rows->buffer);
      if (validate)
        gimp_tile_handler_validate_validate (validate, rows->buffer, row, TRUE, FALSE);
    }
  gegl_buffer_get (rows->buffer, row, 1.0, rows->format, rows->stored,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  decode (rows, (gsize) count * rows->components);
  if (rows->gray_fish)
    babl_process (rows->gray_fish, rows->stored, rows->gray, count);
}

static gboolean
near_endpoint (double sample, double endpoint)
{
  return fabs (sample - endpoint) <= GLIMS_STORED_ENDPOINT_TOLERANCE;
}

gboolean
glims_stored_rows_opaque_gray (const GlimsStoredRows *rows, guint i, float *value)
{
  const double tolerance = GLIMS_STORED_ENDPOINT_TOLERANCE;
  double stored = rows->decoded[2 * i], alpha = rows->decoded[2 * i + 1];
  /* The comparisons are false for NaN, so they also refuse it. */
  if (!(stored >= -tolerance && stored <= 1.0 + tolerance) || !near_endpoint (alpha, 1.0)) return FALSE;

  /* Every encoding maps [0,1] onto [0,1]; clamp only round-off. */
  *value = rows->gray_fish ? rows->gray[2 * i] : (float) stored;
  *value = fminf (fmaxf (*value, 0.0f), 1.0f);
  return TRUE;
}

gboolean
glims_stored_rows_black_or_white (const GlimsStoredRows *rows, guint i, gboolean *white)
{
  const double *p = rows->decoded + (gsize) i * rows->components;
  gboolean is_white = near_endpoint (p[0], 1.0);
  if (!is_white && !near_endpoint (p[0], 0.0)) return FALSE;
  for (guint c = 1; c + 1 < rows->components; c++)
    if (!near_endpoint (p[c], is_white ? 1.0 : 0.0)) return FALSE;
  if (!near_endpoint (p[rows->components - 1], 1.0)) return FALSE;
  *white = is_white;
  return TRUE;
}

void
glims_stored_rows_clear (GlimsStoredRows *rows)
{
  g_clear_pointer (&rows->stored, g_free);
  g_clear_pointer (&rows->decoded, g_free);
  g_clear_pointer (&rows->gray, g_free);
  rows->gray_fish = NULL;
}
