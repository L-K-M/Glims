/* Read-only admission facts for explicitly selected user resource files.
 * Native capability is not provenance: UUID filenames never imply authorship.
 * Only regular files directly in configured writable/search directories are
 * admitted. A snapshot cannot prevent subsequent external filesystem changes. */
#include "resource-mutation-inspect.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpviewable.h"
#include <string.h>

void
glims_resource_mutation_facts_free (GlimsResourceMutationFacts *facts)
{
  if (!facts) return;
  g_clear_object (&facts->data);
  g_clear_object (&facts->factory);
  g_clear_object (&facts->file);
  g_free (facts->file_id); g_free (facts->etag); g_free (facts->reason);
  g_free (facts);
}

static gboolean
known_extension (const gchar *extension)
{
  static const gchar *extensions[] = { ".gbr", ".vbr", ".gih", ".pat", ".ggr" };
  for (guint i = 0; i < G_N_ELEMENTS (extensions); i++)
    if (g_strcmp0 (extension, extensions[i]) == 0) return TRUE;
  return FALSE;
}

/* Both native getters transfer their lists AND GFile references. Equality is
 * exact GFile equality; this first slice deliberately excludes subdirectories. */
static gboolean
configured_parent (GimpDataFactory *factory, GFile *file)
{
  GList *search = gimp_data_factory_get_data_path (factory);
  GList *writable = gimp_data_factory_get_data_path_writable (factory);
  GFile *parent = g_file_get_parent (file);
  gboolean matched = FALSE;
  if (parent && g_file_query_file_type (parent, G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL) == G_FILE_TYPE_DIRECTORY) {
    for (GList *w = writable; w && !matched; w = w->next) {
      if (!g_file_equal (parent, w->data)) continue;
      for (GList *s = search; s; s = s->next)
        if (g_file_equal (parent, s->data)) { matched = TRUE; break; }
    }
  }
  g_clear_object (&parent);
  g_list_free_full (search, g_object_unref);
  g_list_free_full (writable, g_object_unref);
  return matched;
}

static GlimsStatus
ineligible (GlimsResourceMutationFacts *facts, const gchar *reason,
            GlimsResourceMutationFacts **out)
{
  facts->reason = g_strdup (reason);
  *out = facts;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_resource_mutation_inspect (GlimsEngine *engine, GlimsResourceID id,
                                  GlimsResourceMutationFacts **out, char **error)
{
  GimpData *data = NULL;
  GlimsStatus status;
  GlimsResourceMutationFacts *facts;
  GFile *file;
  GFileInfo *info;
  GError *io_error = NULL;
  gchar *local;

  if (out) *out = NULL;
  if (!engine || !out) {
    if (error) *error = strdup ("An engine and resource information output are required.");
    return GLIMS_STATUS_INVALID_ARGUMENT;
  }
  status = glims_lookup_resource_data (engine, id, &data);
  if (status != GLIMS_STATUS_OK) {
    if (error) *error = strdup (status == GLIMS_STATUS_INVALID_ARGUMENT
      ? "This handle cannot name a resource." : "This resource is no longer in the current catalog.");
    return status;
  }
  facts = g_new0 (GlimsResourceMutationFacts, 1);
  facts->data = g_object_ref (data);
  GimpDataFactory *factory = glims_factory_for_resource (engine->gimp, data);
  if (factory) facts->factory = g_object_ref (factory);
  file = gimp_data_get_file (data); /* borrowed native association */
  if (file) facts->file = g_object_ref (file);
  facts->native_mtime = gimp_data_get_mtime (data);

  if (!factory || gimp_data_is_internal (data) || !gimp_data_is_writable (data) ||
      !gimp_data_is_deletable (data) || !known_extension (gimp_data_get_extension (data)))
    return ineligible (facts, "This built-in, shared or read-only resource cannot be changed. Duplicate it first.", out);
  if (!file)
    return ineligible (facts, "This resource has no saved file.", out);
  local = g_file_get_path (file);
  gboolean absolute = local && g_path_is_absolute (local);
  g_free (local);
  if (!absolute || !configured_parent (factory, file))
    return ineligible (facts, "Only files directly in a configured writable resource folder can be changed.", out);

  info = g_file_query_info (file,
    G_FILE_ATTRIBUTE_STANDARD_TYPE "," G_FILE_ATTRIBUTE_STANDARD_IS_SYMLINK ","
    G_FILE_ATTRIBUTE_ID_FILE "," G_FILE_ATTRIBUTE_ETAG_VALUE "," G_FILE_ATTRIBUTE_TIME_MODIFIED,
    G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &io_error);
  if (!info) {
    g_clear_error (&io_error);
    return ineligible (facts, "The resource file could not be inspected. Refresh the catalog and try again.", out);
  }
  gboolean regular = g_file_info_get_file_type (info) == G_FILE_TYPE_REGULAR && !g_file_info_get_is_symlink (info);
  facts->file_id = g_strdup (g_file_info_get_attribute_string (info, G_FILE_ATTRIBUTE_ID_FILE));
  facts->etag = g_strdup (g_file_info_get_etag (info));
  g_object_unref (info);
  if (!regular || !facts->file_id || !*facts->file_id)
    return ineligible (facts, "The saved resource must be a regular file with a verifiable file identity.", out);
  facts->capabilities = GLIMS_RESOURCE_MUTATION_DELETE;
  if (gimp_viewable_is_name_editable (GIMP_VIEWABLE (data)) && gimp_data_is_duplicatable (data))
    facts->capabilities |= GLIMS_RESOURCE_MUTATION_RENAME;
  *out = facts;
  return GLIMS_STATUS_OK;
}
