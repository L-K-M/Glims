#include "plate-preview.h"
#include "plate-cmyk-preview.h"
#include "plate-lab-preview.h"
#include <cairo.h>
#include <math.h>
#include <string.h>
#include "core/gimpdrawable.h"
#include "gegl/gimptilehandlervalidate.h"

struct _GlimsPlatePreview {
  GlimsPlateMap map;
  GBytes *profile;
  gboolean visible[GLIMS_PLATE_LIMIT];
  GeglNode *graph;
  GeglBuffer *buffer;
  GimpTileHandlerValidate *validate;
  GeglBuffer *planes[GLIMS_PLATE_LIMIT];
  gulong changed[GLIMS_PLATE_LIMIT];
  /* A GEGL write may emit from a worker. Only the engine thread touches
   * graph/validator state; the signal accumulates bounded image damage. */
  GMutex dirty_lock;
  gboolean dirty;
  GeglRectangle dirty_rect;
};

static void
plane_changed (GeglBuffer *buffer, const GeglRectangle *rect,
               GlimsPlatePreview *preview)
{
  (void) buffer;
  GeglRectangle extent = { 0, 0, preview->map.width, preview->map.height };
  GeglRectangle damage;
  if (rect && !gegl_rectangle_intersect (&damage, rect, &extent)) return;
  if (!rect) damage = extent;
  g_mutex_lock (&preview->dirty_lock);
  if (preview->dirty)
    gegl_rectangle_bounding_box (&preview->dirty_rect, &preview->dirty_rect, &damage);
  else
    preview->dirty_rect = damage;
  preview->dirty = TRUE;
  g_mutex_unlock (&preview->dirty_lock);
}

void
glims_plate_preview_free (GlimsPlatePreview *preview)
{
  if (!preview) return;
  for (guint i = 0; i < preview->map.count; i++)
    if (preview->planes[i])
      {
        if (preview->changed[i])
          g_signal_handler_disconnect (preview->planes[i], preview->changed[i]);
        g_clear_object (&preview->planes[i]);
      }
  if (preview->buffer && preview->validate)
    gimp_tile_handler_validate_unassign (preview->validate, preview->buffer);
  g_clear_object (&preview->buffer);
  g_clear_object (&preview->validate);
  g_clear_object (&preview->graph);
  g_clear_pointer (&preview->profile, g_bytes_unref);
  g_mutex_clear (&preview->dirty_lock);
  g_free (preview);
}

static GeglNode *
solid (GeglNode *graph, const gfloat rgba[4])
{
  GeglColor *color = gegl_color_new (NULL);
  GeglNode *node;
  gegl_color_set_pixel (color, babl_format ("RGBA float"), rgba);
  node = gegl_node_new_child (graph, "operation", "gegl:color", "value", color, NULL);
  g_object_unref (color);
  return node;
}

static gdouble
srgb_to_linear (gdouble value)
{
  return value <= 0.04045 ? value / 12.92 : pow ((value + 0.055) / 1.055, 2.4);
}

static gboolean
matches (GlimsPlatePreview *preview, const GlimsPlateStorage *storage)
{
  if (!preview || memcmp (&preview->map, &storage->map, sizeof preview->map) ||
      memcmp (preview->visible, storage->visible, sizeof preview->visible))
    return FALSE;
  if (storage->profile)
    {
      gsize size = 0;
      const guint8 *bytes = preview->profile ? g_bytes_get_data (preview->profile, &size) : NULL;
      if (!bytes || size != storage->profile_size || memcmp (bytes, storage->profile, size)) return FALSE;
    }
  else if (preview->profile) return FALSE;
  for (guint i = 0; i < storage->map.count; i++)
    if (preview->planes[i] != gimp_drawable_get_buffer (GIMP_DRAWABLE (storage->planes[i])))
      return FALSE;
  return TRUE;
}

static GlimsPlatePreview *
create (const GlimsPlateStorage *storage)
{
  static const gchar *const required[] = {
    "gegl:color", "gegl:buffer-source", "gegl:multiply", "gegl:add", "gegl:crop"
  };
  const gfloat white[4] = { 1, 1, 1, 1 };
  GlimsPlatePreview *preview;
  GeglNode *last, *crop;
  GeglRectangle extent = { 0, 0, storage->map.width, storage->map.height };

  if (storage->map.mode == GLIMS_PLATE_MODE_MULTICHANNEL)
    {
      for (guint i = 0; i < G_N_ELEMENTS (required); i++)
        if (!gegl_has_operation (required[i])) return NULL;
    }
  else if (storage->map.mode != GLIMS_PLATE_MODE_CMYK &&
           storage->map.mode != GLIMS_PLATE_MODE_LAB)
    return NULL;
  preview = g_try_new0 (GlimsPlatePreview, 1);
  if (!preview) return NULL;
  g_mutex_init (&preview->dirty_lock);
  preview->map = storage->map;
  preview->dirty = TRUE;
  preview->dirty_rect = extent;
  memcpy (preview->visible, storage->visible, sizeof preview->visible);
  if (storage->map.mode == GLIMS_PLATE_MODE_CMYK ||
      storage->map.mode == GLIMS_PLATE_MODE_LAB)
    {
      if (storage->map.mode == GLIMS_PLATE_MODE_CMYK)
        preview->profile = g_bytes_new (storage->profile, storage->profile_size);
      for (guint i = 0; i < storage->map.count; i++)
        {
          preview->planes[i] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (storage->planes[i])));
          preview->changed[i] = g_signal_connect (preview->planes[i], "changed",
                                                  G_CALLBACK (plane_changed), preview);
        }
      preview->validate = storage->map.mode == GLIMS_PLATE_MODE_CMYK
                            ? glims_plate_cmyk_preview_new (storage)
                            : glims_plate_lab_preview_new (storage);
      if (!preview->validate) { glims_plate_preview_free (preview); return NULL; }
      preview->buffer = gegl_buffer_new (&extent, babl_format ("RGBA float"));
      gimp_tile_handler_validate_assign (preview->validate, preview->buffer);
      return preview;
    }
  preview->graph = gegl_node_new ();
  last = solid (preview->graph, white);
  for (guint i = 0; i < storage->map.count; i++)
    {
      gfloat ink[4] = { 0, 0, 0, 1 }, inverse[4] = { 0, 0, 0, 1 };
      GeglNode *source, *multiply, *add, *blend;
      for (guint c = 0; c < 3; c++)
        {
          ink[c] = srgb_to_linear (storage->map.entries[i].ink_rgb[c]);
          inverse[c] = 1 - ink[c];
        }
      preview->planes[i] = g_object_ref (gimp_drawable_get_buffer (GIMP_DRAWABLE (storage->planes[i])));
      preview->changed[i] = g_signal_connect (preview->planes[i], "changed",
                                              G_CALLBACK (plane_changed), preview);
      if (!storage->visible[i]) continue;
      source = gegl_node_new_child (preview->graph, "operation", "gegl:buffer-source",
                                     "buffer", preview->planes[i], NULL);
      multiply = gegl_node_new_child (preview->graph, "operation", "gegl:multiply", NULL);
      add = gegl_node_new_child (preview->graph, "operation", "gegl:add", NULL);
      blend = gegl_node_new_child (preview->graph, "operation", "gegl:multiply", NULL);
      /* Each ink attenuates white by I + (1-I)*ink, with scalar intensity I.
       * This preview is a defined additive-RGB approximation, not a press proof.
       * Compose full-resolution colors before deriving any mipmap levels. */
      gegl_node_link (solid (preview->graph, inverse), multiply);
      gegl_node_connect_to (source, "output", multiply, "aux");
      gegl_node_link (multiply, add);
      gegl_node_connect_to (solid (preview->graph, ink), "output", add, "aux");
      gegl_node_link (last, blend);
      gegl_node_connect_to (add, "output", blend, "aux");
      last = blend;
    }
  crop = gegl_node_new_child (preview->graph, "operation", "gegl:crop",
                              "width", (gdouble) storage->map.width,
                              "height", (gdouble) storage->map.height, NULL);
  gegl_node_link (last, crop);
  preview->buffer = gegl_buffer_new (&extent, babl_format ("RGBA float"));
  preview->validate = GIMP_TILE_HANDLER_VALIDATE (gimp_tile_handler_validate_new (crop));
  gimp_tile_handler_validate_assign (preview->validate, preview->buffer);
  return preview;
}

GlimsStatus
glims_plate_preview_prepare (GimpImage *image, GlimsPlatePreview **preview,
                             GeglBuffer **buffer)
{
  GlimsPlateStorage storage;
  if (buffer) *buffer = NULL;
  if (!preview || !buffer) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (glims_plate_storage_read (image, &storage) != GLIMS_PLATE_STORAGE_VALID)
    {
      g_clear_pointer (preview, glims_plate_preview_free);
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (!matches (*preview, &storage))
    {
      g_clear_pointer (preview, glims_plate_preview_free);
      *preview = create (&storage);
      if (!*preview) return GLIMS_STATUS_FAILED;
    }
  /* Consume damage once. A later write remains pending for the next read,
   * including one arriving while the validator processes this rectangle. */
  g_mutex_lock (&(*preview)->dirty_lock);
  gboolean dirty = (*preview)->dirty;
  GeglRectangle damage = (*preview)->dirty_rect;
  (*preview)->dirty = FALSE;
  g_mutex_unlock (&(*preview)->dirty_lock);
  if (dirty)
    gimp_tile_handler_validate_invalidate ((*preview)->validate, &damage);
  if ((*preview)->map.mode == GLIMS_PLATE_MODE_CMYK ||
      (*preview)->map.mode == GLIMS_PLATE_MODE_LAB)
    {
      GeglRectangle extent = { 0, 0, storage.map.width, storage.map.height };
      if ((*preview)->map.mode == GLIMS_PLATE_MODE_CMYK)
        glims_plate_cmyk_preview_prepare ((*preview)->validate, &extent);
      else
        glims_plate_lab_preview_prepare ((*preview)->validate, &extent);
    }
  *buffer = (*preview)->buffer;
  return GLIMS_STATUS_OK;
}

gboolean
glims_plate_preview_succeeded (GlimsPlatePreview *preview)
{
  if (!preview)
    return TRUE;
  if (preview->map.mode == GLIMS_PLATE_MODE_CMYK)
    return glims_plate_cmyk_preview_succeeded (preview->validate);
  if (preview->map.mode == GLIMS_PLATE_MODE_LAB)
    return glims_plate_lab_preview_succeeded (preview->validate);
  return TRUE;
}
