#include "plate-preview.h"
#include <cairo.h>
#include <math.h>
#include <string.h>
#include "core/gimpdrawable.h"
#include "gegl/gimptilehandlervalidate.h"

struct _GlimsPlatePreview {
  GlimsPlateMap map;
  gboolean visible[GLIMS_PLATE_LIMIT];
  GeglNode *graph;
  GeglBuffer *buffer;
  GimpTileHandlerValidate *validate;
  GeglBuffer *planes[GLIMS_PLATE_LIMIT];
  gulong changed[GLIMS_PLATE_LIMIT];
  /* A GEGL write may emit from a worker. Only the engine thread touches
   * graph/validator state; the signal merely schedules invalidation. */
  gint dirty;
};

static void
plane_changed (GeglBuffer *buffer, const GeglRectangle *rect,
               GlimsPlatePreview *preview)
{
  (void) buffer;
  (void) rect;
  g_atomic_int_set (&preview->dirty, 1);
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

  for (guint i = 0; i < G_N_ELEMENTS (required); i++)
    if (!gegl_has_operation (required[i])) return NULL;
  preview = g_try_new0 (GlimsPlatePreview, 1);
  if (!preview) return NULL;
  preview->map = storage->map;
  memcpy (preview->visible, storage->visible, sizeof preview->visible);
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
  g_atomic_int_set (&preview->dirty, 1);
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
  if (g_atomic_int_compare_and_exchange (&(*preview)->dirty, 1, 0))
    gimp_tile_handler_validate_invalidate ((*preview)->validate,
                                           gegl_buffer_get_extent ((*preview)->buffer));
  *buffer = (*preview)->buffer;
  return GLIMS_STATUS_OK;
}
