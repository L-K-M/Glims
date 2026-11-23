/*
 * Clear Guides (facade slot 249) leaves custom tool-owned guides alone.
 * The facade cannot create one, so this test links the adapter objects and
 * adds one natively. Test-only file.
 *
 *   guides-clear-tests WORK_DIR
 */
#include "engine-private.h"

#include <stdio.h>

#include "core/gimpguide.h"
#include "core/gimpimage.h"
#include "core/gimpimage-guides.h"

static const GlimsEngineAPI *api;
static unsigned              checks, failures;

#define CHECK(condition, message)                                   \
  do {                                                              \
    gboolean pass = (condition);                                    \
    checks++;                                                       \
    printf ("%s %s\n", pass ? "ok  " : "FAIL", message);            \
    if (! pass)                                                     \
      failures++;                                                   \
    fflush (stdout);                                                \
  } while (0)

typedef struct
{
  GlimsImageID  image;
  GimpGuide    *custom;
  gboolean      present;
  guint         total;
} Probe;

static GlimsStatus
add_custom_guide (GlimsEngine *engine, gpointer data)
{
  Probe          *probe = data;
  GlimsOpenImage *open = glims_lookup_image (engine, probe->image);
  GimpGuide      *guide;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  guide = gimp_guide_custom_new (GIMP_ORIENTATION_HORIZONTAL, 900001,
                                 GIMP_GUIDE_STYLE_SPLIT_VIEW);
  gimp_image_add_guide (open->image, guide, 12);
  g_object_unref (guide);
  probe->custom = guide;

  return GLIMS_STATUS_OK;
}

static GlimsStatus
read_native_guides (GlimsEngine *engine, gpointer data)
{
  Probe          *probe = data;
  GlimsOpenImage *open = glims_lookup_image (engine, probe->image);
  GList          *guides;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  guides = gimp_image_get_guides (open->image);
  probe->present = g_list_find (guides, probe->custom) != NULL;
  probe->total = g_list_length (guides);

  return GLIMS_STATUS_OK;
}

static gboolean
native_guides_are (GlimsEngine *engine, Probe *probe, guint total)
{
  return glims_engine_call (engine, read_native_guides, probe) == GLIMS_STATUS_OK &&
         probe->present && probe->total == total;
}

static int32_t
undo_steps (GlimsEngine *engine, GlimsImageID image)
{
  GlimsUndoInfo info;

  return api->image_undo_info (engine, image, &info) == GLIMS_STATUS_OK ? info.undo_count : -1;
}

int
main (int argc, char **argv)
{
  GlimsEngine *engine = NULL;
  char        *error = NULL;
  Probe        probe = { 0 };
  int32_t      before;

  if (argc != 2)
    return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (! api)
    return 2;

  gchar *user = g_build_filename (argv[1], "user", NULL);
  gchar *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config,
                               .user_directory = user, .cache_directory = cache };

  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "%s\n", error ? error : "startup failed");
      return 2;
    }

  CHECK (api->image_new (engine, 64, 48, &probe.image, NULL) == GLIMS_STATUS_OK, "an image opens");
  CHECK (glims_engine_call (engine, add_custom_guide, &probe) == GLIMS_STATUS_OK &&
         native_guides_are (engine, &probe, 1), "a custom guide is in place");

  before = undo_steps (engine, probe.image);
  CHECK (api->image_clear_guides (engine, probe.image, NULL) == GLIMS_STATUS_OK &&
         native_guides_are (engine, &probe, 1) && undo_steps (engine, probe.image) == before,
         "clearing only a custom guide changes nothing");

  for (int32_t position = 8; position <= 24; position += 8)
    CHECK (api->guide_put (engine, probe.image,
                           &(GlimsGuideInfo) { 0, GLIMS_GUIDE_VERTICAL, position }, NULL,
                           NULL) == GLIMS_STATUS_OK, "an ordinary guide is added");

  before = undo_steps (engine, probe.image);
  CHECK (api->image_clear_guides (engine, probe.image, NULL) == GLIMS_STATUS_OK &&
         native_guides_are (engine, &probe, 1) && undo_steps (engine, probe.image) == before + 1,
         "clearing keeps the custom guide and is one undo step");
  CHECK (api->image_undo (engine, probe.image) == GLIMS_STATUS_OK &&
         native_guides_are (engine, &probe, 4),
         "undo restores the three beside the custom guide");

  api->image_close (engine, probe.image);
  api->stop (engine);
  g_free (user);
  g_free (cache);
  printf ("guides-clear-tests: %u checks, %u failures\n", checks, failures);

  return failures ? 1 : 0;
}
