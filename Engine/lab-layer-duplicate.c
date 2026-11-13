#include "lab-layer-duplicate.h"
#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <string.h>
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpitemtree.h"
#include "core/gimplayer.h"
#include "core/gimpviewable.h"

static GlimsStatus
refuse (char **error, GlimsStatus status, const char *message)
{
  if (error) *error = g_strdup (message);
  return status;
}

static const guint8 *
entry_uuid (const GlimsLabLayerEntry *entry, guint role)
{
  switch (role)
    {
    case 0: return entry->group;
    case 1: return entry->l;
    case 2: return entry->a;
    case 3: return entry->b;
    default: return entry->alpha;
    }
}

static gboolean
uuid_matches (GimpItem *item, const guint8 expected[16])
{
  const GimpParasite *parasite = gimp_item_parasite_find (item, GLIMS_PLATE_UUID_PARASITE);
  guint32 size = 0;
  if (!parasite || !gimp_parasite_is_persistent (parasite)) return FALSE;
  const guint8 *bytes = gimp_parasite_get_data (parasite, &size);
  return bytes && size == 16 && !memcmp (bytes, expected, 16);
}

static gboolean
buffer_matches (GimpLayer *plane, const Babl *format, const GlimsLabLayerMap *map)
{
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (plane));
  if (!buffer || gegl_buffer_get_format (buffer) != format) return FALSE;
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  return extent && !extent->x && !extent->y && extent->width == (gint) map->width &&
    extent->height == (gint) map->height;
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
    return refuse (error, GLIMS_STATUS_BUSY, "Finish active edits and enable Undo before duplicating a Lab layer.");
  if (gimp_item_get_image (GIMP_ITEM (source)) != image || !gimp_item_is_attached (GIMP_ITEM (source)))
    return refuse (error, GLIMS_STATUS_NOT_FOUND, "The source Lab layer is no longer attached to this image.");
  if (glims_lab_layer_storage_read (image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "This image is not a supported Lab layer carrier.");
  for (*source_index = 0; *source_index < storage->map.count; (*source_index)++)
    if (storage->layers[*source_index].group == source) break;
  if (*source_index == storage->map.count || G_OBJECT_TYPE (source) != GIMP_TYPE_GROUP_LAYER)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "Select a logical Lab root layer to duplicate.");
  if (storage->map.count >= GLIMS_LAB_LAYER_LIMIT)
    return refuse (error, GLIMS_STATUS_UNSUPPORTED, "The Lab layer limit has been reached.");
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  for (guint i = 0; i < storage->map.count; i++)
    for (guint role = 0; role < 4; role++)
      if (!buffer_matches (storage->layers[i].planes[role], format, &storage->map))
        return refuse (error, GLIMS_STATUS_UNSUPPORTED, "A Lab scalar buffer has unsupported geometry or format.");
  return GLIMS_STATUS_OK;
}

static gboolean
fresh_entry (GlimsLabLayerMap *map)
{
  GlimsLabLayerEntry *entry = &map->entries[map->count-1];
  guint8 *ids[] = { entry->group, entry->l, entry->a, entry->b, entry->alpha };
  /* Regenerate the complete five-identity entry on collision. Validation
   * includes every old identity and every newly generated role. */
  for (guint attempt = 0; attempt < 16; attempt++)
    {
      for (guint role = 0; role < 5; role++)
        {
          gchar *text = g_uuid_string_random ();
          gboolean valid = text && g_uuid_string_is_valid (text);
          guint nibbles = 0;
          if (valid)
            for (const gchar *p = text; *p; p++)
              if (*p != '-')
                {
                  guint value = (guint) g_ascii_xdigit_value (*p);
                  if (nibbles & 1) ids[role][nibbles/2] |= (guint8) value;
                  else ids[role][nibbles/2] = (guint8) (value << 4);
                  nibbles++;
                }
          g_free (text);
          if (!valid || nibbles != 32) return FALSE;
        }
      if (glims_lab_layer_map_validate (map)) return TRUE;
    }
  return FALSE;
}

static gboolean
plain_attributes (GimpLayer *layer)
{
  GimpItem *item = GIMP_ITEM (layer);
  GimpContainer *filters = gimp_drawable_get_filters (GIMP_DRAWABLE (layer));
  return !gimp_item_get_lock_content (item) && !gimp_item_get_lock_position (item) &&
    !gimp_item_get_lock_visibility (item) && !gimp_layer_get_lock_alpha (layer) &&
    !gimp_layer_get_mask (layer) && filters && !gimp_container_get_n_children (filters) &&
    gimp_layer_get_mode (layer) == GIMP_LAYER_MODE_NORMAL &&
    gimp_layer_get_blend_space (layer) == GIMP_LAYER_COLOR_SPACE_AUTO &&
    gimp_layer_get_composite_space (layer) == GIMP_LAYER_COLOR_SPACE_AUTO &&
    gimp_layer_get_composite_mode (layer) == GIMP_LAYER_COMPOSITE_AUTO;
}

static gboolean
detached_extent (GimpItem *item, GimpImage *image, GimpItem *parent, const GlimsLabLayerMap *map)
{
  gint x, y;
  gimp_item_get_offset (item, &x, &y);
  return !gimp_item_is_attached (item) && gimp_item_get_image (item) == image &&
    gimp_item_get_parent (item) == parent && !x && !y &&
    gimp_item_get_width (item) == (gint) map->width &&
    gimp_item_get_height (item) == (gint) map->height;
}

static gboolean
check_detached (GimpImage *image, GimpLayer *copy, const GlimsLabLayerNative *source,
                const GlimsLabLayerMap *map, const GlimsLabLayerEntry *entry, GimpLayer *planes[4])
{
  memset (planes, 0, 4 * sizeof *planes);
  if (!copy || copy == source->group || G_OBJECT_TYPE (copy) != GIMP_TYPE_GROUP_LAYER ||
      !detached_extent (GIMP_ITEM (copy), image, NULL, map) || !plain_attributes (copy) ||
      !uuid_matches (GIMP_ITEM (copy), entry->group) ||
      gimp_item_get_visible (GIMP_ITEM (copy)) != gimp_item_get_visible (GIMP_ITEM (source->group)) ||
      gimp_layer_get_opacity (copy) != gimp_layer_get_opacity (source->group)) return FALSE;
  GimpContainer *children = gimp_viewable_get_children (GIMP_VIEWABLE (copy));
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  if (!children || gimp_container_get_n_children (children) != 4) return FALSE;
  for (guint i = 0; i < 4; i++)
    {
      GimpObject *object = gimp_container_get_child_by_index (children, i);
      if (!object || G_OBJECT_TYPE (object) != GIMP_TYPE_LAYER) return FALSE;
      GimpLayer *plane = GIMP_LAYER (object);
      if (!detached_extent (GIMP_ITEM (plane), image, GIMP_ITEM (copy), map) ||
          !plain_attributes (plane) || !gimp_item_get_visible (GIMP_ITEM (plane)) ||
          gimp_layer_get_opacity (plane) != 1 || gimp_drawable_has_alpha (GIMP_DRAWABLE (plane)) ||
          gimp_viewable_get_children (GIMP_VIEWABLE (plane)) || !buffer_matches (plane, format, map))
        return FALSE;
      guint role;
      for (role = 0; role < 4; role++)
        if (uuid_matches (GIMP_ITEM (plane), entry_uuid (entry, role+1))) break;
      if (role == 4 || planes[role] || plane == source->planes[role] ||
          gimp_drawable_get_buffer (GIMP_DRAWABLE (plane)) ==
          gimp_drawable_get_buffer (GIMP_DRAWABLE (source->planes[role]))) return FALSE;
      planes[role] = plane;
    }
  return TRUE;
}

static gboolean
rewrite_uuid (GimpItem *item, GimpImage *image, const guint8 uuid[16])
{
  /* Item attach's upstream UNDOABLE group_end is unsafe on an attached item
   * with pushFALSE. Prove detachment before EVERY rewrite; fixed flags also
   * exclude ATTACH_PARENT/GRANDPARENT propagation, including while detached. */
  if (gimp_item_is_attached (item) || gimp_item_get_image (item) != image) return FALSE;
  GimpParasite *parasite = gimp_parasite_new (GLIMS_PLATE_UUID_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, 16, uuid);
  if (!parasite) return FALSE;
  gimp_item_parasite_attach (item, parasite, FALSE);
  gimp_parasite_free (parasite);
  return uuid_matches (item, uuid);
}

GlimsStatus
glims_lab_layer_duplicate (GlimsEngine *engine, GimpImage *image, GimpLayer *source,
                           GimpLayer **borrowed_copy, char **error)
{
  if (borrowed_copy) *borrowed_copy = NULL;
  if (!borrowed_copy) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsLabLayerStorage storage, current;
  guint source_index, current_index;
  GlimsStatus status = admit (engine, image, source, &storage, &source_index, error);
  if (status != GLIMS_STATUS_OK) return status;
  GlimsLabLayerMap map = storage.map;
  guint map_index = storage.layers[source_index].map_index;
  guint new_index = map.count++;
  if (!fresh_entry (&map))
    return refuse (error, GLIMS_STATUS_FAILED, "Fresh Lab layer identities could not be generated.");

  GimpLayer *copy = GIMP_LAYER (gimp_item_duplicate (GIMP_ITEM (source), GIMP_TYPE_GROUP_LAYER));
  if (!copy) return refuse (error, GLIMS_STATUS_FAILED, "The logical Lab layer could not be duplicated.");
  copy = g_object_ref_sink (copy);
  GimpLayer *planes[4];
  GimpParasite *mapping = NULL;
  if (!check_detached (image, copy, &storage.layers[source_index], &storage.map,
                        &storage.map.entries[map_index], planes)) goto invalid_copy;
  /* All five items were proved detached before changing the first identity. */
  if (!rewrite_uuid (GIMP_ITEM (copy), image, map.entries[new_index].group)) goto invalid_copy;
  for (guint role = 0; role < 4; role++)
    if (!rewrite_uuid (GIMP_ITEM (planes[role]), image, entry_uuid (&map.entries[new_index], role+1)))
      goto invalid_copy;
  if (!check_detached (image, copy, &storage.layers[source_index], &map,
                        &map.entries[new_index], planes)) goto invalid_copy;
  guint8 encoded[GLIMS_LAB_LAYER_MAP_MAX_SIZE];
  size_t length = 0;
  if (!glims_lab_layer_map_encode (&map, encoded, sizeof encoded, &length)) goto invalid_copy;
  mapping = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, (guint32) length, encoded);
  if (!mapping) goto invalid_copy;

  /* Final admission immediately precedes the insertion preflight/commit.
   * Caller quiescence is what makes native duplicate a coherent pixel copy. */
  status = admit (engine, image, source, &current, &current_index, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (current_index != source_index || memcmp (&storage.map, &current.map, sizeof storage.map) ||
      current.layers[current_index].map_index != map_index ||
      !check_detached (image, copy, &current.layers[current_index], &map, &map.entries[new_index], planes))
    { status = refuse (error, GLIMS_STATUS_BUSY, "The Lab layer changed while its copy was staged."); goto done; }
  GimpItem *parent = NULL;
  gint position = gimp_item_get_index (GIMP_ITEM (source)), checked_position = position;
  if (position < 0 || !gimp_item_tree_get_insert_pos (gimp_image_get_layer_tree (image),
        GIMP_ITEM (copy), &parent, &checked_position) || parent || checked_position != position)
    { status = refuse (error, GLIMS_STATUS_FAILED, "The Lab layer copy cannot be inserted above its source."); goto done; }

  engine->busy++;
  if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_LAYER_ADD, "Duplicate Lab Layer"))
    status = refuse (error, GLIMS_STATUS_FAILED, "The native duplication Undo group could not start; history may have changed.");
  else
    {
      if (!gimp_image_add_layer (image, copy, NULL, position, TRUE))
        status = refuse (error, GLIMS_STATUS_FAILED, "The native layer insertion failed after preflight; history may have changed.");
      else
        {
          /* Native layer-add captures old ordered selection and selects this
           * one copy; its retained object carries the same UUIDs through Redo. */
          gimp_image_parasite_attach (image, mapping, TRUE);
          status = GLIMS_STATUS_OK;
        }
      if (!gimp_image_undo_group_end (image) && status == GLIMS_STATUS_OK)
        status = refuse (error, GLIMS_STATUS_FAILED, "The native duplication Undo group could not finish; history may have changed.");
    }
  if (status == GLIMS_STATUS_OK)
    {
      if (glims_lab_layer_storage_read (image, &current) != GLIMS_LAB_LAYER_STORAGE_VALID ||
          memcmp (&current.map, &map, sizeof map))
        status = refuse (error, GLIMS_STATUS_FAILED, "The native duplicated carrier failed validation; its state may have changed.");
      else *borrowed_copy = copy;
    }
  engine->busy--;
  goto done;

invalid_copy:
  status = refuse (error, GLIMS_STATUS_FAILED, "The staged Lab layer copy did not preserve its scalar structure.");
done:
  if (mapping) gimp_parasite_free (mapping);
  g_object_unref (copy); /* owned staging ref; image/Undo own attached copies */
  return status;
}
