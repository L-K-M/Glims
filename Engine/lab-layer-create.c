#include "lab-layer-create.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include "layer-duplicate-selection-undo.h"
#include <string.h>
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpitemtree.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpobject.h"
#include "core/gimpviewable.h"

static GlimsStatus
refuse (char **error, GlimsStatus status, const char *message)
{
  if (error) *error = g_strdup (message);
  return status;
}

static GlimsStatus
admit (GlimsEngine *engine, GimpImage *image, int32_t index,
       GlimsLabLayerStorage *storage, char **error)
{
  if (!engine || !engine->gimp || !engine->strokes || !engine->filters ||
      !image || !GIMP_IS_IMAGE (image) || image->gimp != engine->gimp)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT, "The Lab image ownership is invalid.");
  if (engine->busy || g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters) ||
      !gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image))
    return refuse (error, GLIMS_STATUS_BUSY, "Finish active edits and enable Undo before adding a Lab layer.");
  if (glims_lab_layer_storage_read (image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "This image is not a supported Lab layer carrier.");
  if (index < 0 || (guint32) index > storage->map.count)
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT, "The new Lab layer position is out of range.");
  if (storage->map.count >= GLIMS_LAB_LAYER_LIMIT)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "The Lab layer limit has been reached.");
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  for (guint i = 0; i < storage->map.count; i++)
    for (guint role = 0; role < 4; role++)
      {
        GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (storage->layers[i].planes[role]));
        const GeglRectangle *extent = buffer ? gegl_buffer_get_extent (buffer) : NULL;
        if (!extent || extent->x || extent->y || extent->width != (gint) storage->map.width ||
            extent->height != (gint) storage->map.height || gegl_buffer_get_format (buffer) != format)
          return refuse (error, GLIMS_STATUS_UNSUPPORTED, "A Lab scalar buffer has unsupported geometry or format.");
      }
  return GLIMS_STATUS_OK;
}

static gboolean
fresh_entry (GlimsLabLayerMap *map)
{
  GlimsLabLayerEntry *entry = &map->entries[map->count - 1];
  guint8 *ids[] = { entry->group, entry->l, entry->a, entry->b, entry->alpha };
  for (guint attempt = 0; attempt < 16; attempt++)
    {
      for (guint role = 0; role < G_N_ELEMENTS (ids); role++)
        {
          gchar *uuid = g_uuid_string_random ();
          guint nibbles = 0;
          gboolean valid = uuid && g_uuid_string_is_valid (uuid);
          if (valid)
            for (const gchar *p = uuid; *p; p++)
              if (*p != '-')
                {
                  guint value = (guint) g_ascii_xdigit_value (*p);
                  if (nibbles & 1) ids[role][nibbles / 2] |= (guint8) value;
                  else ids[role][nibbles / 2] = (guint8) (value << 4);
                  nibbles++;
                }
          g_free (uuid);
          if (!valid || nibbles != 32) return FALSE;
        }
      if (glims_lab_layer_map_validate (map)) return TRUE;
    }
  return FALSE;
}

static gboolean
attach_uuid (GimpItem *item, const guint8 uuid[16])
{
  if (gimp_item_is_attached (item)) return FALSE;
  GimpParasite *p = gimp_parasite_new (GLIMS_PLATE_UUID_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, 16, uuid);
  if (!p) return FALSE;
  /* Never propagate identity to an image or parent, including while detached. */
  gimp_item_parasite_attach (item, p, FALSE);
  gimp_parasite_free (p);
  const GimpParasite *stored = gimp_item_parasite_find (item, GLIMS_PLATE_UUID_PARASITE);
  guint32 size = 0;
  const void *bytes = stored ? gimp_parasite_get_data (stored, &size) : NULL;
  return bytes && size == 16 && !memcmp (bytes, uuid, 16);
}

static void
initialize_attributes (GimpLayer *layer)
{
  gimp_item_set_visible (GIMP_ITEM (layer), TRUE, FALSE);
  gimp_layer_set_opacity (layer, 1, FALSE);
  gimp_layer_set_mode (layer, GIMP_LAYER_MODE_NORMAL, FALSE);
  gimp_layer_set_blend_space (layer, GIMP_LAYER_COLOR_SPACE_AUTO, FALSE);
  gimp_layer_set_composite_space (layer, GIMP_LAYER_COLOR_SPACE_AUTO, FALSE);
  gimp_layer_set_composite_mode (layer, GIMP_LAYER_COMPOSITE_AUTO, FALSE);
}

static GimpLayer *
stage_layer (GimpImage *image, const GlimsLabLayerMap *map, const char *name)
{
  const GlimsLabLayerEntry *entry = &map->entries[map->count - 1];
  const guint8 *ids[] = { entry->l, entry->a, entry->b, entry->alpha };
  static const gchar *names[] = { "Lightness", "a", "b", "Alpha" };
  static const guint8 values[] = { 255, 128, 128, 0 };
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  GimpLayer *group = gimp_group_layer_new (image);
  if (!group) return NULL;
  g_object_ref_sink (group);
  initialize_attributes (group);
  gimp_object_set_name (GIMP_OBJECT (group), name);
  if (!attach_uuid (GIMP_ITEM (group), entry->group)) goto failed;
  GimpContainer *children = gimp_viewable_get_children (GIMP_VIEWABLE (group));
  if (!children) goto failed;

  /* Core's group duplicate builds detached children with explicit parentage
   * and container insertion. This keeps the image selection/history untouched. */
  for (guint role = 0; role < 4; role++)
    {
      GimpLayer *plane = gimp_layer_new (image, map->width, map->height,
        format, names[role], 1, GIMP_LAYER_MODE_NORMAL);
      if (!plane) goto failed;
      g_object_ref_sink (plane);
      initialize_attributes (plane);
      GeglBuffer *pattern = gegl_buffer_new (GEGL_RECTANGLE (0, 0, 1, 1), format);
      if (!pattern || !attach_uuid (GIMP_ITEM (plane), ids[role]))
        {
          if (pattern) g_object_unref (pattern);
          g_object_unref (plane);
          goto failed;
        }
      gegl_buffer_set (pattern, GEGL_RECTANGLE (0, 0, 1, 1), 0, format,
                       &values[role], GEGL_AUTO_ROWSTRIDE);
      gegl_buffer_set_pattern (gimp_drawable_get_buffer (GIMP_DRAWABLE (plane)),
                               NULL, pattern, 0, 0);
      g_object_unref (pattern);
      gimp_drawable_update (GIMP_DRAWABLE (plane), 0, 0, -1, -1);
      gimp_viewable_set_parent (GIMP_VIEWABLE (plane), GIMP_VIEWABLE (group));
      gboolean added = gimp_container_insert (children, GIMP_OBJECT (plane), role);
      if (!added) gimp_viewable_set_parent (GIMP_VIEWABLE (plane), NULL);
      g_object_unref (plane); /* the child container owns successful insertions */
      if (!added) goto failed;
    }
  gint x, y;
  gimp_item_get_offset (GIMP_ITEM (group), &x, &y);
  if (gimp_item_is_attached (GIMP_ITEM (group)) || x || y ||
      gimp_item_get_width (GIMP_ITEM (group)) != (gint) map->width ||
      gimp_item_get_height (GIMP_ITEM (group)) != (gint) map->height ||
      gimp_container_get_n_children (children) != 4) goto failed;
  return group;

failed:
  g_object_unref (group);
  return NULL;
}

GlimsStatus
glims_lab_layer_create (GlimsEngine *engine, GimpImage *image, int32_t index,
                        const char *name, GimpLayer **borrowed_layer, char **error)
{
  if (borrowed_layer) *borrowed_layer = NULL;
  if (!borrowed_layer) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (name && (strnlen (name, 1025) > 1024 || !g_utf8_validate (name, -1, NULL)))
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT, "Use a valid Lab layer name of at most 1024 UTF-8 bytes.");
  if (!name || !*name) name = "Layer";
  GlimsLabLayerStorage initial, current;
  GlimsStatus status = admit (engine, image, index, &initial, error);
  if (status != GLIMS_STATUS_OK) return status;
  GlimsLabLayerMap map = initial.map;
  map.count++;
  if (!fresh_entry (&map))
    return refuse (error, GLIMS_STATUS_FAILED, "Fresh Lab layer identities could not be generated.");
  guint8 encoded[GLIMS_LAB_LAYER_MAP_MAX_SIZE];
  size_t length = 0;
  if (!glims_lab_layer_map_encode (&map, encoded, sizeof encoded, &length))
    return refuse (error, GLIMS_STATUS_FAILED, "The new Lab layer map could not be encoded.");
  GimpParasite *mapping = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, (guint32) length, encoded);
  if (!mapping) return refuse (error, GLIMS_STATUS_FAILED, "The new Lab layer map could not be allocated.");
  GimpLayer *layer = stage_layer (image, &map, name);
  if (!layer)
    {
      gimp_parasite_free (mapping);
      return refuse (error, GLIMS_STATUS_FAILED, "The transparent Lab layer could not be prepared.");
    }

  GPtrArray *before = g_ptr_array_new_with_free_func (g_object_unref);
  GPtrArray *after = g_ptr_array_new_with_free_func (g_object_unref);
  for (GList *it = gimp_image_get_selected_layers (image); it; it = it->next)
    {
      GimpItem *item = it->data;
      if (!GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image ||
          !gimp_item_is_attached (item) || g_ptr_array_find (before, item, NULL))
        { status = refuse (error, GLIMS_STATUS_UNSUPPORTED, "The current layer selection cannot be preserved."); goto done; }
      g_ptr_array_add (before, g_object_ref (item));
    }
  g_ptr_array_add (after, g_object_ref (layer));

  status = admit (engine, image, index, &current, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (memcmp (&initial.map, &current.map, sizeof initial.map))
    { status = refuse (error, GLIMS_STATUS_BUSY, "The Lab carrier changed while the layer was prepared."); goto done; }
  GimpItem *parent = NULL;
  gint checked_index = index;
  if (!gimp_item_tree_get_insert_pos (gimp_image_get_layer_tree (image),
        GIMP_ITEM (layer), &parent, &checked_index) || parent || checked_index != index)
    { status = refuse (error, GLIMS_STATUS_FAILED, "The new Lab layer cannot be inserted at this position."); goto done; }

  engine->busy++;
  if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_LAYER_ADD, "New Lab Layer"))
    status = refuse (error, GLIMS_STATUS_FAILED, "The native layer Undo group could not start; history may have changed.");
  else
    {
      if (!gimp_image_add_layer (image, layer, NULL, index, TRUE))
        status = refuse (error, GLIMS_STATUS_FAILED, "The native layer insertion failed after preflight; history may have changed.");
      else
        {
          gimp_image_parasite_attach (image, mapping, TRUE);
          /* This LAST record runs FIRST on Undo. Clearing the new selection
           * before native removal preserves an empty before-list instead of
           * letting Core select an automatic surviving-root fallback. */
          if (!glims_layer_selection_undo_push (image, before, after))
            status = refuse (error, GLIMS_STATUS_FAILED, "The new layer selection Undo could not be recorded; history may have changed.");
          else status = GLIMS_STATUS_OK;
        }
      if (!gimp_image_undo_group_end (image) && status == GLIMS_STATUS_OK)
        status = refuse (error, GLIMS_STATUS_FAILED, "The native layer Undo group could not finish; history may have changed.");
    }
  if (status == GLIMS_STATUS_OK)
    {
      if (glims_lab_layer_storage_read (image, &current) != GLIMS_LAB_LAYER_STORAGE_VALID ||
          memcmp (&current.map, &map, sizeof map))
        status = refuse (error, GLIMS_STATUS_FAILED, "The native new layer failed validation; its state may have changed.");
      else *borrowed_layer = layer;
    }
  engine->busy--;
done:
  g_ptr_array_unref (before);
  g_ptr_array_unref (after);
  g_object_unref (layer);
  gimp_parasite_free (mapping);
  return status;
}
