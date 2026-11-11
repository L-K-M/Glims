#include "brush-fingerprint.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-header.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimptempbuf.h"

#include <float.h>
#include <math.h>
#include <string.h>

G_STATIC_ASSERT (sizeof (gfloat) == sizeof (guint32));
G_STATIC_ASSERT (sizeof (gdouble) == sizeof (guint64));

static guint32
float_bits (gfloat value)
{
  guint32 bits;
  memcpy (&bits, &value, sizeof bits);
  return bits;
}

static guint64
double_bits (gdouble value)
{
  guint64 bits;
  memcpy (&bits, &value, sizeof bits);
  return bits;
}

static gboolean
scalar_format_supported (void)
{
  return FLT_RADIX == 2 && FLT_MANT_DIG == 24 && FLT_MAX_EXP == 128 &&
         DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024 &&
         float_bits (1.0f) == 0x3f800000 &&
         double_bits (1.0) == G_GUINT64_CONSTANT (0x3ff0000000000000);
}

static void
hash_u32 (GChecksum *sum, guint32 value)
{
  guint32 encoded = GUINT32_TO_BE (value);
  g_checksum_update (sum, (const guchar *) &encoded, sizeof encoded);
}

static void
hash_double (GChecksum *sum, gdouble value)
{
  guint64 encoded = GUINT64_TO_BE (double_bits (value));
  g_checksum_update (sum, (const guchar *) &encoded, sizeof encoded);
}

/* Generated transforms can regenerate a mask at a new size. The base mask
 * alone does not identify the transform recipe (gimpbrushgenerated.c,
 * gimp_brush_generated_transform_size/transform_mask, all four pins). */
static gboolean
hash_generated_recipe (GChecksum *sum, GimpBrushGenerated *brush)
{
  guint32 shape;
  switch (gimp_brush_generated_get_shape (brush))
    {
    case GIMP_BRUSH_GENERATED_CIRCLE:  shape = 1; break;
    case GIMP_BRUSH_GENERATED_SQUARE:  shape = 2; break;
    case GIMP_BRUSH_GENERATED_DIAMOND: shape = 3; break;
    default: return FALSE;
    }

  gint   spikes = gimp_brush_generated_get_spikes (brush);
  gfloat radius = gimp_brush_generated_get_radius (brush);
  gfloat hardness = gimp_brush_generated_get_hardness (brush);
  gfloat aspect = gimp_brush_generated_get_aspect_ratio (brush);
  gfloat angle = gimp_brush_generated_get_angle (brush);
  if (spikes < 2 || spikes > 20 ||
      !(radius >= GIMP_BRUSH_GENERATED_MIN_RADIUS && radius <= GIMP_BRUSH_GENERATED_MAX_RADIUS) ||
      !(hardness >= 0.0f && hardness <= 1.0f) ||
      !(aspect >= 1.0f && aspect <= 1000.0f) ||
      !(angle >= 0.0f && angle <= 180.0f))
    return FALSE;

  hash_u32 (sum, shape);
  hash_u32 (sum, (guint32) spikes);
  hash_u32 (sum, float_bits (radius));
  hash_u32 (sum, float_bits (hardness));
  hash_u32 (sum, float_bits (aspect));
  hash_u32 (sum, float_bits (angle));
  return TRUE;
}

static gboolean
hash_float_mask (GChecksum *sum, const guchar *data, gsize pixels)
{
  guint32 encoded[1024];

  for (gsize offset = 0; offset < pixels;)
    {
      gsize count = MIN (pixels - offset, G_N_ELEMENTS (encoded));
      for (gsize i = 0; i < count; i++)
        {
          gfloat sample;
          memcpy (&sample, data + (offset + i) * sizeof sample, sizeof sample);
          if (!isfinite (sample))
            return FALSE;
          encoded[i] = GUINT32_TO_BE (float_bits (sample));
        }
      g_checksum_update (sum, (const guchar *) encoded, count * sizeof encoded[0]);
      offset += count;
    }
  return TRUE;
}

gchar *
glims_brush_fingerprint (GimpBrush *brush)
{
  if (!brush || !scalar_format_supported ())
    return NULL;

  GType type = G_OBJECT_TYPE (brush);
  gboolean generated = type == GIMP_TYPE_BRUSH_GENERATED;
  if ((!generated && type != GIMP_TYPE_BRUSH) ||
      gimp_brush_get_pixmap (brush) || gimp_brush_get_blur_hardness (brush) != 1.0)
    return NULL;

  const GimpTempBuf *mask = gimp_brush_get_mask (brush);
  /* gimpbrush-load.c creates Y u8; gimpbrushgenerated.c creates Y float.
   * gimptempbuf.c allocates tightly packed width × height × bpp in all
   * four pins. Reject a different format/space rather than convert it. */
  const Babl *format = babl_format (generated ? "Y float" : "Y u8");
  gsize bpp = generated ? sizeof (gfloat) : 1;
  if (!mask || !format || gimp_temp_buf_get_format (mask) != format ||
      (gsize) babl_format_get_bytes_per_pixel (format) != bpp)
    return NULL;

  gint width = gimp_temp_buf_get_width (mask);
  gint height = gimp_temp_buf_get_height (mask);
  if (width <= 0 || height <= 0 ||
      (!generated && (width > GIMP_BRUSH_MAX_SIZE || height > GIMP_BRUSH_MAX_SIZE)) ||
      (guint64) width > GLIMS_MAX_PIXEL_BUFFER_BYTES / (guint64) height / bpp)
    return NULL;

  gsize pixels = (gsize) width * (gsize) height;
  gsize bytes = pixels * bpp;
  const guchar *data = gimp_temp_buf_get_data (mask);
  gint spacing = gimp_brush_get_spacing (brush);
  GimpVector2 x = gimp_brush_get_x_axis (brush);
  GimpVector2 y = gimp_brush_get_y_axis (brush);
  if (!data || gimp_temp_buf_get_data_size (mask) != bytes ||
      spacing < 1 || spacing > 5000 ||
      !isfinite (x.x) || !isfinite (x.y) || !isfinite (y.x) || !isfinite (y.y))
    return NULL;

  /* v1: NUL-terminated domain, format tag (1 = ordinary Y u8, 2 =
   * generated Y float), dimensions, spacing, axes, generated recipe
   * when present, then the complete mask. All scalars use big endian. */
  static const guchar domain[] = "Glims brush fingerprint v1";
  GChecksum *sum = g_checksum_new (G_CHECKSUM_SHA256);
  g_checksum_update (sum, domain, sizeof domain);
  hash_u32 (sum, generated ? 2 : 1);
  hash_u32 (sum, (guint32) width);
  hash_u32 (sum, (guint32) height);
  hash_u32 (sum, (guint32) spacing);
  hash_double (sum, x.x);
  hash_double (sum, x.y);
  hash_double (sum, y.x);
  hash_double (sum, y.y);

  gchar *digest = NULL;
  if (generated)
    {
      if (hash_generated_recipe (sum, GIMP_BRUSH_GENERATED (brush)) && hash_float_mask (sum, data, pixels))
        digest = g_strdup (g_checksum_get_string (sum));
    }
  else
    {
      g_checksum_update (sum, data, bytes);
      digest = g_strdup (g_checksum_get_string (sum));
    }
  g_checksum_free (sum);
  return digest;
}
