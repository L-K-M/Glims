/* Preserve foreign XCF effect fields before the loaded image is published.
 * Glims-authored supplements retain their existing validated load path.
 * The independent format reader never enters GIMP or reads pixel tiles. */
#include "foreign-effect-load.h"
#include "foreign-effect-state.h"
#include "xcf-effect-fields.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "core/gimplayer.h"
#include "core/gimplist.h"
#include <string.h>

static GlimsStatus
refuse (char **error, const gchar *message)
{
  if (error) *error = g_strdup (message);
  return GLIMS_STATUS_UNSUPPORTED;
}

static gboolean
drawable_has_effects (GimpDrawable *drawable)
{
  GimpContainer *filters = gimp_drawable_get_filters (drawable);
  for (GList *node = GIMP_LIST (filters)->queue->head; node; node = node->next)
    if (GIMP_IS_DRAWABLE_FILTER (node->data) &&
        !gimp_drawable_filter_get_temporary (node->data))
      return TRUE;
  return FALSE;
}

static gboolean
image_has_effects (GimpImage *image)
{
  GList *items = g_list_concat (gimp_image_get_layer_list (image),
                               gimp_image_get_channel_list (image));
  gboolean found = FALSE;
  for (GList *node = items; node && !found; node = node->next)
    {
      found = drawable_has_effects (GIMP_DRAWABLE (node->data));
      if (!found && GIMP_IS_LAYER (node->data))
        {
          GimpLayerMask *mask = gimp_layer_get_mask (node->data);
          if (mask) found = drawable_has_effects (GIMP_DRAWABLE (mask));
        }
    }
  g_list_free (items);
  return found;
}

static gboolean
same_file (GFileInfo *before, GFileInfo *after)
{
  if (!before || !after ||
      !g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_STANDARD_SIZE) ||
      !g_file_info_has_attribute (after, G_FILE_ATTRIBUTE_STANDARD_SIZE) ||
      g_file_info_get_size (before) != g_file_info_get_size (after))
    return FALSE;

  const gchar *old_tag = g_file_info_get_attribute_string (before, G_FILE_ATTRIBUTE_ETAG_VALUE);
  const gchar *new_tag = g_file_info_get_attribute_string (after, G_FILE_ATTRIBUTE_ETAG_VALUE);
  if (!old_tag || !new_tag || strcmp (old_tag, new_tag)) return FALSE;

  if (g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_UNIX_INODE) !=
      g_file_info_has_attribute (after, G_FILE_ATTRIBUTE_UNIX_INODE) ||
      g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_UNIX_DEVICE) !=
      g_file_info_has_attribute (after, G_FILE_ATTRIBUTE_UNIX_DEVICE))
    return FALSE;
  if (g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_UNIX_INODE) &&
      g_file_info_get_attribute_uint64 (before, G_FILE_ATTRIBUTE_UNIX_INODE) !=
      g_file_info_get_attribute_uint64 (after, G_FILE_ATTRIBUTE_UNIX_INODE))
    return FALSE;
  if (g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_UNIX_DEVICE) &&
      g_file_info_get_attribute_uint32 (before, G_FILE_ATTRIBUTE_UNIX_DEVICE) !=
      g_file_info_get_attribute_uint32 (after, G_FILE_ATTRIBUTE_UNIX_DEVICE))
    return FALSE;
  return TRUE;
}

GlimsStatus
glims_foreign_effects_load (GimpImage *image, GFile *file,
                            const gchar *mime_type, GFileInfo *before,
                            char **error)
{
  if (gimp_image_parasite_find (image, "glims-effect-state-v1") ||
      !image_has_effects (image))
    return GLIMS_STATUS_OK;

  gboolean xcf = g_strcmp0 (mime_type, "image/x-xcf") == 0;
  gboolean compressed = g_strcmp0 (mime_type, "application/x-gzip") == 0 ||
                        g_strcmp0 (mime_type, "application/x-bzip") == 0 ||
                        g_strcmp0 (mime_type, "application/x-xz") == 0;
  if (!xcf && !compressed) return GLIMS_STATUS_OK;
  if (compressed)
    return refuse (error, "Use an uncompressed XCF copy to preserve this file's effect settings.");

  GError *read_error = NULL;
  GlimsXcfEffectFields *fields = glims_xcf_effect_fields_read (file, NULL, &read_error);
  if (!fields)
    {
      gboolean over_budget = g_error_matches (read_error, GLIMS_XCF_EFFECT_FIELDS_ERROR,
                                              GLIMS_XCF_EFFECT_FIELDS_BUDGET);
      g_debug ("Cannot read foreign effect metadata: %s", read_error ? read_error->message : "no result");
      g_clear_error (&read_error);
      return refuse (error, over_budget ? "The file's effect metadata exceeds the supported limit."
                                        : "This file uses effect settings Glims cannot preserve yet.");
    }

  GFileInfo *after = g_file_query_info (file, GLIMS_FOREIGN_SOURCE_ATTRIBUTES,
                                       G_FILE_QUERY_INFO_NONE, NULL, NULL);
  gboolean stable = same_file (before, after);
  g_clear_object (&after);
  GlimsStatus status = stable ? glims_foreign_effect_fields_restore (image, fields, error)
                              : refuse (error, "The file changed while it was opening. Try opening it again.");
  glims_xcf_effect_fields_free (fields);
  return status;
}
