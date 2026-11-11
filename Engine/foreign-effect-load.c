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

static GFileIOStream *
private_spool (GError **error)
{
  g_autofree gchar *directory = g_dir_make_tmp ("glims-xcf-gzip-XXXXXX", error);
  if (!directory) return NULL;
  struct stat status;
  if (g_lstat (directory, &status) != 0 || !S_ISDIR (status.st_mode) ||
      status.st_uid != geteuid () || (status.st_mode & 077) != 0) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "Cannot verify private gzip staging");
    g_rmdir (directory);
    return NULL;
  }

  g_autofree gchar *path = g_build_filename (directory, "metadata.xcf", NULL);
  g_autoptr(GFile) temporary = g_file_new_for_path (path);
  g_autoptr(GFileIOStream) spool = g_file_create_readwrite (temporary, G_FILE_CREATE_PRIVATE, NULL, error);
  if (!spool) {
    g_rmdir (directory);
    return NULL;
  }
  /* Unlink before any bytes are written. The private descriptor is the
   * only way either consumer can reach the finished spool. */
  gboolean unlinked = g_file_delete (temporary, NULL, error);
  gboolean removed = g_rmdir (directory) == 0;
  if (!unlinked) return NULL;
  if (!removed) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not remove private gzip staging directory");
    return NULL;
  }
  return g_steal_pointer (&spool);
}

static gboolean
stage_gzip (int fd, GFileInfo *before, GFileIOStream **staged, GError **error)
{
  if (!source_fd_matches (fd, before)) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Cannot verify the original gzip source");
    return FALSE;
  }

  g_autoptr(GFileIOStream) spool = private_spool (error);
  if (!spool) return FALSE;
  g_autoptr(GInputStream) input = g_unix_input_stream_new (fd, FALSE);
  GOutputStream *output = g_io_stream_get_output_stream (G_IO_STREAM (spool));
  gboolean is_xcf = FALSE;
  if (!glims_xcf_gzip_decode_xcf (input, output, GZIP_RECOVERY_LIMIT, GZIP_RECOVERY_LIMIT, &is_xcf, error))
    return FALSE;
  if (!is_xcf) return TRUE;
  if (!source_fd_matches (fd, before)) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The gzip source changed during recovery");
    return FALSE;
  }
  if (!g_output_stream_flush (output, NULL, error)) return FALSE;
  GInputStream *decoded = g_io_stream_get_input_stream (G_IO_STREAM (spool));
  if (!G_IS_SEEKABLE (decoded) || !g_seekable_can_seek (G_SEEKABLE (decoded))) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Cannot seek the private XCF spool");
    return FALSE;
  }
  /* Core's magic reader assumes a complete, NUL-terminated XCF header. */
  guint8 header[14];
  gsize count = 0;
  if (!g_seekable_seek (G_SEEKABLE (decoded), 0, G_SEEK_SET, NULL, error) ||
      !g_input_stream_read_all (decoded, header, sizeof header, &count, NULL, error))
    return FALSE;
  if (count != sizeof header || header[sizeof header - 1] != 0) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The decoded XCF header is incomplete or invalid");
    return FALSE;
  }
  if (!g_seekable_seek (G_SEEKABLE (decoded), 0, G_SEEK_SET, NULL, error)) return FALSE;
  *staged = g_steal_pointer (&spool);
  return TRUE;
}

gboolean
glims_foreign_gzip_spool (GFile *file, GFileInfo *before, GFileIOStream **staged,
                         gboolean *gzip_source, GError **error)
{
  *staged = NULL;
  *gzip_source = FALSE;
  g_autofree gchar *path = g_file_get_path (file);
  if (!path) return TRUE;
  int fd = g_open (path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
  if (fd < 0) return TRUE; /* The original loader owns ordinary file errors. */

  struct stat status;
  guint8 prefix[2];
  ssize_t count = 0;
  if (fstat (fd, &status) == 0 && S_ISREG (status.st_mode)) {
    do
      count = pread (fd, prefix, sizeof prefix, 0);
    while (count < 0 && errno == EINTR);
  }
  gboolean ok = TRUE;
  if (count == (ssize_t) sizeof prefix && prefix[0] == 0x1f && prefix[1] == 0x8b) {
    *gzip_source = TRUE;
    ok = stage_gzip (fd, before, staged, error);
  }
  close (fd);
  return ok;
}

static GlimsXcfEffectFields *
read_spooled_fields (GFileIOStream *spool, GError **error)
{
  GInputStream *input = g_io_stream_get_input_stream (G_IO_STREAM (spool));
  GSeekable *seekable = G_SEEKABLE (input);
  if (!g_seekable_seek (seekable, 0, G_SEEK_END, NULL, error)) return NULL;
  goffset size = g_seekable_tell (seekable);
  if (size < 0 || (guint64) size > GZIP_RECOVERY_LIMIT) {
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Cannot verify the decoded XCF spool");
    return NULL;
  }
  return glims_xcf_effect_fields_read_stream (input, (guint64) size, NULL, error);
}

static gboolean
source_still_current (GFile *file, GFileInfo *before)
{
  g_autoptr(GFileInfo) after = g_file_query_info (file, GLIMS_FOREIGN_SOURCE_ATTRIBUTES,
                                                G_FILE_QUERY_INFO_NONE, NULL, NULL);
  return same_file (before, after);
}

GlimsStatus
glims_foreign_effects_load (GimpImage *image, GFile *file,
                            const gchar *mime_type, GFileInfo *before,
                            GFileIOStream *spool, gboolean gzip_source, char **error)
{
  if (gimp_image_parasite_find (image, "glims-effect-state-v1") ||
      !image_has_effects (image)) {
    if (spool && !source_still_current (file, before))
      return refuse (error, "The file changed while it was opening. Try opening it again.");
    return GLIMS_STATUS_OK;
  }

  gboolean xcf = g_strcmp0 (mime_type, "image/x-xcf") == 0;
  gboolean compressed = g_strcmp0 (mime_type, "application/x-gzip") == 0 ||
                        g_strcmp0 (mime_type, "application/x-bzip") == 0 ||
                        g_strcmp0 (mime_type, "application/x-xz") == 0;
  if (!xcf && !compressed) return GLIMS_STATUS_OK;
  if (compressed || (gzip_source && !spool))
    return refuse (error, "Use an uncompressed XCF copy to preserve this file's effect settings.");

  GError *read_error = NULL;
  GlimsXcfEffectFields *fields = spool ? read_spooled_fields (spool, &read_error)
      : glims_xcf_effect_fields_read (file, NULL, &read_error);
  if (!fields)
    {
      gboolean over_budget = g_error_matches (read_error, GLIMS_XCF_EFFECT_FIELDS_ERROR,
                                              GLIMS_XCF_EFFECT_FIELDS_BUDGET);
      g_debug ("Cannot read foreign effect metadata: %s", read_error ? read_error->message : "no result");
      g_clear_error (&read_error);
      return refuse (error, over_budget ? "The file's effect metadata exceeds the supported limit."
                                        : "This file uses effect settings Glims cannot preserve yet.");
    }

  GlimsStatus status = source_still_current (file, before)
      ? glims_foreign_effect_fields_restore (image, fields, error)
      : refuse (error, "The file changed while it was opening. Try opening it again.");
  glims_xcf_effect_fields_free (fields);
  return status;
}
