#include "lab-layer-preview.h"
#include "lab-layer-storage.h"
#include "lab-layer-render.h"
#include <cairo.h>
#include <stdint.h>
#include <string.h>
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "gegl/gimptilehandlervalidate.h"

typedef struct {
  GimpTileHandlerValidate parent_instance;
  GlimsLabLayerRender *render;
  guint width, height;
  const Babl *format;
  GMutex row_lock;
  gint failed;
} GlimsLabLayerValidate;
typedef struct { GimpTileHandlerValidateClass parent_class; } GlimsLabLayerValidateClass;
G_DEFINE_TYPE (GlimsLabLayerValidate, glims_lab_layer_validate, GIMP_TYPE_TILE_HANDLER_VALIDATE)

struct _GlimsLabLayerPreview {
  GlimsLabLayerMap map;
  guint order[GLIMS_LAB_LAYER_LIMIT];
  gboolean visible[GLIMS_LAB_LAYER_LIMIT];
  gdouble opacity[GLIMS_LAB_LAYER_LIMIT];
  GeglBuffer *planes[GLIMS_LAB_LAYER_LIMIT][4];
  gulong changed[GLIMS_LAB_LAYER_LIMIT][4];
  GeglBuffer *buffer;
  GimpTileHandlerValidate *validate;
  GMutex dirty_lock;
  gboolean dirty;
  GeglRectangle dirty_rect;
};

static gboolean
clip_rect (const GeglRectangle *rect, guint width, guint height, GeglRectangle *out)
{
  if (!rect || rect->width <= 0 || rect->height <= 0) return FALSE;
  gint64 x1 = MAX ((gint64) rect->x, 0), y1 = MAX ((gint64) rect->y, 0);
  gint64 x2 = MIN ((gint64) rect->x + rect->width, (gint64) width);
  gint64 y2 = MIN ((gint64) rect->y + rect->height, (gint64) height);
  if (x2 <= x1 || y2 <= y1) return FALSE;
  *out = (GeglRectangle) { (gint) x1, (gint) y1, (gint) (x2-x1), (gint) (y2-y1) };
  return TRUE;
}

static void
plane_changed (GeglBuffer *buffer, const GeglRectangle *rect, GlimsLabLayerPreview *preview)
{
  (void) buffer;
  GeglRectangle damage = { 0, 0, preview->map.width, preview->map.height };
  if (rect && !clip_rect (rect, preview->map.width, preview->map.height, &damage)) return;
  /* A source writer may emit from a worker. Never touch validator/derived
   * storage or the row mutex here; only accumulate clipped damage. */
  g_mutex_lock (&preview->dirty_lock);
  if (preview->dirty)
    {
      gint x1 = MIN (damage.x, preview->dirty_rect.x);
      gint y1 = MIN (damage.y, preview->dirty_rect.y);
      gint x2 = MAX (damage.x + damage.width, preview->dirty_rect.x + preview->dirty_rect.width);
      gint y2 = MAX (damage.y + damage.height, preview->dirty_rect.y + preview->dirty_rect.height);
      preview->dirty_rect = (GeglRectangle) { x1, y1, x2-x1, y2-y1 };
    }
  else preview->dirty_rect = damage;
  preview->dirty = TRUE;
  g_mutex_unlock (&preview->dirty_lock);
}

static gboolean
render_row (GlimsLabLayerValidate *self, gint64 x, gint64 y, guint width, gfloat *out)
{
  memset (out, 0, (gsize) width * 4 * sizeof *out);
  if (y < 0 || y >= self->height) return TRUE;
  gint64 left = MAX (x, 0), right = MIN (x + width, (gint64) self->width);
  if (right <= left) return TRUE;
  guint offset = (guint) (left-x), count = (guint) (right-left);
  /* The caller owns out. Release this lock before any operation on the
   * derived buffer; native validation already holds derived-storage locks. */
  g_mutex_lock (&self->row_lock);
  gboolean ok = glims_lab_layer_render_row (self->render, (gint) left, (gint) y,
                                            count, out + offset * 4);
  g_mutex_unlock (&self->row_lock);
  if (!ok)
    {
      g_atomic_int_set (&self->failed, TRUE);
      return FALSE;
    }
  /* Both validator paths associate manually with TRUE float alpha. Babl's
   * association fish floors alpha at 1/65536 and must not be used here. */
  for (guint i = 0; i < width; i++)
    for (guint c = 0; c < 3; c++) out[i*4+c] *= out[i*4+3];
  return TRUE;
}

static gboolean
multiply_size (gsize a, gsize b, gsize *result)
{
  if (a && b > G_MAXSIZE / a) return FALSE;
  *result = a * b;
  return TRUE;
}

static gboolean
valid_layout (const GeglRectangle *rect, gpointer destination, gint stride)
{
  if (!rect || rect->width < 0 || rect->height < 0) return FALSE;
  if (!rect->width || !rect->height) return TRUE;
  if (!destination || stride < 0) return FALSE;
  gsize row_bytes, last_row;
  if (!multiply_size ((gsize) rect->width, 4 * sizeof (gfloat), &row_bytes) ||
      (gsize) stride < row_bytes ||
      !multiply_size ((gsize) rect->height-1, (gsize) stride, &last_row) ||
      last_row > G_MAXSIZE-row_bytes)
    return FALSE;
  return (uintptr_t) destination <= UINTPTR_MAX - (last_row + row_bytes);
}

static void
validate_pixels (GimpTileHandlerValidate *validate, const GeglRectangle *rect,
                 const Babl *format, gpointer destination, gint stride)
{
  GlimsLabLayerValidate *self = (GlimsLabLayerValidate *) validate;
  if (format != self->format || !valid_layout (rect, destination, stride))
    { g_atomic_int_set (&self->failed, TRUE); return; }
  if (!rect->width || !rect->height) return;
  gfloat row[GLIMS_LAB_LAYER_RENDER_MAX_WIDTH * 4];
  for (gint y = 0; y < rect->height; y++)
    for (gint x = 0; x < rect->width; )
      {
        guint width = MIN (GLIMS_LAB_LAYER_RENDER_MAX_WIDTH, (guint) (rect->width-x));
        render_row (self, (gint64) rect->x+x, (gint64) rect->y+y, width, row);
        memcpy ((guint8 *) destination + (gsize) y*stride + (gsize) x*4*sizeof (gfloat),
                row, (gsize) width*4*sizeof (gfloat));
        x += width;
      }
}

static void
validate_buffer (GimpTileHandlerValidate *validate, const GeglRectangle *rect, GeglBuffer *buffer)
{
  GlimsLabLayerValidate *self = (GlimsLabLayerValidate *) validate;
  if (!rect || rect->width < 0 || rect->height < 0 || !buffer ||
      gegl_buffer_get_format (buffer) != self->format)
    { g_atomic_int_set (&self->failed, TRUE); return; }
  GeglRectangle clipped;
  if (!clip_rect (rect, self->width, self->height, &clipped)) return;
  gfloat row[GLIMS_LAB_LAYER_RENDER_MAX_WIDTH * 4];
  for (gint y = 0; y < clipped.height; y++)
    for (gint x = 0; x < clipped.width; )
      {
        guint width = MIN (GLIMS_LAB_LAYER_RENDER_MAX_WIDTH, (guint) (clipped.width-x));
        GeglRectangle chunk = { clipped.x+x, clipped.y+y, (gint) width, 1 };
        render_row (self, chunk.x, chunk.y, width, row);
        /* SAME native associated format: no Babl association/floor conversion.
         * row is callback-local and row_lock is no longer held. */
        gegl_buffer_set (buffer, &chunk, 0, self->format, row, GEGL_AUTO_ROWSTRIDE);
        x += width;
      }
}

static void
finalize (GObject *object)
{
  GlimsLabLayerValidate *self = (GlimsLabLayerValidate *) object;
  glims_lab_layer_render_free (self->render);
  g_mutex_clear (&self->row_lock);
  G_OBJECT_CLASS (glims_lab_layer_validate_parent_class)->finalize (object);
}

static void
glims_lab_layer_validate_class_init (GlimsLabLayerValidateClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = finalize;
  GimpTileHandlerValidateClass *parent = GIMP_TILE_HANDLER_VALIDATE_CLASS (klass);
  parent->validate = validate_pixels;
  parent->validate_buffer = validate_buffer;
}

static void
glims_lab_layer_validate_init (GlimsLabLayerValidate *self)
{
  g_mutex_init (&self->row_lock);
}

void
glims_lab_layer_preview_free (GlimsLabLayerPreview *preview)
{
  if (!preview) return;
  /* Caller has completed every synchronous read/validation and source write.
   * Disconnect/unassign never acts as a substitute for that quiescence. */
  for (guint i = 0; i < preview->map.count; i++)
    for (guint role = 0; role < 4; role++)
      if (preview->planes[i][role])
        {
          if (preview->changed[i][role])
            g_signal_handler_disconnect (preview->planes[i][role], preview->changed[i][role]);
          g_clear_object (&preview->planes[i][role]);
        }
  if (preview->buffer && preview->validate)
    gimp_tile_handler_validate_unassign (preview->validate, preview->buffer);
  g_clear_object (&preview->buffer);
  g_clear_object (&preview->validate);
  g_mutex_clear (&preview->dirty_lock);
  g_free (preview);
}

static gboolean
source_matches (GeglBuffer *buffer, const Babl *format, guint width, guint height)
{
  if (!buffer || gegl_buffer_get_format (buffer) != format) return FALSE;
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  return extent && !extent->x && !extent->y &&
    extent->width == (gint) width && extent->height == (gint) height;
}

static gboolean
matches (GlimsLabLayerPreview *preview, const GlimsLabLayerStorage *storage, const Babl *format)
{
  if (!preview || memcmp (&preview->map, &storage->map, sizeof preview->map)) return FALSE;
  for (guint i = 0; i < storage->map.count; i++)
    {
      const GlimsLabLayerNative *native = &storage->layers[i];
      gdouble opacity = gimp_layer_get_opacity (native->group);
      if (preview->order[i] != native->map_index ||
          preview->visible[i] != gimp_item_get_visible (GIMP_ITEM (native->group)) ||
          memcmp (&preview->opacity[i], &opacity, sizeof opacity)) return FALSE;
      for (guint role = 0; role < 4; role++)
        {
          GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (native->planes[role]));
          if (preview->planes[i][role] != buffer ||
              !source_matches (buffer, format, storage->map.width, storage->map.height)) return FALSE;
        }
    }
  return TRUE;
}

static GlimsLabLayerPreview *
create (GimpImage *image, const GlimsLabLayerStorage *storage, const Babl *format)
{
  GlimsLabLayerPreview *preview = g_try_new0 (GlimsLabLayerPreview, 1);
  if (!preview) return NULL;
  g_mutex_init (&preview->dirty_lock);
  preview->map = storage->map;
  for (guint i = 0; i < storage->map.count; i++)
    {
      const GlimsLabLayerNative *native = &storage->layers[i];
      preview->order[i] = native->map_index;
      preview->visible[i] = gimp_item_get_visible (GIMP_ITEM (native->group));
      preview->opacity[i] = gimp_layer_get_opacity (native->group);
      for (guint role = 0; role < 4; role++)
        {
          GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (native->planes[role]));
          if (!source_matches (buffer, format, storage->map.width, storage->map.height)) goto failed;
          preview->planes[i][role] = g_object_ref (buffer);
          preview->changed[i][role] = g_signal_connect (buffer, "changed", G_CALLBACK (plane_changed), preview);
        }
    }
  preview->validate = g_object_new (glims_lab_layer_validate_get_type (), "whole-tile", TRUE, NULL);
  if (!preview->validate) goto failed;
  GlimsLabLayerValidate *self = (GlimsLabLayerValidate *) preview->validate;
  self->width = storage->map.width;
  self->height = storage->map.height;
  self->format = babl_format ("RaGaBaA float");
  self->render = glims_lab_layer_render_new (image);
  if (!self->render) goto failed;
  GeglRectangle extent = { 0, 0, storage->map.width, storage->map.height };
  preview->buffer = gegl_buffer_new (&extent, self->format);
  if (!preview->buffer) goto failed;
  gimp_tile_handler_validate_assign (preview->validate, preview->buffer);
  preview->dirty = TRUE;
  preview->dirty_rect = extent;
  return preview;

failed:
  glims_lab_layer_preview_free (preview);
  return NULL;
}

GlimsStatus
glims_lab_layer_preview_prepare (GimpImage *image, GlimsLabLayerPreview **preview, GeglBuffer **buffer)
{
  if (buffer) *buffer = NULL;
  if (!preview || !buffer) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsLabLayerStorage storage;
  if (glims_lab_layer_storage_read (image, &storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    {
      g_clear_pointer (preview, glims_lab_layer_preview_free);
      return GLIMS_STATUS_UNSUPPORTED;
    }
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  if (!matches (*preview, &storage, format))
    {
      g_clear_pointer (preview, glims_lab_layer_preview_free);
      *preview = create (image, &storage, format);
      if (!*preview) return GLIMS_STATUS_FAILED;
    }
  GlimsLabLayerValidate *self = (GlimsLabLayerValidate *) (*preview)->validate;
  g_mutex_lock (&(*preview)->dirty_lock);
  gboolean dirty = (*preview)->dirty;
  GeglRectangle damage = (*preview)->dirty_rect;
  (*preview)->dirty = FALSE;
  g_mutex_unlock (&(*preview)->dirty_lock);
  if (g_atomic_int_get (&self->failed))
    {
      damage = (GeglRectangle) { 0, 0, storage.map.width, storage.map.height };
      dirty = TRUE;
      g_atomic_int_set (&self->failed, FALSE);
    }
  if (dirty) gimp_tile_handler_validate_invalidate ((*preview)->validate, &damage);
  *buffer = (*preview)->buffer;
  return GLIMS_STATUS_OK;
}

gboolean
glims_lab_layer_preview_succeeded (GlimsLabLayerPreview *preview)
{
  return !preview || !g_atomic_int_get (&((GlimsLabLayerValidate *) preview->validate)->failed);
}
