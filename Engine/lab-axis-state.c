/* Metadata-only Lab axis state. Canonical roles and identities come from the
 * validated persisted map, never channel names or native container order. */
#include "engine-private.h"
#include "plate-storage.h"

#include <string.h>

#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpobject.h"

static gboolean
copy_axis_name (char         target[256],
                const gchar *name)
{
  if (! name)
    return TRUE; /* The staged field is already empty. */

  /* Validate even the suffix that will not fit in the display field. Invalid
   * native metadata must refuse, not disappear behind display truncation. */
  if (! g_utf8_validate (name, -1, NULL))
    return FALSE;

  size_t length = strlen (name);
  if (length > 255)
    {
      length = 255;
      while (length > 0 && ((guchar) name[length] & 0xC0) == 0x80)
        length--;
    }
  memcpy (target, name, length);
  target[length] = '\0';
  return TRUE;
}

GlimsStatus
glims_image_lab_axes (GlimsEngine  *engine,
                      GlimsImageID  id,
                      GlimsLabAxes *out)
{
  if (! out || out->struct_size < sizeof (*out))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  GlimsLabAxes result;
  memset (&result, 0, sizeof result);
  result.struct_size = out->struct_size;
  /* Clear only the known output, preserving capacity and any future tail.
   * Partial axis results stay private until every row has validated. */
  memcpy (out, &result, sizeof result);

  if (! engine)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  GlimsPlateStorage storage;
  if (! open->component_document || open->component_mode != GLIMS_PLATE_MODE_LAB ||
      ! glims_plate_storage_read_open (open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_LAB || storage.map.count != 3)
    return GLIMS_STATUS_UNSUPPORTED;

  switch (storage.map.storage)
    {
    case GLIMS_PLATE_STORAGE_U8:
      result.component = GLIMS_COLOR_COMPONENT_U8;
      break;
    case GLIMS_PLATE_STORAGE_U16:
      result.component = GLIMS_COLOR_COMPONENT_U16;
      break;
    case GLIMS_PLATE_STORAGE_FLOAT:
      result.component = GLIMS_COLOR_COMPONENT_FLOAT;
      break;
    default:
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* Borrowed from the native item tree; do not free or change this list. */
  GList *selected = gimp_image_get_selected_channels (open->image);
  static const guint32 roles[] = {
    GLIMS_LAB_AXIS_LIGHTNESS, GLIMS_LAB_AXIS_A, GLIMS_LAB_AXIS_B
  };
  for (guint i = 0; i < 3; i++)
    {
      GimpChannel *plane = storage.planes[i];
      if (! plane)
        return GLIMS_STATUS_UNSUPPORTED;

      result.axes[i].id = gimp_item_get_id (GIMP_ITEM (plane));
      if (result.axes[i].id <= 0 ||
          ! copy_axis_name (result.axes[i].name,
                            gimp_object_get_name (GIMP_OBJECT (plane))))
        return GLIMS_STATUS_UNSUPPORTED;

      result.axes[i].role = roles[i];
      result.axes[i].selected = g_list_find (selected, plane) ? 1u : 0u;
      memcpy (result.axes[i].uuid, storage.map.entries[i].uuid,
              sizeof result.axes[i].uuid);
    }

  result.count = 3;
  memcpy (out, &result, sizeof result);
  return GLIMS_STATUS_OK;
}
