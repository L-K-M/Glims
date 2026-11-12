#include "plate-cmyk-preview.h"
#include "cmyk-transform.h"
#include "core/gimpdrawable.h"
#include <math.h>
#include <string.h>

typedef struct {
  GimpTileHandlerValidate parent_instance;
  GeglBuffer *planes[4];
  gboolean visible[4];
  GlimsCmykTransform *transform;
  GMutex transform_lock;
  gint failed;
} GlimsCmykValidate;
typedef struct { GimpTileHandlerValidateClass parent_class; } GlimsCmykValidateClass;

G_DEFINE_TYPE (GlimsCmykValidate, glims_cmyk_validate, GIMP_TYPE_TILE_HANDLER_VALIDATE)

/* Bound scratch storage even when fit-view requests a large full-resolution
 * area before deriving a mipmap. Input planes remain authoritative. */
static void
render_chunk (GlimsCmykValidate *self, const GeglRectangle *rect, gfloat *rgba)
{
  gfloat intensity[256 * 4], plane[256];
  for (guint c = 0; c < 4; c++)
    {
      if (self->visible[c])
        gegl_buffer_get (self->planes[c], rect, 1.0, babl_format ("Y float"),
                         plane, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      for (gint x = 0; x < rect->width; x++)
        {
          gfloat value = self->visible[c] ? plane[x] : 1.0f;
          /* Physical ICC coverage clips finite extended values only for
           * display. Never rewrite them in the source; nonfinite ink fails. */
          intensity[x * 4 + c] = isfinite (value) ? CLAMP (value, 0.0f, 1.0f) : value;
        }
    }
  g_mutex_lock (&self->transform_lock);
  gboolean ok = glims_cmyk_transform_pixels (self->transform, intensity,
                                              rect->width, rgba, NULL);
  g_mutex_unlock (&self->transform_lock);
  if (!ok)
    {
      memset (rgba, 0, rect->width * 4 * sizeof *rgba);
      g_atomic_int_set (&self->failed, TRUE);
    }
}

static void
validate_pixels (GimpTileHandlerValidate *validate, const GeglRectangle *rect,
                   const Babl *format, gpointer destination, gint stride)
{
  GlimsCmykValidate *self = (GlimsCmykValidate *) validate;
  g_return_if_fail (format == babl_format ("RGBA float"));
  for (gint y = 0; y < rect->height; y++)
    for (gint x = 0; x < rect->width; x += 256)
      {
        GeglRectangle chunk = { rect->x + x, rect->y + y, MIN (256, rect->width - x), 1 };
        render_chunk (self, &chunk, (gfloat *) ((guint8 *) destination + (gsize) y * stride) + x * 4);
      }
}

static void
validate_buffer (GimpTileHandlerValidate *validate, const GeglRectangle *rect,
                   GeglBuffer *buffer)
{
  /* The parent's custom-validator default linearly opens the entire area.
   * Override it so a cold fit-view does not allocate an image-sized array. */
  GlimsCmykValidate *self = (GlimsCmykValidate *) validate;
  gfloat rgba[256 * 4];
  for (gint y = 0; y < rect->height; y++)
    for (gint x = 0; x < rect->width; x += 256)
      {
        GeglRectangle chunk = { rect->x + x, rect->y + y, MIN (256, rect->width - x), 1 };
        render_chunk (self, &chunk, rgba);
        gegl_buffer_set (buffer, &chunk, 0, babl_format ("RGBA float"), rgba, GEGL_AUTO_ROWSTRIDE);
      }
}

static void
finalize (GObject *object)
{
  GlimsCmykValidate *self = (GlimsCmykValidate *) object;
  for (guint i = 0; i < 4; i++) g_clear_object (&self->planes[i]);
  glims_cmyk_transform_free (self->transform);
  g_mutex_clear (&self->transform_lock);
  G_OBJECT_CLASS (glims_cmyk_validate_parent_class)->finalize (object);
}

static void
glims_cmyk_validate_class_init (GlimsCmykValidateClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = finalize;
  GimpTileHandlerValidateClass *parent = GIMP_TILE_HANDLER_VALIDATE_CLASS (klass);
  parent->validate = validate_pixels;
  parent->validate_buffer = validate_buffer;
}

static void
glims_cmyk_validate_init (GlimsCmykValidate *self)
{
  g_mutex_init (&self->transform_lock);
}

GimpTileHandlerValidate *
glims_plate_cmyk_preview_new (const GlimsPlateStorage *storage)
{
  if (!storage || storage->map.mode != GLIMS_PLATE_MODE_CMYK || storage->map.count != 4)
    return NULL;
  GlimsCmykTransform *transform = glims_cmyk_transform_new (storage->profile, storage->profile_size, NULL);
  if (!transform) return NULL;
  GlimsCmykValidate *self = g_object_new (glims_cmyk_validate_get_type (), NULL);
  self->transform = transform;
  for (guint i = 0; i < 4; i++)
    {
      self->planes[i] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (storage->planes[i])));
      self->visible[i] = storage->visible[i];
    }
  return GIMP_TILE_HANDLER_VALIDATE (self);
}

void
glims_plate_cmyk_preview_prepare (GimpTileHandlerValidate *validate, const GeglRectangle *extent)
{
  GlimsCmykValidate *self = (GlimsCmykValidate *) validate;
  if (g_atomic_int_get (&self->failed))
    {
      gimp_tile_handler_validate_invalidate (validate, extent);
      g_atomic_int_set (&self->failed, FALSE);
    }
}

gboolean
glims_plate_cmyk_preview_succeeded (GimpTileHandlerValidate *validate)
{
  return !g_atomic_int_get (&((GlimsCmykValidate *) validate)->failed);
}
