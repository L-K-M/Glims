/*
 * Component documents: creation of Multichannel images backed by the
 * validated plate storage contract. Runs on the engine thread; adoption
 * publishes the document only after complete native storage validation.
 */
#include "component-document.h"
#include "plate-storage.h"

#include <string.h>

#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"

/* Default inks for the first channels, in order. A single-channel
 * document is grayscale-like and gets Black instead of Cyan. */
static const struct
{
  const char *name;
  double      rgb[3];
} default_inks[] =
{
  { "Cyan",    { 0.0, 1.0, 1.0 } },
  { "Magenta", { 1.0, 0.0, 1.0 } },
  { "Yellow",  { 1.0, 1.0, 0.0 } },
  { "Black",   { 0.0, 0.0, 0.0 } },
};

#define GLIMS_DEFAULT_INK_COUNT (sizeof default_inks / sizeof default_inks[0])

static gboolean
component_storage (uint32_t component,
                   uint32_t *storage)
{
  switch (component)
    {
    case GLIMS_COLOR_COMPONENT_U8:
      *storage = GLIMS_PLATE_STORAGE_U8;
      return TRUE;
    case GLIMS_COLOR_COMPONENT_U16:
      *storage = GLIMS_PLATE_STORAGE_U16;
      return TRUE;
    case GLIMS_COLOR_COMPONENT_FLOAT:
      *storage = GLIMS_PLATE_STORAGE_FLOAT;
      return TRUE;
    default:
      return FALSE;
    }
}

/* Parses the canonical 8-4-4-4-12 hexadecimal form that
 * g_uuid_string_random returns into 16 opaque identity bytes.
 * Names are never used as identity. */
static gboolean
plate_uuid_bytes (const char *text,
                  uint8_t     bytes[16])
{
  guint nibbles = 0;
  gint  digit;

  if (! text)
    return FALSE;

  for (const char *p = text; *p; p++)
    {
      if (*p == '-')
        {
          /* Hyphens close the 8-, 4-, 4- and 4-nibble groups. */
          if (nibbles != 8 && nibbles != 12 && nibbles != 16 && nibbles != 20)
            return FALSE;
          continue;
        }
      digit = g_ascii_xdigit_value (*p);
      if (digit < 0 || nibbles >= 32)
        return FALSE;
      if (nibbles & 1)
        bytes[nibbles / 2] |= (uint8_t) digit;
      else
        bytes[nibbles / 2] = (uint8_t) (digit << 4);
      nibbles++;
    }

  return nibbles == 32;
}

static char *
plane_display_name (uint32_t index,
                    uint32_t channel_count)
{
  if (channel_count == 1)
    return g_strdup ("Black");
  if (index < GLIMS_DEFAULT_INK_COUNT)
    return g_strdup (default_inks[index].name);
  return g_strdup_printf ("Ink %u", index + 1);
}

static GlimsStatus
new_component_image (GlimsEngine *engine,
                              int32_t      width,
                              int32_t      height,
                              uint32_t     component,
                              uint32_t     channel_count,
                              uint32_t     mode,
                              const guint8 *icc, gsize icc_size,
                              GlimsImageID *result,
                              char       **error)
{
  GlimsPlateMap      map = { 0 };
  GlimsPlateStorage  storage;
  GimpImage         *image;
  GError            *gerror = NULL;
  gboolean           named;
  GlimsStatus        status;

  if (result)
    *result = 0;
  if (error)
    *error = NULL;

  if (! engine || ! result ||
      width < 1 || height < 1 ||
      width > GIMP_MAX_IMAGE_SIZE || height > GIMP_MAX_IMAGE_SIZE ||
      channel_count < 1 || channel_count > GLIMS_PLATE_LIMIT ||
      ! component_storage (component, &map.storage))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  /* Creating native storage and renaming items must not run inside a
   * plug-in call's nested state. Checked before any allocation. */
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  map.width    = (uint32_t) width;
  map.height   = (uint32_t) height;
  map.count    = channel_count;
  map.mode     = mode;
  map.encoding = mode == GLIMS_PLATE_MODE_LAB ? GLIMS_PLATE_ENCODING_LAB_D50
                                            : GLIMS_PLATE_ENCODING_INTENSITY;

  for (uint32_t i = 0; i < channel_count; i++)
    {
      gchar *uuid = g_uuid_string_random ();
      gboolean parsed = plate_uuid_bytes (uuid, map.entries[i].uuid);
      g_free (uuid);
      if (! parsed)
        return glims_fail (error, NULL,
                           "A component identity could not be generated.");

      if (mode != GLIMS_PLATE_MODE_LAB && channel_count > 1 && i < GLIMS_DEFAULT_INK_COUNT)
        memcpy (map.entries[i].ink_rgb, default_inks[i].rgb,
                sizeof map.entries[i].ink_rgb);
      /* Single-channel documents and channels past the defaults are
       * Black (0,0,0); the zeroed map already holds that. */
    }

  /* The encoded parasite and the native storage validate the map again;
   * validating here keeps a malformed map from reaching the engine. */
  if (! glims_plate_map_validate (&map))
    return glims_fail (error, NULL,
                       "The component image definition is invalid.");

  image = glims_plate_storage_create_profiled (engine, &map, icc, icc_size, error);
  if (! image)
    return GLIMS_STATUS_FAILED;

  /* Display names are applied through the native item rename with the
   * undo stack frozen so creation leaves no Undo entries; the rename's
   * dirty marks are cleared before adoption. */
  gimp_image_undo_disable (image);
  named = glims_plate_storage_read (image, &storage) == GLIMS_PLATE_STORAGE_VALID;
  for (uint32_t i = 0; named && i < channel_count; i++)
    {
      const char *lab_names[] = { "Lightness", "a", "b" };
      gchar *name = mode == GLIMS_PLATE_MODE_LAB ? g_strdup (lab_names[i])
                                               : plane_display_name (i, channel_count);
      if (! gimp_item_rename (GIMP_ITEM (storage.planes[i]), name, &gerror))
        named = FALSE;
      g_free (name);
    }
  gimp_image_undo_enable (image);
  gimp_image_clean_all (image);

  if (! named)
    {
      g_object_unref (image);
      return glims_fail (error, gerror,
                         "The component planes could not be named.");
    }

  /* glims_adopt_image consumes the image's reference only on success. */
  status = glims_adopt_image (engine, image, result);
  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (image);
      if (result)
        *result = 0;
      if (error && ! *error)
        *error = strdup ("The component image could not be registered "
                         "with the engine.");
    }

  return status;
}

GlimsStatus
glims_image_new_multichannel (GlimsEngine *engine, int32_t width, int32_t height,
                              uint32_t component, uint32_t channel_count,
                              GlimsImageID *result, char **error)
{
  return new_component_image (engine, width, height, component, channel_count,
                               GLIMS_PLATE_MODE_MULTICHANNEL, NULL, 0, result, error);
}

GlimsStatus
glims_image_new_cmyk (GlimsEngine *engine, int32_t width, int32_t height,
                      uint32_t component, const guint8 *icc, gsize size,
                      GlimsImageID *result, char **error)
{
  return new_component_image (engine, width, height, component, 4,
                               GLIMS_PLATE_MODE_CMYK, icc, size, result, error);
}

GlimsStatus
glims_image_new_lab (GlimsEngine *engine, int32_t width, int32_t height,
                     uint32_t component, GlimsImageID *result, char **error)
{
  return new_component_image (engine, width, height, component, 3,
                               GLIMS_PLATE_MODE_LAB, NULL, 0, result, error);
}
