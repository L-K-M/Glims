#include "plate-lab-preview.h"
#include "lab-samples.h"
#include "lab-transform.h"
#include "core/gimpdrawable.h"
#include <string.h>

typedef struct {
  GimpTileHandlerValidate parent_instance;
  GeglBuffer *planes[3];
  const Babl *format;
  GlimsLabFormat sample_format;
  GlimsLabTransform *transform;
  gint failed;
} GlimsLabValidate;
typedef struct { GimpTileHandlerValidateClass parent_class; } GlimsLabValidateClass;

G_DEFINE_TYPE (GlimsLabValidate, glims_lab_validate, GIMP_TYPE_TILE_HANDLER_VALIDATE)

static const Babl *
storage_babl_format (guint storage, GlimsLabFormat *sample_format)
{
  switch (storage)
    {
    case GLIMS_PLATE_STORAGE_U8:
      *sample_format = GLIMS_LAB_FORMAT_U8;
      return babl_format ("Y u8");
    case GLIMS_PLATE_STORAGE_U16:
      *sample_format = GLIMS_LAB_FORMAT_U16;
      return babl_format ("Y u16");
    case GLIMS_PLATE_STORAGE_FLOAT:
      *sample_format = GLIMS_LAB_FORMAT_FLOAT;
      return babl_format ("Y float");
    default:
      *sample_format = GLIMS_LAB_FORMAT_U8;
      return NULL;
    }
}

static void
render_chunk (GlimsLabValidate *self, const GeglRectangle *rect, gfloat *rgba)
{
  /* Bounded per-row scratch: native samples, decoded physical doubles, and
   * interleaved physical float Lab. No image-proportional allocations. */
  union {
    guint8 u8[256];
    guint16 u16[256];
    gfloat f32[256];
  } native;
  gdouble decoded[256];
  gfloat lab[256 * 3];

  g_assert (rect->width > 0 && rect->width <= 256 && rect->height == 1);
  for (guint c = 0; c < 3; c++)
    {
      gegl_buffer_get (self->planes[c], rect, 1.0, self->format, &native,
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      if (!glims_lab_decode_row ((GlimsLabRole) c, self->sample_format,
                                 (size_t) rect->width, &native, decoded))
        {
          memset (rgba, 0, (gsize) rect->width * 4 * sizeof *rgba);
          g_atomic_int_set (&self->failed, TRUE);
          return;
        }
      for (gint x = 0; x < rect->width; x++)
        lab[x * 3 + c] = (gfloat) decoded[x];
    }

  /* Immutable transform, no mutable global state. Finite extended float
   * samples are retained as physical values. */
  if (!glims_lab_transform_pixels (self->transform, lab, (size_t) rect->width, rgba))
    {
      memset (rgba, 0, (gsize) rect->width * 4 * sizeof *rgba);
      g_atomic_int_set (&self->failed, TRUE);
    }
}

static void
validate_pixels (GimpTileHandlerValidate *validate, const GeglRectangle *rect,
                 const Babl *format, gpointer destination, gint stride)
{
  GlimsLabValidate *self = (GlimsLabValidate *) validate;
  if (format != babl_format ("RGBA float"))
    {
      g_atomic_int_set (&self->failed, TRUE);
      return;
    }
  for (gint y = 0; y < rect->height; y++)
    for (gint x = 0; x < rect->width; x += 256)
      {
        GeglRectangle chunk = { rect->x + x, rect->y + y,
                                MIN (256, rect->width - x), 1 };
        render_chunk (self, &chunk,
                      (gfloat *) ((guint8 *) destination + (gsize) y * stride) + x * 4);
      }
}

static void
validate_buffer (GimpTileHandlerValidate *validate, const GeglRectangle *rect,
                 GeglBuffer *buffer)
{
  /* The parent's custom-validator default linearly opens the entire area.
   * Override it so a cold fit-view does not allocate an image-sized array. */
  GlimsLabValidate *self = (GlimsLabValidate *) validate;
  gfloat rgba[256 * 4];
  for (gint y = 0; y < rect->height; y++)
    for (gint x = 0; x < rect->width; x += 256)
      {
        GeglRectangle chunk = { rect->x + x, rect->y + y,
                                MIN (256, rect->width - x), 1 };
        render_chunk (self, &chunk, rgba);
        gegl_buffer_set (buffer, &chunk, 0, babl_format ("RGBA float"), rgba,
                         GEGL_AUTO_ROWSTRIDE);
      }
}

static void
finalize (GObject *object)
{
  GlimsLabValidate *self = (GlimsLabValidate *) object;
  for (guint i = 0; i < 3; i++)
    g_clear_object (&self->planes[i]);
  glims_lab_transform_free (self->transform);
  G_OBJECT_CLASS (glims_lab_validate_parent_class)->finalize (object);
}

static void
glims_lab_validate_class_init (GlimsLabValidateClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = finalize;
  GimpTileHandlerValidateClass *parent = GIMP_TILE_HANDLER_VALIDATE_CLASS (klass);
  parent->validate = validate_pixels;
  parent->validate_buffer = validate_buffer;
}

static void
glims_lab_validate_init (GlimsLabValidate *self)
{
  (void) self;
}

GimpTileHandlerValidate *
glims_plate_lab_preview_new (const GlimsPlateStorage *storage)
{
  GlimsLabFormat sample_format;
  const Babl *format;
  GlimsLabTransform *transform;
  GlimsLabValidate *self;

  if (!storage ||
      !glims_plate_map_validate (&storage->map) ||
      storage->map.mode != GLIMS_PLATE_MODE_LAB ||
      storage->map.encoding != GLIMS_PLATE_ENCODING_LAB_D50 ||
      storage->map.count != 3 || storage->profile || storage->profile_size)
    return NULL;

  for (guint i = 0; i < 3; i++)
    if (!storage->visible[i] || !storage->planes[i])
      return NULL;

  format = storage_babl_format (storage->map.storage, &sample_format);
  if (!format)
    return NULL;

  transform = glims_lab_transform_new ();
  if (!transform)
    return NULL;

  self = g_object_new (glims_lab_validate_get_type (), NULL);
  if (!self)
    {
      glims_lab_transform_free (transform);
      return NULL;
    }
  self->transform = transform;
  self->format = format;
  self->sample_format = sample_format;

  for (guint i = 0; i < 3; i++)
    {
      GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (storage->planes[i]));
      if (!buffer || gegl_buffer_get_format (buffer) != format)
        {
          g_object_unref (self);
          return NULL;
        }
      self->planes[i] = g_object_ref (buffer);
    }

  return GIMP_TILE_HANDLER_VALIDATE (self);
}

void
glims_plate_lab_preview_prepare (GimpTileHandlerValidate *validate,
                                 const GeglRectangle *extent)
{
  GlimsLabValidate *self = (GlimsLabValidate *) validate;
  if (g_atomic_int_get (&self->failed))
    {
      gimp_tile_handler_validate_invalidate (validate, extent);
      g_atomic_int_set (&self->failed, FALSE);
    }
}

gboolean
glims_plate_lab_preview_succeeded (GimpTileHandlerValidate *validate)
{
  return !g_atomic_int_get (&((GlimsLabValidate *) validate)->failed);
}
