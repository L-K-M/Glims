/* Preserve the upstream PSD loader's opaque Duotone color-mode data when a
 * grayscale image is later saved as XCF. This does not interpret inks or
 * promise a color preview. Adobe documents the PSD block as opaque. */
#include "engine-private.h"
#include <stdlib.h>
#include <string.h>
#include "core/gimpimage.h"

#define DUOTONE_PARASITE "psd-duotone-data"
#define DUOTONE_MAX_BYTES (16u * 1024u * 1024u)

GlimsStatus
glims_duotone_preserve_import (GimpImage *image, char **error)
{
  if (error) *error = NULL;
  if (!image) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (gimp_image_get_base_type (image) != GIMP_GRAY) return GLIMS_STATUS_OK;
  const GimpParasite *source = gimp_image_parasite_find (image, DUOTONE_PARASITE);
  if (!source || gimp_parasite_is_persistent (source)) return GLIMS_STATUS_OK;
  guint32 size = 0;
  const void *bytes = gimp_parasite_get_data (source, &size);
  if (!bytes || !size || size > DUOTONE_MAX_BYTES)
    {
      if (error) *error = strdup ("The imported Duotone data is empty or too large to preserve safely.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  /* Replacing the private in-memory tag before adoption does not push Undo or
   * change its bytes. Persistent tags survive the native XCF writer. */
  GimpParasite *copy = gimp_parasite_new (DUOTONE_PARASITE,
      gimp_parasite_get_flags (source) | GIMP_PARASITE_PERSISTENT, size, bytes);
  if (!copy) return GLIMS_STATUS_FAILED;
  gimp_image_parasite_attach (image, copy, FALSE);
  const GimpParasite *saved = gimp_image_parasite_find (image, DUOTONE_PARASITE);
  guint32 saved_size = 0, expected_size = 0;
  const void *saved_bytes = saved ? gimp_parasite_get_data (saved, &saved_size) : NULL;
  const void *expected_bytes = gimp_parasite_get_data (copy, &expected_size);
  gboolean valid = saved && gimp_parasite_is_persistent (saved) && saved_bytes && expected_bytes &&
                   saved_size == expected_size && !memcmp (saved_bytes, expected_bytes, expected_size);
  gimp_parasite_free (copy);
  if (!valid)
    {
      if (error) *error = strdup ("The imported Duotone data could not be preserved.");
      return GLIMS_STATUS_FAILED;
    }
  return GLIMS_STATUS_OK;
}
