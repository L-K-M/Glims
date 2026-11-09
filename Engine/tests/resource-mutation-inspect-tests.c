/* Private read-only resource admission checks, run only on the engine thread. */
#include "engine-private.h"
#include "resource-mutation-inspect.h"
#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpobject.h"
#include <stdio.h>
#include <string.h>
/* The harness is C11; inherited engine flags also request C89 style. */
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

static const GlimsEngineAPI *api;
static int failures;
#define CHECK(c, text) do { gboolean ok_ = (c); printf ("%s %s\n", ok_ ? "ok  " : "FAIL", text); if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean fixture_success = (c); CHECK (fixture_success, text); if (!fixture_success) { if (error) fprintf (stderr, "fixture: %s\n", error); goto done; } } while (0)

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }

static GlimsStatus run_all (GlimsEngine *engine, gpointer unused)
{
  const uint8_t rgba[16] = {255,0,0,255, 0,0,255,255, 0,255,0,255, 255,255,255,255};
  GlimsResourceID id = 0;
  GlimsImageID image = 0;
  GlimsResourceMutationFacts *facts = NULL;
  char *error = NULL;
  gchar *contents = NULL, *digest = NULL, *after_digest = NULL;
  gsize length = 0;
  GFile *file = NULL, *parent = NULL, *backup = NULL;
  GimpData *data = NULL;
  GlimsResourceMutationFacts *again = NULL;
  gboolean restore_pending = FALSE, replacement_created = FALSE;
  GimpContext *context = gimp_get_user_context (engine->gimp);
  gpointer brush = gimp_context_get_brush (context), pattern = gimp_context_get_pattern (context), gradient = gimp_context_get_gradient (context);
  (void) unused;
  NEED (api->resource_create_pixels (engine, GLIMS_RESOURCE_PATTERN, "Inspect fixture", 2, 2, rgba, sizeof rgba, 0, &id, &error) == GLIMS_STATUS_OK,
        "a checked pattern is saved in the configured writable directory");
  NEED (api->image_new (engine, 16, 16, &image, &error) == GLIMS_STATUS_OK, "an unrelated image exists for unchanged-state checks");
  GlimsImageInfo image_before = {0}, image_after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  NEED (api->image_info (engine, image, &image_before) == GLIMS_STATUS_OK && api->image_undo_info (engine, image, &undo_before) == GLIMS_STATUS_OK,
        "the baseline image/history reads succeed");
  NEED (glims_resource_mutation_inspect (engine, id, &facts, &error) == GLIMS_STATUS_OK && facts,
        "a valid current resource returns owned inspection facts");
  CHECK (facts->capabilities == (GLIMS_RESOURCE_MUTATION_RENAME | GLIMS_RESOURCE_MUTATION_DELETE) && !facts->reason,
         "the newly saved pattern admits both native mutation prerequisites");
  CHECK (facts->data && facts->factory && facts->file && facts->file_id && *facts->file_id && facts->etag && *facts->etag,
         "admitted facts own native objects and nonempty file identity and etag");
  NEED (g_file_load_contents (facts->file, NULL, &contents, &length, NULL, NULL), "the saved fixture has independently readable bytes");
  digest = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) contents, length);
  g_clear_pointer (&contents, g_free);
  file = g_object_ref (facts->file);
  data = g_object_ref (facts->data);
  NEED (glims_resource_mutation_inspect (engine, id, &again, &error) == GLIMS_STATUS_OK && again,
        "repeated inspection succeeds");
  CHECK (again != facts && again->data == facts->data && again->file != NULL &&
         strcmp (again->file_id, facts->file_id) == 0 && strcmp (again->etag, facts->etag) == 0,
         "independent snapshots name the same unchanged native object/file");
  glims_resource_mutation_facts_free (again); again = NULL;
  glims_resource_mutation_facts_free (facts); facts = NULL;
  CHECK (!gimp_data_is_dirty (data) && strcmp (gimp_object_get_name (data), "Inspect fixture") == 0,
         "inspection leaves the live resource name and clean state unchanged");
  /* Preserve the original file under an owned sibling while presenting
   * missing, directory and symlink replacements at its associated path. */
  parent = g_file_get_parent (file);
  gchar *uuid = g_uuid_string_random ();
  gchar *name = g_strconcat (".inspect-backup-", uuid, NULL);
  backup = g_file_get_child (parent, name);
  g_free (uuid); g_free (name);
  for (int variant = 0; variant < 3; variant++) {
    gboolean moved = g_file_move (file, backup, G_FILE_COPY_NO_FALLBACK_FOR_MOVE, NULL, NULL, NULL, NULL);
    CHECK (moved, "the fixture owns a no-overwrite backup before replacement checks");
    if (!moved) break;
    restore_pending = TRUE;
    gboolean created = FALSE;
    if (variant == 1) created = g_file_make_directory (file, NULL, NULL);
    if (variant == 2) {
      gchar *target = g_file_get_path (backup);
      created = g_file_make_symbolic_link (file, target, NULL, NULL); g_free (target);
    }
    replacement_created = created;
    CHECK (variant == 0 || created, "the requested directory or symlink fixture actually exists");
    GlimsStatus status = glims_resource_mutation_inspect (engine, id, &facts, &error);
    CHECK (status == GLIMS_STATUS_OK && facts && facts->capabilities == 0 && facts->reason && *facts->reason,
           "missing, directory and symlink paths return an explicit ineligible snapshot");
    glims_resource_mutation_facts_free (facts); facts = NULL; clear_error (&error);
    if (created) {
      gboolean removed = g_file_delete (file, NULL, NULL);
      CHECK (removed, "only the fixture's own replacement is removed");
      if (removed) replacement_created = FALSE;
    }
    gboolean restored = g_file_move (backup, file, G_FILE_COPY_NO_FALLBACK_FOR_MOVE, NULL, NULL, NULL, NULL);
    CHECK (restored, "the fixture restores the original saved file without overwrite");
    if (!restored) break;
    restore_pending = FALSE;
  }
  NEED (g_file_load_contents (file, NULL, &contents, &length, NULL, NULL), "the original payload remains readable after path refusal checks");
  after_digest = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) contents, length);
  CHECK (strcmp (digest, after_digest) == 0, "all refusal inspections preserve every original file byte");

  /* Native capability flags alone do not authorize an arbitrary file. */
  for (int nested = 0; nested < 2; nested++) {
    GFile *folder = nested ? g_file_get_child (parent, ".inspect-subfolder") : g_file_get_parent (parent);
    gboolean made_folder = !nested || g_file_make_directory (folder, NULL, NULL);
    CHECK (made_folder, "the configured-folder boundary fixture is available");
    gchar *unique = g_uuid_string_random ();
    GFile *outside = g_file_get_child (folder, unique); g_free (unique);
    gboolean copied = made_folder && g_file_copy (file, outside, G_FILE_COPY_NONE, NULL, NULL, NULL, NULL);
    CHECK (copied, "a fixture-owned payload exists outside the direct configured save directory");
    if (copied) {
      gimp_data_set_file (data, outside, TRUE, TRUE);
      GlimsStatus status = glims_resource_mutation_inspect (engine, id, &facts, &error);
      CHECK (status == GLIMS_STATUS_OK && facts && !facts->capabilities && facts->reason,
             "writable native data in a sibling or nested folder is explicitly ineligible");
      glims_resource_mutation_facts_free (facts); facts = NULL; clear_error (&error);
      gimp_data_set_file (data, file, TRUE, TRUE);
      CHECK (g_file_delete (outside, NULL, NULL), "the test deletes only its own copied boundary fixture");
    }
    if (nested && made_folder) CHECK (g_file_delete (folder, NULL, NULL), "the test removes its own empty nested folder");
    g_object_unref (outside); g_object_unref (folder);
  }
  NEED (glims_resource_mutation_inspect (engine, id, &facts, &error) == GLIMS_STATUS_OK && facts,
        "the restored direct file is inspectable again");
  CHECK (facts->capabilities == 3, "restoring the native association restores its eligible snapshot");
  glims_resource_mutation_facts_free (facts); facts = NULL;

  const GlimsResourceID bad[] = {0, ((GlimsResourceID) 1 << 63), 123456789};
  for (guint i = 0; i < G_N_ELEMENTS (bad); i++) {
    facts = (GlimsResourceMutationFacts *) 1;
    GlimsStatus status = glims_resource_mutation_inspect (engine, bad[i], &facts, &error);
    CHECK (status == (i < 2 ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_NOT_FOUND) && facts == NULL,
           "malformed and stale handles are classified without returning partial facts");
    clear_error (&error);
  }
  CHECK (glims_resource_mutation_inspect (engine, id, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "a missing output is refused without mutation"); clear_error (&error);
  NEED (brush != NULL, "the stock context has a brush fixture");
  GlimsResourceID builtin = (GlimsResourceID) gimp_data_get_id (GIMP_DATA (brush));
  NEED (builtin && glims_resource_mutation_inspect (engine, builtin, &facts, &error) == GLIMS_STATUS_OK && facts,
        "the stock current brush resolves through the same native membership admission");
  CHECK (!facts->capabilities && facts->reason, "stock or internal data stays read-only");
  glims_resource_mutation_facts_free (facts); facts = NULL;
  CHECK (brush == gimp_context_get_brush (context) && pattern == gimp_context_get_pattern (context) && gradient == gimp_context_get_gradient (context),
         "inspection never changes brush, pattern or gradient contexts");
  NEED (glims_resource_mutation_inspect (engine, id, &facts, &error) == GLIMS_STATUS_OK && facts,
        "a final owned snapshot can outlive catalog membership");
  GError *remove_error = NULL;
  gboolean removed = gimp_data_factory_data_delete (facts->factory, facts->data, FALSE, &remove_error);
  CHECK (removed && !remove_error, "removing fixture catalog membership does not delete its file");
  g_clear_error (&remove_error);
  CHECK (GIMP_IS_DATA (facts->data) && g_file_query_exists (file, NULL),
         "held facts retain the native object while leaving its original file intact");
  GlimsStatus stale_status = glims_resource_mutation_inspect (engine, id, &again, &error);
  CHECK (stale_status == GLIMS_STATUS_NOT_FOUND && again == NULL,
         "a held native reference never re-admits an object removed from the current catalog");
  clear_error (&error);
  glims_resource_mutation_facts_free (facts); facts = NULL;
  CHECK (api->image_info (engine, image, &image_after) == GLIMS_STATUS_OK && api->image_undo_info (engine, image, &undo_after) == GLIMS_STATUS_OK &&
         memcmp (&image_before, &image_after, sizeof image_before) == 0 && memcmp (&undo_before, &undo_after, sizeof undo_before) == 0,
         "inspection leaves unrelated image facts and complete history unchanged");
done:
  if (restore_pending && backup && file) {
    if (replacement_created) g_file_delete (file, NULL, NULL);
    CHECK (g_file_move (backup, file, G_FILE_COPY_NO_FALLBACK_FOR_MOVE, NULL, NULL, NULL, NULL),
           "cleanup restores the fixture's own saved bytes without replacing a sentinel");
  }
  g_clear_object (&backup); g_clear_object (&parent); g_clear_object (&file); g_clear_object (&data);
  g_free (contents); g_free (digest); g_free (after_digest);
  clear_error (&error); glims_resource_mutation_facts_free (facts); glims_resource_mutation_facts_free (again);
  if (image) api->image_close (engine, image);
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int main (int argc, char **argv)
{
  if (argc != 2) return 2;
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof (GlimsEngineAPI)) return 2;
  GlimsStatus status = api->start (&config, &engine, &error);
  if (status != GLIMS_STATUS_OK) { fprintf (stderr, "%s\n", error ? error : "start failed"); clear_error (&error); return 2; }
  clear_error (&error);
  status = glims_engine_call (engine, run_all, NULL);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED", failures);
  return failures || status != GLIMS_STATUS_OK;
}
