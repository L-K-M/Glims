/* Serialize privately before replacing the original file. The final local
 * rename is the commit point; no live name or catalog identity changes first. */
#include "resource-rename.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpbrushpipe.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpobject.h"
#include "core/gimppattern.h"
#include "core/gimptempbuf.h"
#include "babl/babl.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
#include <copyfile.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

static GlimsStatus refusal (char **error, GlimsStatus status, const char *text)
{
  if (error) *error = strdup (text);
  return status;
}

/* Copy only security/extended metadata, never payload or timestamps. GIO's
 * local metadata query may over-return read-only attributes such as size. */
static gboolean
preserve_metadata (GFile *original, GFile *staged, GError **error)
{
#ifdef __APPLE__
  gchar *from = g_file_get_path (original), *to = g_file_get_path (staged);
  int input = -1, output = -1, saved_error = 0;
  struct stat before, temporary;
  if (!from || !to) { saved_error = EINVAL; goto done; }
  input = open (from, O_RDONLY | O_NOFOLLOW);
  if (input < 0) { saved_error = errno; goto done; }
  output = open (to, O_RDWR | O_NOFOLLOW);
  if (output < 0) { saved_error = errno; goto done; }
  if (fstat (input, &before) || fstat (output, &temporary)) { saved_error = errno; goto done; }
  if (!S_ISREG (before.st_mode) || !S_ISREG (temporary.st_mode)) { saved_error = EINVAL; goto done; }
  if ((before.st_uid != temporary.st_uid || before.st_gid != temporary.st_gid) &&
      fchown (output, before.st_uid, before.st_gid)) { saved_error = errno; goto done; }
  if (fchmod (output, before.st_mode & 07777) ||
      fcopyfile (input, output, NULL, COPYFILE_ACL | COPYFILE_XATTR)) { saved_error = errno; goto done; }
done:
  if (input >= 0 && close (input) < 0 && !saved_error) saved_error = errno;
  if (output >= 0 && close (output) < 0 && !saved_error) saved_error = errno;
  g_free (from); g_free (to);
  if (saved_error) {
    g_set_error_literal (error, G_FILE_ERROR, g_file_error_from_errno (saved_error), g_strerror (saved_error));
    return FALSE;
  }
  return TRUE;
#else
  (void) original; (void) staged;
  g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Resource metadata preservation requires macOS.");
  return FALSE;
#endif
}

GlimsStatus
glims_resource_rename_checked (GlimsEngine *engine, GlimsResourceID id,
                                 const char *expected_guard, const char *name, char **error)
{
  GlimsResourceMutationFacts *facts = NULL, *fresh = NULL;
  GimpData *copy = NULL;
  GFile *parent = NULL, *stage_dir = NULL, *stage_file = NULL;
  gchar *guard = NULL, *uuid = NULL, *label = NULL, *source_path = NULL, *destination_path = NULL;
  gboolean own_dir = FALSE, busy = FALSE;
  GError *io_error = NULL;
  GlimsStatus status;
  if (!engine || !glims_valid_resource_name (name) || !expected_guard || strlen (expected_guard) != 64)
    return refusal (error, GLIMS_STATUS_INVALID_ARGUMENT, "Use a nonempty resource name without control characters, at most 255 UTF-8 bytes, and refresh its current state.");
  for (guint i = 0; i < 64; i++)
    if (!(expected_guard[i] >= '0' && expected_guard[i] <= '9') && !(expected_guard[i] >= 'a' && expected_guard[i] <= 'f'))
      return refusal (error, GLIMS_STATUS_INVALID_ARGUMENT, "Refresh the resource before renaming it.");
  if (engine->busy || g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
  status = glims_resource_mutation_inspect (engine, id, &facts, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (!(facts->capabilities & GLIMS_RESOURCE_MUTATION_RENAME)) {
    status = refusal (error, GLIMS_STATUS_UNSUPPORTED, facts->reason ? facts->reason : "This resource cannot be renamed."); goto done;
  }
  guard = glims_resource_mutation_guard (facts);
  if (!guard || strcmp (guard, expected_guard)) {
    status = refusal (error, GLIMS_STATUS_NOT_FOUND, "The resource changed. Refresh it before renaming."); goto done;
  }
  if (strcmp (gimp_object_get_name (facts->data), name) == 0) { status = GLIMS_STATUS_OK; goto done; }
  if (glims_resource_name_taken (gimp_data_factory_get_container (facts->factory), name)) {
    status = refusal (error, GLIMS_STATUS_FAILED, "A resource with this name already exists."); goto done;
  }
  if ((GIMP_IS_BRUSH_GENERATED (facts->data) || GIMP_IS_GRADIENT (facts->data)) &&
      (g_ascii_isspace (name[0]) || g_ascii_isspace (name[strlen (name) - 1]))) {
    status = refusal (error, GLIMS_STATUS_INVALID_ARGUMENT, "This resource format cannot preserve spaces at the start or end of its name."); goto done;
  }
  if (GIMP_IS_BRUSH_PIPE (facts->data) && GIMP_BRUSH_PIPE (facts->data)->n_brushes < 1) {
    status = refusal (error, GLIMS_STATUS_UNSUPPORTED, "An empty brush pipe cannot be saved."); goto done;
  }
  if (GIMP_IS_PATTERN (facts->data)) {
    GimpTempBuf *mask = GIMP_PATTERN (facts->data)->mask;
    const Babl *format = mask ? gimp_temp_buf_get_format (mask) : NULL;
    if (!format || (format != babl_format ("Y' u8") && format != babl_format ("Y'A u8") &&
                    format != babl_format ("R'G'B' u8") && format != babl_format ("R'G'B'A u8"))) {
      status = refusal (error, GLIMS_STATUS_UNSUPPORTED, "This pattern's pixel format cannot be preserved in its saved file."); goto done;
    }
  }

  engine->busy++; busy = TRUE;
  copy = gimp_data_duplicate (facts->data);
  if (!copy || !gimp_data_is_writable (copy) || g_strcmp0 (gimp_data_get_extension (copy), gimp_data_get_extension (facts->data))) {
    status = refusal (error, GLIMS_STATUS_UNSUPPORTED, "This resource cannot be copied faithfully into its native format."); goto done;
  }
  gimp_object_set_name (GIMP_OBJECT (copy), name);
  if (g_strcmp0 (gimp_object_get_name (copy), name)) {
    status = refusal (error, GLIMS_STATUS_UNSUPPORTED, "This name cannot be preserved by the native resource format."); goto done;
  }
  /* Stage under THIS file's actual configured parent, including secondary
   * writable paths; the final rename stays on the same filesystem. */
  parent = g_file_get_parent (facts->file);
  uuid = g_uuid_string_random (); label = g_strconcat (".glims-rename-", uuid, NULL);
  stage_dir = g_file_get_child (parent, label);
  if (!g_file_make_directory (stage_dir, NULL, &io_error)) {
    status = glims_fail (error, g_steal_pointer (&io_error), "The resource folder could not be prepared for saving."); goto done;
  }
  own_dir = TRUE;
  g_free (label); label = g_strconcat ("resource", gimp_data_get_extension (copy), NULL);
  stage_file = g_file_get_child (stage_dir, label);
  gimp_data_set_file (copy, stage_file, TRUE, TRUE);
  if (!gimp_data_is_writable (copy)) {
    status = refusal (error, GLIMS_STATUS_FAILED, "The resource staging folder is not writable."); goto done;
  }
  if (!gimp_data_save (copy, &io_error)) {
    status = glims_fail (error, g_steal_pointer (&io_error), "The renamed resource could not be saved."); goto done;
  }
  if (!preserve_metadata (facts->file, stage_file, &io_error)) {
    status = glims_fail (error, g_steal_pointer (&io_error), "The resource's file security and metadata could not be preserved."); goto done;
  }
  /* File I/O may have taken time. Revalidate the observed identity immediately
   * before the commit; never overwrite a detected replacement/symlink. */
  status = glims_resource_mutation_inspect (engine, id, &fresh, error);
  if (status != GLIMS_STATUS_OK) goto done;
  g_clear_pointer (&guard, g_free); guard = glims_resource_mutation_guard (fresh);
  if (fresh->data != facts->data || !(fresh->capabilities & GLIMS_RESOURCE_MUTATION_RENAME) || !guard || strcmp (guard, expected_guard)) {
    status = refusal (error, GLIMS_STATUS_NOT_FOUND, "The resource changed while saving. Refresh it and try again."); goto done;
  }
  source_path = g_file_get_path (stage_file); destination_path = g_file_get_path (fresh->file);
  if (!source_path || !destination_path) {
    status = refusal (error, GLIMS_STATUS_UNSUPPORTED, "The resource must be stored in a local file."); goto done;
  }
  if (rename (source_path, destination_path) != 0) {
    int code = errno;
    status = glims_fail (error, g_error_new_literal (G_FILE_ERROR, g_file_error_from_errno (code), g_strerror (code)), "The resource file could not be replaced."); goto done;
  }
  /* The disk commit is complete. Same-thread preflight excluded collisions.
   * If an unexpected Core callback interferes, report partial success honestly. */
  gimp_object_set_name (GIMP_OBJECT (facts->data), name);
  if (g_strcmp0 (gimp_object_get_name (facts->data), name)) {
    status = refusal (error, GLIMS_STATUS_FAILED, "The file was renamed, but the resource catalog changed. Refresh the catalog."); goto done;
  }
  GFileInfo *info = g_file_query_info (facts->file, G_FILE_ATTRIBUTE_TIME_MODIFIED, G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, NULL);
  if (info) { gimp_data_set_mtime (facts->data, g_file_info_get_attribute_uint64 (info, G_FILE_ATTRIBUTE_TIME_MODIFIED)); g_object_unref (info); }
  gimp_data_clean (facts->data);
  status = GLIMS_STATUS_OK;
done:
  if (own_dir) {
    if (stage_file) g_file_delete (stage_file, NULL, NULL);
    g_file_delete (stage_dir, NULL, NULL);
  }
  g_clear_object (&copy); g_clear_object (&stage_file); g_clear_object (&stage_dir); g_clear_object (&parent);
  g_free (guard); g_free (uuid); g_free (label); g_free (source_path); g_free (destination_path);
  glims_resource_mutation_facts_free (fresh); glims_resource_mutation_facts_free (facts);
  g_clear_error (&io_error);
  if (busy) engine->busy--;
  return status;
}
