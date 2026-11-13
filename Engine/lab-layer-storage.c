#include "lab-layer-storage.h"
#include "plate-storage.h"
#include <math.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplayermask.h"
#include "core/gimpobject.h"
#include "core/gimpviewable.h"

static const guint8 *
item_uuid (GimpItem *item)
{
  const GimpParasite *parasite = gimp_item_parasite_find (item, GLIMS_PLATE_UUID_PARASITE);
  guint32 size = 0;
  if (!parasite || !gimp_parasite_is_persistent (parasite)) return NULL;
  const guint8 *bytes = gimp_parasite_get_data (parasite, &size);
  return bytes && size == 16 ? bytes : NULL;
}

static gboolean
has_uuid (GimpItem *item)
{
  return gimp_item_parasite_find (item, GLIMS_PLATE_UUID_PARASITE) != NULL;
}

static gboolean
paths_have_uuid (GimpImage *image)
{
  gboolean found = FALSE;
  GList *paths = gimp_image_get_path_list (image);
  for (GList *iter = paths; iter && !found; iter = iter->next)
    found = has_uuid (GIMP_ITEM (iter->data));
  g_list_free (paths);
  return found;
}

static gboolean
has_orphan_uuid (GimpImage *image)
{
  gboolean found = has_uuid (GIMP_ITEM (gimp_image_get_mask (image))) || paths_have_uuid (image);
  GList *layers = gimp_image_get_layer_list (image);
  GList *channels = gimp_image_get_channel_list (image);
  /* These lists own their nodes, not the native items. The layer list includes
   * descendants; masks are separate channel-derived items. */
  for (GList *iter = layers; iter && !found; iter = iter->next)
    {
      GimpLayer *layer = iter->data;
      GimpLayerMask *mask = gimp_layer_get_mask (layer);
      found = has_uuid (GIMP_ITEM (layer)) || (mask && has_uuid (GIMP_ITEM (mask)));
    }
  for (GList *iter = channels; iter && !found; iter = iter->next)
    found = has_uuid (GIMP_ITEM (iter->data));
  g_list_free (layers);
  g_list_free (channels);
  return found;
}

static gboolean
full_extent (GimpItem *item, GimpImage *image, GimpItem *parent,
             const GlimsLabLayerMap *map)
{
  gint x, y;
  gimp_item_get_offset (item, &x, &y);
  return gimp_item_is_attached (item) && gimp_item_get_image (item) == image &&
    gimp_item_get_parent (item) == parent && !x && !y &&
    gimp_item_get_width (item) == (gint) map->width &&
    gimp_item_get_height (item) == (gint) map->height;
}

static gboolean
fixed_attributes (GimpLayer *layer)
{
  GimpItem *item = GIMP_ITEM (layer);
  GimpContainer *filters = gimp_drawable_get_filters (GIMP_DRAWABLE (layer));
  return !gimp_item_get_lock_content (item) &&
    !gimp_item_get_lock_position (item) && !gimp_item_get_lock_visibility (item) &&
    !gimp_layer_get_lock_alpha (layer) && !gimp_layer_get_mask (layer) &&
    filters && gimp_container_get_n_children (filters) == 0 &&
    gimp_layer_get_mode (layer) == GIMP_LAYER_MODE_NORMAL &&
    gimp_layer_get_blend_space (layer) == GIMP_LAYER_COLOR_SPACE_AUTO &&
    gimp_layer_get_composite_space (layer) == GIMP_LAYER_COLOR_SPACE_AUTO &&
    gimp_layer_get_composite_mode (layer) == GIMP_LAYER_COMPOSITE_AUTO;
}

static const guint8 *
role_uuid (const GlimsLabLayerEntry *entry, guint role)
{
  switch (role)
    {
    case 0: return entry->l;
    case 1: return entry->a;
    case 2: return entry->b;
    default: return entry->alpha;
    }
}

static gboolean
read_group (GimpImage *image, GimpLayer *group, GlimsLabLayerStorage *result,
            GlimsLabLayerNative *native, gboolean seen[GLIMS_LAB_LAYER_LIMIT])
{
  const guint8 *uuid = item_uuid (GIMP_ITEM (group));
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  GimpContainer *children = gimp_viewable_get_children (GIMP_VIEWABLE (group));
  gdouble opacity = gimp_layer_get_opacity (group);
  guint index;
  if (!uuid || !full_extent (GIMP_ITEM (group), image, NULL, &result->map) ||
      !fixed_attributes (group) || !isfinite (opacity) || opacity < 0 || opacity > 1 ||
      !children || gimp_container_get_n_children (children) != 4)
    return FALSE;
  for (index = 0; index < result->map.count; index++)
    if (!memcmp (uuid, result->map.entries[index].group, 16)) break;
  if (index == result->map.count || seen[index]) return FALSE;
  native->map_index = index;
  native->group = group;
  for (guint i = 0; i < 4; i++)
    {
      GimpObject *object = gimp_container_get_child_by_index (children, i);
      if (!object || G_OBJECT_TYPE (object) != GIMP_TYPE_LAYER) return FALSE;
      GimpLayer *plane = GIMP_LAYER (object);
      GimpDrawable *drawable = GIMP_DRAWABLE (plane);
      uuid = item_uuid (GIMP_ITEM (plane));
      if (!uuid || !full_extent (GIMP_ITEM (plane), image, GIMP_ITEM (group), &result->map) ||
          !fixed_attributes (plane) || !gimp_item_get_visible (GIMP_ITEM (plane)) ||
          gimp_layer_get_opacity (plane) != 1.0 || gimp_drawable_has_alpha (drawable) ||
          gimp_drawable_get_format (drawable) != format ||
          gimp_viewable_get_children (GIMP_VIEWABLE (plane)))
        return FALSE;
      guint role;
      for (role = 0; role < 4; role++)
        if (!memcmp (uuid, role_uuid (&result->map.entries[index], role), 16)) break;
      if (role == 4 || native->planes[role]) return FALSE;
      native->planes[role] = plane;
    }
  seen[index] = TRUE;
  return TRUE;
}

GlimsLabLayerStorageState
glims_lab_layer_storage_read (GimpImage *image, GlimsLabLayerStorage *out)
{
  GlimsLabLayerStorage result = {0};
  gboolean seen[GLIMS_LAB_LAYER_LIMIT] = {FALSE};
  if (!out) return GLIMS_LAB_LAYER_STORAGE_INVALID;
  memset (out, 0, sizeof *out);
  if (!image || !GIMP_IS_IMAGE (image)) return GLIMS_LAB_LAYER_STORAGE_INVALID;
  const GimpParasite *parasite = gimp_image_parasite_find (image, GLIMS_PLATE_MAP_PARASITE);
  if (!parasite)
    return gimp_image_parasite_find (image, GLIMS_PLATE_PROFILE_PARASITE) || has_orphan_uuid (image)
      ? GLIMS_LAB_LAYER_STORAGE_INVALID : GLIMS_LAB_LAYER_STORAGE_NONE;

  guint32 size = 0;
  const guint8 *bytes = gimp_parasite_get_data (parasite, &size);
  if (!gimp_parasite_is_persistent (parasite) ||
      !glims_lab_layer_map_decode (bytes, size, &result.map) ||
      gimp_image_get_base_type (image) != GIMP_GRAY ||
      gimp_image_get_precision (image) != GIMP_PRECISION_U8_LINEAR ||
      gimp_image_get_width (image) != (gint) result.map.width ||
      gimp_image_get_height (image) != (gint) result.map.height ||
      gimp_container_get_n_children (gimp_image_get_channels (image)) != 0 ||
      gimp_image_get_quick_mask_state (image) || gimp_image_get_floating_selection (image) ||
      gimp_image_parasite_find (image, GLIMS_PLATE_PROFILE_PARASITE) ||
      gimp_image_parasite_find (image, GIMP_ICC_PROFILE_PARASITE_NAME) ||
      gimp_image_parasite_find (image, GIMP_SIMULATION_ICC_PROFILE_PARASITE_NAME) ||
      has_uuid (GIMP_ITEM (gimp_image_get_mask (image))) || paths_have_uuid (image))
    return GLIMS_LAB_LAYER_STORAGE_INVALID;
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  GimpContainer *roots = gimp_image_get_layers (image);
  if (babl_format_get_n_components (format) != 1 || babl_format_get_bytes_per_pixel (format) != 1 ||
      gimp_container_get_n_children (roots) != (gint) result.map.count)
    return GLIMS_LAB_LAYER_STORAGE_INVALID;
  for (guint i = 0; i < result.map.count; i++)
    {
      GimpObject *object = gimp_container_get_child_by_index (roots, i);
      if (!object || G_OBJECT_TYPE (object) != GIMP_TYPE_GROUP_LAYER ||
          !read_group (image, GIMP_LAYER (object), &result, &result.layers[i], seen))
        return GLIMS_LAB_LAYER_STORAGE_INVALID;
    }
  for (guint i = 0; i < result.map.count; i++)
    if (!seen[i]) return GLIMS_LAB_LAYER_STORAGE_INVALID;
  memcpy (out, &result, sizeof result);
  return GLIMS_LAB_LAYER_STORAGE_VALID;
}

static gboolean
attach_uuid (GimpItem *item, const guint8 uuid[16])
{
  GimpParasite *parasite = gimp_parasite_new (GLIMS_PLATE_UUID_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, 16, uuid);
  if (!parasite) return FALSE;
  gimp_item_parasite_attach (item, parasite, FALSE);
  gimp_parasite_free (parasite);
  return TRUE;
}

static void
initialize_attributes (GimpLayer *layer)
{
  gimp_item_set_visible (GIMP_ITEM (layer), TRUE, FALSE);
  gimp_layer_set_opacity (layer, 1.0, FALSE);
  gimp_layer_set_mode (layer, GIMP_LAYER_MODE_NORMAL, FALSE);
  gimp_layer_set_blend_space (layer, GIMP_LAYER_COLOR_SPACE_AUTO, FALSE);
  gimp_layer_set_composite_space (layer, GIMP_LAYER_COLOR_SPACE_AUTO, FALSE);
  gimp_layer_set_composite_mode (layer, GIMP_LAYER_COMPOSITE_AUTO, FALSE);
}

static gboolean
initialize_plane (GimpLayer *plane, guint role)
{
  GimpDrawable *drawable = GIMP_DRAWABLE (plane);
  const Babl *format = gimp_drawable_get_format (drawable);
  guint8 value = role == 0 ? 255 : role == 3 ? 0 : 128;
  GeglBuffer *pattern = gegl_buffer_new (GEGL_RECTANGLE (0, 0, 1, 1), format);
  if (!pattern) return FALSE;
  /* Same-format expansion preserves encoded scalar bytes; no color fill. */
  gegl_buffer_set (pattern, GEGL_RECTANGLE (0, 0, 1, 1), 0, format, &value, GEGL_AUTO_ROWSTRIDE);
  gegl_buffer_set_pattern (gimp_drawable_get_buffer (drawable), NULL, pattern, 0, 0);
  g_object_unref (pattern);
  gimp_drawable_update (drawable, 0, 0, -1, -1);
  return TRUE;
}

GimpImage *
glims_lab_layer_storage_create (GlimsEngine *engine, const GlimsLabLayerMap *map,
                                char **error)
{
  guint8 encoded[GLIMS_LAB_LAYER_MAP_MAX_SIZE];
  size_t length = 0;
  GlimsLabLayerStorage storage;
  if (!engine || !engine->gimp ||
      !glims_lab_layer_map_encode (map, encoded, sizeof encoded, &length) ||
      map->width > GIMP_MAX_IMAGE_SIZE || map->height > GIMP_MAX_IMAGE_SIZE)
    {
      glims_fail (error, NULL, "The Lab layer dimensions or identities are invalid.");
      return NULL;
    }
  GimpImage *image = gimp_create_image (engine->gimp, map->width, map->height,
                                       GIMP_GRAY, GIMP_PRECISION_U8_LINEAR, FALSE);
  if (!image)
    {
      glims_fail (error, NULL, "The Lab layer image could not be created.");
      return NULL;
    }
  gimp_image_undo_disable (image);
  const Babl *format = gimp_image_get_layer_format (image, FALSE);
  for (guint i = 0; i < map->count; i++)
    {
      GimpLayer *group = gimp_group_layer_new (image);
      if (!group) goto failed;
      gchar *name = g_strdup_printf ("Layer %u", i + 1);
      gimp_object_set_name (GIMP_OBJECT (group), name);
      g_free (name);
      if (!gimp_image_add_layer (image, group, NULL, i, FALSE))
        { g_object_unref (group); goto failed; }
      initialize_attributes (group);
      if (!attach_uuid (GIMP_ITEM (group), map->entries[i].group)) goto failed;
      for (guint role = 0; role < 4; role++)
        {
          static const gchar *names[] = { "Lightness", "a", "b", "Alpha" };
          GimpLayer *plane = gimp_layer_new (image, map->width, map->height, format,
                                            names[role], 1.0, GIMP_LAYER_MODE_NORMAL);
          if (!plane) goto failed;
          if (!gimp_image_add_layer (image, plane, group, role, FALSE))
            { g_object_unref (plane); goto failed; }
          initialize_attributes (plane);
          if (!attach_uuid (GIMP_ITEM (plane), role_uuid (&map->entries[i], role)) ||
              !initialize_plane (plane, role)) goto failed;
        }
    }
  GimpParasite *mapping = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, (guint32) length, encoded);
  if (!mapping) goto failed;
  gimp_image_parasite_attach (image, mapping, FALSE);
  gimp_parasite_free (mapping);
  if (glims_lab_layer_storage_read (image, &storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    goto failed;
  gimp_image_undo_enable (image);
  gimp_image_clean_all (image);
  return image;

failed:
  g_object_unref (image);
  glims_fail (error, NULL, "The Lab layer image could not preserve its carrier structure.");
  return NULL;
}
