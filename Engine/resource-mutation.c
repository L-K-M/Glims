/* Checked mutation of explicitly selected, configured user resource files.
 * Refuse stale observed snapshots; delete the file BEFORE native membership,
 * avoiding the factory convenience method's remove-first failure order. */
#include "resource-mutation.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpobject.h"
#include <string.h>

static void
hash_field (GChecksum *checksum, const gchar *text)
{
  const gchar *value = text ? text : "";
  /* NUL delimiters distinguish every field boundary. */
  g_checksum_update (checksum, (const guchar *) value, strlen (value) + 1);
}

gchar *
glims_resource_mutation_guard (const GlimsResourceMutationFacts *facts)
{
  if (!facts || !facts->data || !facts->file || !facts->file_id || !*facts->file_id || !facts->etag || !*facts->etag)
    return NULL;
  GChecksum *checksum = g_checksum_new (G_CHECKSUM_SHA256);
  gchar *uri = g_file_get_uri (facts->file);
  gchar *id = g_strdup_printf ("%d", gimp_data_get_id (facts->data));
  hash_field (checksum, "Glims resource snapshot 1");
  hash_field (checksum, id);
  hash_field (checksum, gimp_object_get_name (facts->data));
  hash_field (checksum, uri);
  hash_field (checksum, facts->file_id);
  hash_field (checksum, facts->etag);
  gchar *result = g_strdup (g_checksum_get_string (checksum));
  g_checksum_free (checksum); g_free (uri); g_free (id);
  return result;
}

static gboolean
valid_guard (const char *guard)
{
  if (!guard || strlen (guard) != 64) return FALSE;
  for (guint i = 0; i < 64; i++)
    if (!(guard[i] >= '0' && guard[i] <= '9') && !(guard[i] >= 'a' && guard[i] <= 'f')) return FALSE;
  return TRUE;
}

GlimsStatus
glims_resource_delete_checked (GlimsEngine *engine, GlimsResourceID id,
                                 const char *expected_guard, char **error)
{
  GlimsResourceMutationFacts *facts = NULL;
  GlimsStatus status;
  GError *io_error = NULL;
  gchar *guard;
  if (!engine || !valid_guard (expected_guard)) {
    if (error) *error = strdup ("Refresh the resource before deleting it.");
    return GLIMS_STATUS_INVALID_ARGUMENT;
  }
  if (engine->busy > 0 || g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters))
    return GLIMS_STATUS_BUSY;
  status = glims_resource_mutation_inspect (engine, id, &facts, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (!(facts->capabilities & GLIMS_RESOURCE_MUTATION_DELETE)) {
    if (error) *error = strdup (facts->reason ? facts->reason : "This resource cannot be deleted.");
    status = GLIMS_STATUS_UNSUPPORTED;
    goto done;
  }
  guard = glims_resource_mutation_guard (facts);
  gboolean matches = guard && strcmp (guard, expected_guard) == 0;
  g_free (guard);
  if (!matches) {
    if (error) *error = strdup ("The resource changed. Refresh it before deleting.");
    status = GLIMS_STATUS_NOT_FOUND;
    goto done;
  }

  /* Block reentrant facade edits during native resource/context signals. */
  engine->busy++;
  if (!gimp_data_delete_from_disk (facts->data, &io_error)) {
    status = glims_fail (error, io_error, "The resource file could not be deleted.");
    io_error = NULL; /* glims_fail consumes the GError */
  } else if (!gimp_data_factory_data_delete (facts->factory, facts->data, FALSE, &io_error)) {
    /* Disk removal already succeeded. Never imply this rare failure was
     * unchanged: callers must reconcile the catalog after every result. */
    status = glims_fail (error, io_error, "The resource file was deleted, but its catalog could not be refreshed.");
    io_error = NULL;
  } else {
    GimpData *remaining = NULL;
    status = glims_lookup_resource_data (engine, id, &remaining) == GLIMS_STATUS_NOT_FOUND
      ? GLIMS_STATUS_OK : glims_fail (error, NULL, "The resource file was deleted, but its catalog entry remains.");
  }
  engine->busy--;
done:
  g_clear_error (&io_error);
  glims_resource_mutation_facts_free (facts);
  return status;
}
