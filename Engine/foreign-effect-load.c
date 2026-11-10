/* Preserve foreign XCF effect fields before the loaded image is published.
 * Glims-authored supplements retain their existing validated load path.
 * The independent format reader never enters GIMP or reads pixel tiles. */
#include "foreign-effect-load.h"
#include "foreign-effect-state.h"
#include "xcf-effect-fields.h"
#include "xcf-gzip.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-filters.h"
#include "core/gimpdrawablefilter.h"
#include "core/gimpimage.h"
#include "core/gimplayer.h"
#include "core/gimplist.h"
#include <errno.h>
#include <fcntl.h>
#include <gio/gunixinputstream.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define GZIP_RECOVERY_LIMIT (G_GUINT64_CONSTANT (4) * 1024 * 1024 * 1024)

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

static gboolean
source_fd_matches (int fd, GFileInfo *before)
{
  struct stat file;
  return before && fstat (fd, &file) == 0 && S_ISREG (file.st_mode) && file.st_size >= 0 &&
      g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_STANDARD_SIZE) &&
      g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_UNIX_DEVICE) &&
      g_file_info_has_attribute (before, G_FILE_ATTRIBUTE_UNIX_INODE) &&
      (guint64) file.st_size == (guint64) g_file_info_get_size (before) &&
      (guint32) file.st_dev == g_file_info_get_attribute_uint32 (before, G_FILE_ATTRIBUTE_UNIX_DEVICE) &&
      (guint64) file.st_ino == g_file_info_get_attribute_uint64 (before, G_FILE_ATTRIBUTE_UNIX_INODE);
}

static GlimsXcfEffectFields *
read_gzip_fields (int fd, GFileInfo *before, GError **error)
{
  if (!source_fd_matches (fd, before)) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Cannot verify the original gzip source");
    return NULL;
  }
  if ((guint64) g_file_info_get_size (before) > GZIP_RECOVERY_LIMIT) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE, "Gzip input limit exceeded");
    return NULL;
  }

  g_autofree gchar *directory = g_dir_make_tmp ("glims-xcf-gzip-XXXXXX", error);
  if (!directory) return NULL;
  struct stat directory_stat;
  if (g_lstat (directory, &directory_stat) != 0 || !S_ISDIR (directory_stat.st_mode) ||
      directory_stat.st_uid != geteuid () || (directory_stat.st_mode & 077) != 0) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "Cannot verify private gzip staging");
    g_rmdir (directory);
    return NULL;
  }

  g_autofree gchar *path = g_build_filename (directory, "metadata.xcf", NULL);
  g_autoptr(GFile) temporary = g_file_new_for_path (path);
  g_autoptr(GFileOutputStream) output = g_file_create (temporary, G_FILE_CREATE_PRIVATE, NULL, error);
  GlimsXcfEffectFields *fields = NULL;
  if (output) {
    g_autoptr(GInputStream) input = g_unix_input_stream_new (fd, FALSE);
    gboolean decoded = glims_xcf_gzip_decode (input, G_OUTPUT_STREAM (output),
        GZIP_RECOVERY_LIMIT, GZIP_RECOVERY_LIMIT, error);
    g_autoptr(GError) close_error = NULL;
    gboolean closed = g_output_stream_close (G_OUTPUT_STREAM (output), NULL, &close_error);
    if (decoded && !closed) g_propagate_error (error, g_steal_pointer (&close_error));
    if (decoded && closed) {
      if (source_fd_matches (fd, before))
        fields = glims_xcf_effect_fields_read (temporary, NULL, error);
      else
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The gzip source changed during recovery");
    }
  }

  /* Only remove the file if this call created it inside the private
   * directory. Try both removals even when decode or parsing failed. */
  gboolean deleted = !output || g_file_delete (temporary, NULL, NULL);
  gboolean removed = g_rmdir (directory) == 0;
  if (!deleted || !removed) {
    g_debug ("Could not remove private gzip staging");
    if (fields) {
      glims_xcf_effect_fields_free (fields);
      fields = NULL;
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not remove private gzip staging");
    }
  }
  return fields;
}

static GlimsXcfEffectFields *
read_foreign_fields (GFile *file, GFileInfo *before, GError **error)
{
  g_autofree gchar *path = g_file_get_path (file);
  if (!path) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "XCF metadata requires a local input file");
    return NULL;
  }
  int fd = g_open (path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
  if (fd < 0) {
    int saved = errno;
    g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved), "Could not inspect XCF source: %s", g_strerror (saved));
    return NULL;
  }
  GlimsXcfEffectFields *fields = NULL;
  struct stat status;
  if (fstat (fd, &status) != 0 || !S_ISREG (status.st_mode)) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "XCF metadata requires a regular source");
    goto done;
  }
  guint8 prefix[2];
  gsize length = 0;
  while (length < sizeof prefix) {
    ssize_t count = pread (fd, prefix + length, sizeof prefix - length, (off_t) length);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) {
      int saved = errno;
      g_set_error (error, G_IO_ERROR, g_io_error_from_errno (saved), "Could not read XCF source magic: %s", g_strerror (saved));
      goto done;
    }
    if (!count) break;
    length += (gsize) count;
  }
  if (length == sizeof prefix && prefix[0] == 0x1f && prefix[1] == 0x8b)
    fields = read_gzip_fields (fd, before, error);
  else
    fields = glims_xcf_effect_fields_read (file, NULL, error);
done:
  close (fd);
  return fields;
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
  GlimsXcfEffectFields *fields = read_foreign_fields (file, before, &read_error);
  if (!fields)
    {
      gboolean over_budget = g_error_matches (read_error, GLIMS_XCF_EFFECT_FIELDS_ERROR,
                                              GLIMS_XCF_EFFECT_FIELDS_BUDGET);
      gboolean gzip_budget = g_error_matches (read_error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE);
      g_debug ("Cannot read foreign effect metadata: %s", read_error ? read_error->message : "no result");
      g_clear_error (&read_error);
      if (gzip_budget) return refuse (error, "Gzip effect recovery exceeds the 4 GiB input or decoded limit.");
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
