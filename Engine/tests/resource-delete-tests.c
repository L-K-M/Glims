/* A deterministic file-delete failure must preserve catalog and contexts. */
#include "engine-private.h"
#include "resource-mutation.h"
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimppattern.h"
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

static const GlimsEngineAPI *api;
static int failures, intercepted;
static GFile *deny_file;
#define CHECK(c, text) do { gboolean checked = (c); printf ("%s %s\n", checked ? "ok  " : "FAIL", text); if (!checked) failures++; fflush (stdout); } while (0)
#define NEED(c, text) do { gboolean needed = (c); CHECK (needed, text); if (!needed) { if (error) fprintf (stderr, "%s\n", error); goto done; } } while (0)

/* Test executable overrides Core's unresolved call. The GIO implementation
 * remains the delegate for every other operation and all cleanup. */
gboolean g_file_delete (GFile *file, GCancellable *cancel, GError **error)
{
  static gboolean (*real_delete) (GFile *, GCancellable *, GError **);
  if (!real_delete) *(void **) (&real_delete) = dlsym (RTLD_NEXT, "g_file_delete");
  if (deny_file && g_file_equal (file, deny_file)) {
    intercepted++;
    g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "Injected resource delete denial");
    return FALSE;
  }
  if (!real_delete) { g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Missing real delete delegate"); return FALSE; }
  return real_delete (file, cancel, error);
}

static void trace_critical (const gchar *domain, GLogLevelFlags level, const gchar *message, gpointer ignored)
{
  void *frames[80]; (void) domain; (void) level; (void) ignored;
  fprintf (stderr, "native critical: %s\n", message);
  backtrace_symbols_fd (frames, backtrace (frames, 80), 2);
}

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }

typedef struct { GlimsEngine *engine; GimpData *source; GlimsResourceID brush; int calls; } Reentry;
static void on_remove (GimpContainer *container, GimpObject *object, Reentry *probe)
{
  (void) container;
  if (object != GIMP_OBJECT (probe->source)) return;
  GlimsResourceID result = 123; char *error = NULL;
  GlimsStatus status = api->resource_duplicate (probe->engine, probe->brush, "Must not reenter", &result, &error);
  CHECK (status == GLIMS_STATUS_BUSY && result == 0, "native catalog signals cannot reenter resource mutation");
  clear_error (&error); probe->calls++;
}

static GlimsStatus run_all (GlimsEngine *engine, gpointer unused)
{
  const uint8_t pixel[4] = {255, 0, 0, 255};
  GlimsResourceID id = 0;
  GlimsImageID image = 0;
  GlimsImageInfo image_before = {0}, image_after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  guint8 pixels_before[16 * 16 * 4], pixels_after[16 * 16 * 4];
  GlimsResourceMutationFacts *facts = NULL, *after = NULL;
  GFile *file = NULL;
  gchar *guard = NULL, *bytes = NULL, *after_bytes = NULL;
  gsize length = 0, after_length = 0;
  char *error = NULL;
  gulong handler = 0;
  (void) unused;
  NEED (api->resource_create_pixels (engine, GLIMS_RESOURCE_PATTERN, "Delete fixture", 1, 1, pixel, sizeof pixel, 0, &id, &error) == GLIMS_STATUS_OK,
        "a saved pattern fixture exists");
  NEED (glims_resource_mutation_inspect (engine, id, &facts, &error) == GLIMS_STATUS_OK && facts,
        "the fixture has a current mutation snapshot");
  guard = glims_resource_mutation_guard (facts); file = g_object_ref (facts->file);
  NEED (guard && strlen (guard) == 64 && g_file_load_contents (file, NULL, &bytes, &length, NULL, NULL),
        "the guard and independent file baseline exist");
  NEED (api->image_new (engine, 16, 16, &image, &error) == GLIMS_STATUS_OK &&
        api->image_render (engine, image, 1, (GlimsRect) {0, 0, 16, 16}, pixels_before, 16 * 4) == GLIMS_STATUS_OK &&
        api->image_info (engine, image, &image_before) == GLIMS_STATUS_OK &&
        api->image_undo_info (engine, image, &undo_before) == GLIMS_STATUS_OK,
        "an unrelated image has independently captured pixels, facts and history");
  GimpContext *context = gimp_get_user_context (engine->gimp);
  gimp_context_set_pattern (context, GIMP_PATTERN (facts->data));
  GimpPattern *selected = gimp_context_get_pattern (context);
  GlimsStatus status = glims_resource_delete_checked (engine, id, NULL, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && g_file_query_exists (file, NULL), "an absent guard refuses before deleting");
  clear_error (&error);
  gchar *wrong = g_strdup (guard); wrong[0] = wrong[0] == '0' ? '1' : '0';
  status = glims_resource_delete_checked (engine, id, wrong, &error); g_free (wrong);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && g_file_query_exists (file, NULL), "a stale observed guard refuses without touching the file");
  clear_error (&error);
  engine->busy++;
  status = glims_resource_delete_checked (engine, id, guard, &error);
  engine->busy--;
  CHECK (status == GLIMS_STATUS_BUSY && g_file_query_exists (file, NULL), "global exclusive work refuses deletion"); clear_error (&error);

  /* A replaced file must survive a stale confirmation, even when the
   * native resource object/name still refer to its previously loaded data. */
  const char replacement[] = "independent replacement sentinel";
  NEED (g_file_replace_contents (file, replacement, sizeof replacement - 1, NULL, FALSE,
                                  G_FILE_CREATE_NONE, NULL, NULL, NULL),
        "an independent replacement occupies the old resource path");
  status = glims_resource_delete_checked (engine, id, guard, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND, "a physical replacement invalidates the old observed guard");
  clear_error (&error);
  NEED (g_file_load_contents (file, NULL, &after_bytes, &after_length, NULL, NULL), "the replacement remains readable");
  CHECK (after_length == sizeof replacement - 1 && memcmp (after_bytes, replacement, after_length) == 0,
         "a stale Delete preserves every replacement-sentinel byte");
  g_clear_pointer (&after_bytes, g_free);
  CHECK (selected == gimp_context_get_pattern (context), "a stale physical-file guard leaves native selection unchanged");
  NEED (g_file_replace_contents (file, bytes, length, NULL, FALSE, G_FILE_CREATE_NONE, NULL, NULL, NULL),
        "the test restores its own original resource bytes");
  NEED (glims_resource_mutation_inspect (engine, id, &after, &error) == GLIMS_STATUS_OK && after,
        "the restored file has a fresh inspectable identity");
  g_free (guard); guard = glims_resource_mutation_guard (after);
  glims_resource_mutation_facts_free (after); after = NULL;
  NEED (guard != NULL, "a new observed guard is available after explicit refresh");

  deny_file = file; intercepted = 0;
  status = glims_resource_delete_checked (engine, id, guard, &error);
  deny_file = NULL;
  CHECK (status == GLIMS_STATUS_FAILED && intercepted == 1 && engine->busy == 0,
         "injected disk failure is reported exactly once and releases the busy gate");
  clear_error (&error);
  CHECK (glims_resource_mutation_inspect (engine, id, &after, &error) == GLIMS_STATUS_OK && after && after->data == facts->data,
         "a failed disk delete preserves native catalog membership and identity");
  clear_error (&error);
  CHECK (selected == gimp_context_get_pattern (context), "disk failure preserves the explicitly selected native pattern");
  NEED (g_file_load_contents (file, NULL, &after_bytes, &after_length, NULL, NULL), "the original file is readable after injected failure");
  CHECK (length == after_length && memcmp (bytes, after_bytes, length) == 0, "injected failure preserves every saved byte");
  glims_resource_mutation_facts_free (after); after = NULL;

  Reentry probe = { .engine = engine, .source = facts->data,
    .brush = (GlimsResourceID) gimp_data_get_id (GIMP_DATA (gimp_context_get_brush (context))) };
  GimpContainer *container = gimp_data_factory_get_container (facts->factory);
  handler = g_signal_connect (container, "remove", G_CALLBACK (on_remove), &probe);
  status = glims_resource_delete_checked (engine, id, guard, &error);
  g_signal_handler_disconnect (container, handler); handler = 0;
  CHECK (status == GLIMS_STATUS_OK && engine->busy == 0, "successful checked deletion releases the busy gate");
  clear_error (&error);
  CHECK (!g_file_query_exists (file, NULL), "success removes the actual saved file");
  CHECK (probe.calls == 1, "successful deletion removes native membership exactly once");
  CHECK (gimp_context_get_pattern (context) != selected, "native context fallback stops referencing the deleted selected pattern");
  GimpData *remaining = NULL;
  CHECK (glims_lookup_resource_data (engine, id, &remaining) == GLIMS_STATUS_NOT_FOUND,
         "held facts cannot keep a removed resource discoverable");
  status = glims_resource_delete_checked (engine, id, guard, &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND, "a repeated delete reports the stale handle"); clear_error (&error);
  CHECK (api->image_render (engine, image, 1, (GlimsRect) {0, 0, 16, 16}, pixels_after, 16 * 4) == GLIMS_STATUS_OK &&
         api->image_info (engine, image, &image_after) == GLIMS_STATUS_OK &&
         api->image_undo_info (engine, image, &undo_after) == GLIMS_STATUS_OK &&
         memcmp (pixels_before, pixels_after, sizeof pixels_before) == 0 &&
         memcmp (&image_before, &image_after, sizeof image_before) == 0 &&
         memcmp (&undo_before, &undo_after, sizeof undo_before) == 0,
         "failed and successful resource deletion leave open-image pixels, facts and complete history unchanged");
done:
  deny_file = NULL;
  if (handler && facts) g_signal_handler_disconnect (gimp_data_factory_get_container (facts->factory), handler);
  clear_error (&error); glims_resource_mutation_facts_free (after); glims_resource_mutation_facts_free (facts);
  if (image) api->image_close (engine, image);
  g_clear_object (&file); g_free (guard); g_free (bytes); g_free (after_bytes);
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
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) { fprintf (stderr, "%s\n", error ? error : "start failed"); clear_error (&error); return 2; }
  clear_error (&error);
  g_log_set_handler ("Gimp-Core", G_LOG_LEVEL_CRITICAL | G_LOG_FLAG_FATAL | G_LOG_FLAG_RECURSION, trace_critical, NULL);
  GlimsStatus status = glims_engine_call (engine, run_all, NULL);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED", failures);
  return failures || status != GLIMS_STATUS_OK;
}
