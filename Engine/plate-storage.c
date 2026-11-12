#include "plate-storage.h"
#include <string.h>
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-quick-mask.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"

static GimpPrecision
storage_precision (uint32_t storage)
{
  switch (storage)
    {
    case GLIMS_PLATE_STORAGE_U8: return GIMP_PRECISION_U8_LINEAR;
    case GLIMS_PLATE_STORAGE_U16: return GIMP_PRECISION_U16_LINEAR;
    case GLIMS_PLATE_STORAGE_FLOAT: return GIMP_PRECISION_FLOAT_LINEAR;
    default: g_assert_not_reached ();
    }
}

static gboolean
persistent_data (const GimpParasite *parasite, gconstpointer *bytes, guint32 *size)
{
  if (!parasite || !gimp_parasite_is_persistent (parasite)) return FALSE;
  *bytes = gimp_parasite_get_data (parasite, size);
  return *bytes != NULL;
}

GlimsPlateStorageState
glims_plate_storage_read (GimpImage *image, GlimsPlateStorage *out)
{
  GlimsPlateStorage result = {0};
  GlimsPlateStorageState state = GLIMS_PLATE_STORAGE_INVALID;
  const GimpParasite *parasite;
  gconstpointer bytes = NULL;
  guint32 size = 0;
  GList *channels = NULL;

  if (!out) return GLIMS_PLATE_STORAGE_INVALID;
  memset (out, 0, sizeof *out);
  if (!image) return GLIMS_PLATE_STORAGE_INVALID;
  channels = gimp_image_get_channel_list (image);
  parasite = gimp_image_parasite_find (image, GLIMS_PLATE_MAP_PARASITE);
  if (!parasite)
    {
      state = GLIMS_PLATE_STORAGE_NONE;
      /* Stripped image metadata must not silently turn ink planes into
       * ordinary alpha channels on the next open. */
      for (GList *iter = channels; iter; iter = iter->next)
        if (gimp_item_parasite_find (GIMP_ITEM (iter->data), GLIMS_PLATE_UUID_PARASITE) ||
            gimp_item_parasite_find (GIMP_ITEM (iter->data), GLIMS_PLATE_VISIBLE_PARASITE))
          { state = GLIMS_PLATE_STORAGE_INVALID; break; }
      goto done;
    }
  if (!persistent_data (parasite, &bytes, &size) ||
      !glims_plate_map_decode (bytes, size, &result.map) ||
      gimp_image_get_base_type (image) != GIMP_GRAY ||
      gimp_image_get_width (image) != result.map.width ||
      gimp_image_get_height (image) != result.map.height ||
      gimp_image_get_precision (image) != storage_precision (result.map.storage) ||
      gimp_container_get_n_children (gimp_image_get_layers (image)) != 0 ||
      gimp_image_get_quick_mask_state (image) ||
      g_list_length (channels) != result.map.count)
    goto done;

  for (GList *iter = channels; iter; iter = iter->next)
    {
      GimpChannel *channel = iter->data;
      GimpItem *item = GIMP_ITEM (channel);
      gint x, y;
      guint index;
      parasite = gimp_item_parasite_find (item, GLIMS_PLATE_UUID_PARASITE);
      gimp_item_get_offset (item, &x, &y);
      if (!persistent_data (parasite, &bytes, &size) || size != 16 ||
          !gimp_item_is_attached (item) || gimp_item_get_image (item) != image ||
          x || y || gimp_item_get_width (item) != result.map.width ||
          gimp_item_get_height (item) != result.map.height ||
          gimp_drawable_get_format (GIMP_DRAWABLE (channel)) != gimp_image_get_channel_format (image))
        goto done;
      for (index = 0; index < result.map.count; index++)
        if (!memcmp (bytes, result.map.entries[index].uuid, 16)) break;
      if (index == result.map.count || result.planes[index]) goto done;
      result.planes[index] = channel;
      result.visible[index] = TRUE;
      parasite = gimp_item_parasite_find (item, GLIMS_PLATE_VISIBLE_PARASITE);
      if (parasite)
        {
          if (!persistent_data (parasite, &bytes, &size) || size != 1 ||
              *(const guint8 *) bytes > 1) goto done;
          result.visible[index] = *(const guint8 *) bytes != 0;
        }
    }
  for (guint i = 0; i < result.map.count; i++)
    if (!result.planes[i]) goto done;
  memcpy (out, &result, sizeof result);
  state = GLIMS_PLATE_STORAGE_VALID;

done:
  g_list_free (channels);
  return state;
}

GimpImage *
glims_plate_storage_create (GlimsEngine *engine, const GlimsPlateMap *map, char **error)
{
  uint8_t encoded[GLIMS_PLATE_MAP_MAX_SIZE];
  size_t length = 0;
  GimpImage *image;
  GlimsPlateStorage storage;
  if (!engine || !glims_plate_map_encode (map, encoded, sizeof encoded, &length) ||
      map->width > GIMP_MAX_IMAGE_SIZE || map->height > GIMP_MAX_IMAGE_SIZE)
    { glims_fail (error, NULL, "The component image dimensions or ink definitions are invalid."); return NULL; }
  image = gimp_create_image (engine->gimp, map->width, map->height, GIMP_GRAY,
                             storage_precision (map->storage), FALSE);
  if (!image)
    { glims_fail (error, NULL, "The component image could not be created."); return NULL; }
  gimp_image_undo_disable (image);
  for (guint i = 0; i < map->count; i++)
    {
      gchar *name = g_strdup_printf ("Channel %u", i + 1);
      GeglColor *color = gegl_color_new ("black");
      GimpChannel *channel = gimp_channel_new (image, map->width, map->height, name, color);
      g_object_unref (color);
      g_free (name);
      if (!channel) goto failed;
      gimp_item_set_visible (GIMP_ITEM (channel), FALSE, FALSE);
      GimpParasite *identity = gimp_parasite_new (GLIMS_PLATE_UUID_PARASITE,
        GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, 16, map->entries[i].uuid);
      gimp_item_parasite_attach (GIMP_ITEM (channel), identity, FALSE);
      gimp_parasite_free (identity);
      if (!gimp_image_add_channel (image, channel, NULL, i, FALSE))
        { g_object_unref (channel); goto failed; }
      gimp_channel_all (channel, FALSE);
    }
  GimpParasite *mapping = gimp_parasite_new (GLIMS_PLATE_MAP_PARASITE,
    GIMP_PARASITE_PERSISTENT | GIMP_PARASITE_UNDOABLE, length, encoded);
  gimp_image_parasite_attach (image, mapping, FALSE);
  gimp_parasite_free (mapping);
  if (glims_plate_storage_read (image, &storage) != GLIMS_PLATE_STORAGE_VALID) goto failed;
  GList *selected = g_list_prepend (NULL, storage.planes[0]);
  gimp_image_set_selected_channels (image, selected);
  g_list_free (selected);
  gimp_image_undo_enable (image);
  gimp_image_clean_all (image);
  return image;

failed:
  g_object_unref (image);
  glims_fail (error, NULL, "The component image could not preserve its plane identities.");
  return NULL;
}
