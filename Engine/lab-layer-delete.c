#include "lab-layer-delete.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include "layer-duplicate-selection-undo.h"
#include <string.h>
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

static GlimsStatus
refuse (char **error, GlimsStatus status, const char *message)
{
  if (error) *error = g_strdup (message);
  return status;
}

static GlimsStatus
admit (GlimsEngine *engine, GimpImage *image, GimpLayer *source,
       GlimsLabLayerStorage *storage, guint *source_index, char **error)
{
  if (!engine || !engine->gimp || !engine->strokes || !engine->filters ||
      !image || !GIMP_IS_IMAGE (image) || image->gimp != engine->gimp ||
      !source || !GIMP_IS_LAYER (source))
    return refuse (error, GLIMS_STATUS_INVALID_ARGUMENT, "The Lab layer ownership is invalid.");
  if (engine->busy || g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters) ||
      !gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image))
    return refuse (error, GLIMS_STATUS_BUSY, "Finish active edits and enable Undo before deleting a Lab layer.");
  if (gimp_item_get_image (GIMP_ITEM (source)) != image || !gimp_item_is_attached (GIMP_ITEM (source)))
    return refuse (error, GLIMS_STATUS_NOT_FOUND, "The source Lab layer is no longer attached to this image.");
  if (glims_lab_layer_storage_read (image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "This image is not a supported Lab layer carrier.");
  for (*source_index = 0; *source_index < storage->map.count; (*source_index)++)
    if (storage->layers[*source_index].group == source) break;
  if (*source_index == storage->map.count || G_OBJECT_TYPE (source) != GIMP_TYPE_GROUP_LAYER)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "Select a logical Lab root layer to delete.");
  return GLIMS_STATUS_OK;
}

static gboolean
contains (GPtrArray *items, gpointer item)
{
  for (guint i = 0; i < items->len; i++)
    if (g_ptr_array_index (items, i) == item) return TRUE;
  return FALSE;
}

static gboolean
logical_root (const GlimsLabLayerStorage *storage, gpointer item)
{
  for (guint i = 0; i < storage->map.count; i++)
    if (storage->layers[i].group == item) return TRUE;
  return FALSE;
}

static gboolean
selection_matches (GimpImage *image, GPtrArray *expected)
{
  GList *selected = gimp_image_get_selected_layers (image); /* borrowed */
  for (guint i = 0; i < expected->len; i++)
    {
      if (!selected || selected->data != g_ptr_array_index (expected, i)) return FALSE;
      selected = selected->next;
    }
  return selected == NULL;
}

static gboolean
same_tree (const GlimsLabLayerStorage *before, const GlimsLabLayerStorage *current)
{
  if (memcmp (&before->map, &current->map, sizeof before->map)) return FALSE;
  for (guint i = 0; i < before->map.count; i++)
    {
      if (before->layers[i].group != current->layers[i].group ||
          before->layers[i].map_index != current->layers[i].map_index) return FALSE;
      for (guint role = 0; role < 4; role++)
        if (before->layers[i].planes[role] != current->layers[i].planes[role]) return FALSE;
    }
  return TRUE;
}

GlimsStatus
glims_lab_layer_delete (GlimsEngine *engine, GimpImage *image,
                        GimpLayer *explicit_source, char **error)
{
  GlimsLabLayerStorage storage, current;
  guint source_index, current_index;
  GlimsStatus status = admit (engine, image, explicit_source, &storage, &source_index, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* Hold the removed tree through postvalidation even if native history policy
   * immediately expires its Undo reference. Arrays own only our extra refs. */
  GimpLayer *source = g_object_ref (explicit_source);
  GPtrArray *before = g_ptr_array_new_with_free_func (g_object_unref);
  GPtrArray *after = g_ptr_array_new_with_free_func (g_object_unref);
  GList *after_list = NULL;
  GimpParasite *mapping = NULL;
  for (GList *it = gimp_image_get_selected_layers (image); it; it = it->next)
    {
      GimpItem *item = it->data;
      if (!GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image ||
          !gimp_item_is_attached (item) || contains (before, item))
        { status = refuse (error, GLIMS_STATUS_UNSUPPORTED, "The current layer selection cannot be preserved."); goto done; }
      g_ptr_array_add (before, g_object_ref (item));
      if (item != GIMP_ITEM (source) && logical_root (&storage, item))
        g_ptr_array_add (after, g_object_ref (item));
    }
  if (!after->len)
    for (guint i = 0; i < storage.map.count; i++)
      if (storage.layers[i].group != source)
        { g_ptr_array_add (after, g_object_ref (storage.layers[i].group)); break; }
  for (guint i = 0; i < after->len; i++)
    after_list = g_list_prepend (after_list, g_ptr_array_index (after, i));
  after_list = g_list_reverse (after_list);

  /* Membership order is independent of native stacking order. Compact the
   * removed map entry and explicitly clear its now-inactive trailing slot. */
  GlimsLabLayerMap map = storage.map;
  guint map_index = storage.layers[source_index].map_index;
  if (map_index + 1 < map.count)
    memmove (&map.entries[map_index], &map.entries[map_index+1],
             (map.count-map_index-1) * sizeof map.entries[0]);
  map.count--;
  memset (&map.entries[map.count], 0, sizeof map.entries[0]);
  guint8 encoded[GLIMS_LAB_LAYER_MAP_MAX_SIZE];
  size_t length = 0;
  if (!glims_lab_layer_map_encode (&map, encoded, sizeof encoded, &length))
    { status = refuse (error, GLIMS_STATUS_FAILED, "The remaining Lab layer map could not be staged."); goto done; }
  mapping = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, (guint32) length, encoded);
  if (!mapping)
    { status = refuse (error, GLIMS_STATUS_FAILED, "The remaining Lab layer metadata could not be staged."); goto done; }

  status = admit (engine, image, source, &current, &current_index, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (current_index != source_index || !same_tree (&storage, &current) || !selection_matches (image, before))
    { status = refuse (error, GLIMS_STATUS_BUSY, "The Lab layer state changed while deletion was staged."); goto done; }

  engine->busy++;
  if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "Delete Lab Layer"))
    status = refuse (error, GLIMS_STATUS_FAILED, "The native deletion Undo group could not start; history may have changed.");
  else
    {
      /* FIRST record runs LAST on Undo, after native removal Undo has restored
       * the tree. Native re-add alone selects only the restored layer. Reuse
       * the existing weak ordered-selection companion, including empty lists. */
      if (!glims_layer_selection_undo_push (image, before, after))
        status = refuse (error, GLIMS_STATUS_FAILED, "The deletion selection Undo could not be recorded; history may have changed.");
      else
        {
          gimp_image_set_selected_layers (image, after_list);
          gimp_image_remove_layer (image, source, TRUE, NULL);
          gimp_image_parasite_attach (image, mapping, TRUE);
          status = GLIMS_STATUS_OK;
        }
      if (!gimp_image_undo_group_end (image) && status == GLIMS_STATUS_OK)
        status = refuse (error, GLIMS_STATUS_FAILED, "The native deletion Undo group could not finish; history may have changed.");
    }
  if (status == GLIMS_STATUS_OK)
    {
      gboolean valid = !gimp_item_is_attached (GIMP_ITEM (source)) &&
        glims_lab_layer_storage_read (image, &current) == GLIMS_LAB_LAYER_STORAGE_VALID &&
        !memcmp (&current.map, &map, sizeof map) && selection_matches (image, after);
      guint remaining = 0;
      if (valid)
        for (guint i = 0; i < storage.map.count; i++)
          if (i != source_index && current.layers[remaining++].group != storage.layers[i].group)
            { valid = FALSE; break; }
      if (!valid)
        status = refuse (error, GLIMS_STATUS_FAILED, "The native deleted carrier failed validation; its state may have changed.");
    }
  engine->busy--;

done:
  if (mapping) gimp_parasite_free (mapping);
  g_list_free (after_list);
  g_ptr_array_unref (before);
  g_ptr_array_unref (after);
  g_object_unref (source);
  return status;
}
