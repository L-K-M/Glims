/* Capture actual full float selection masks/history from an immutable producer.
 * A separate driver byte-compares original and patched captures. This harness
 * creates no expected mask from the workaround and installs no interface spy.
 */
#include "engine-private.h"
#include <stdio.h>
#include <string.h>
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"

#define WIDTH 17
#define HEIGHT 13
#define SAMPLES (WIDTH * HEIGHT)

static const GlimsEngineAPI *api;
static int failures;

int main (int argc, char **argv);

#define REQUIRE(condition, message) do { if (!(condition)) { \
  fprintf (stderr, "FAIL case %u: %s\n", number, message); failures++; goto cleanup; \
} } while (0)

static gboolean
capture (GlimsEngine *engine, GlimsImageID id, const char *directory,
         guint number, const char *phase, float samples[SAMPLES], GlimsUndoInfo *history)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (gimp_image_get_mask (open->image)));
  gchar *name = g_strdup_printf ("%02u-%s.mask", number, phase);
  gchar *path = g_build_filename (directory, name, NULL);
  gchar *text, *meta_path;
  gboolean ok;

  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 1.0,
                   babl_format ("Y float"), samples, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  memset (history, 0, sizeof *history);
  ok = api->image_undo_info (engine, id, history) == GLIMS_STATUS_OK;
  if (ok)
    ok = g_file_set_contents (path, (const gchar *) samples, sizeof (float) * SAMPLES, NULL);
  text = g_strdup_printf ("width=%d\nheight=%d\nformat=Y float\nundo=%d\nredo=%d\nnext_undo=%s\nnext_redo=%s\n",
                          WIDTH, HEIGHT, history->undo_count, history->redo_count,
                          history->next_undo, history->next_redo);
  meta_path = g_strconcat (path, ".txt", NULL);
  if (ok)
    ok = g_file_set_contents (meta_path, text, -1, NULL);
  g_free (name); g_free (path); g_free (text); g_free (meta_path);
  return ok;
}

static GlimsStatus
exercise (GlimsEngine *engine, gpointer data)
{
  const gchar *directory = data;
  guint number = 0, contiguous, merged, soft, effect;

  for (contiguous = 0; contiguous < 2; contiguous++)
    for (merged = 0; merged < 2; merged++)
      for (soft = 0; soft < 2; soft++)
        for (effect = 0; effect < 2; effect++, number++)
          {
            guchar background[WIDTH * HEIGHT * 4], foreground[9 * 7 * 4];
            GlimsImageID id = 0;
            GlimsItemID layer = 0;
            GlimsFilterID filter = 0;
            GlimsSelectOptions options = {0}, initial = {0};
            GlimsPoint corners[2] = { {2, 1}, {13, 10} };
            GlimsUndoInfo before_history = {0}, after_history = {0}, history = {0};
            float before[SAMPLES], after[SAMPLES], returned[SAMPLES];
            gint x, y, offset_x = merged ? -2 : 3, offset_y = soft ? 4 : 2;
            char *error = NULL;

            for (y = 0; y < HEIGHT; y++)
              for (x = 0; x < WIDTH; x++)
                {
                  guchar *p = background + (y * WIDTH + x) * 4;
                  p[0] = (guchar) (x * 17 + y * 5);
                  p[1] = (guchar) (y * 29 + x * 3);
                  p[2] = (guchar) (x * 11 + y * 19);
                  p[3] = (x + y) % 5 ? 255 : 96;
                }
            for (y = 0; y < 7; y++)
              for (x = 0; x < 9; x++)
                {
                  guchar *p = foreground + (y * 9 + x) * 4;
                  gboolean islands = x <= 3 || x >= 6;
                  p[0] = islands ? 190 : 18;
                  p[1] = islands ? (guchar) (35 + y * 7) : 170;
                  p[2] = islands ? 55 : (guchar) (95 + y * 11);
                  p[3] = y == 3 ? 255 : (guchar) ((x * 31 + y * 37) % 256);
                }
            REQUIRE (api->image_from_pixels (engine, WIDTH, HEIGHT, background, sizeof background, &id, &error) == GLIMS_STATUS_OK,
                     "create asymmetric public RGBA image");
            REQUIRE (api->image_paste_pixels (engine, id, (GlimsRect) {offset_x, offset_y, 9, 7},
                                              foreground, sizeof foreground, &layer, &error) == GLIMS_STATUS_OK,
                     "paste independently patterned layer at its nonzero offset");
            REQUIRE (api->image_select_layers (engine, id, &layer, 1, &error) == GLIMS_STATUS_OK,
                     "select exactly the offset foreground layer");
            if (effect)
              {
                GlimsLayerInfo layers[4];
                int32_t count = 0;
                gboolean retained_effect = FALSE;
                gint i;

                REQUIRE (api->filter_begin (engine, id, layer, "gegl:brightness-contrast", &filter, &error) == GLIMS_STATUS_OK,
                         "begin a real native committed effect");
                REQUIRE (api->filter_set_double (engine, filter, "brightness", 0.11) == GLIMS_STATUS_OK &&
                         api->filter_set_double (engine, filter, "contrast", 0.19) == GLIMS_STATUS_OK,
                         "configure the real brightness/contrast effect");
                REQUIRE (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
                         "commit the effect before selection setup");
                filter = 0;
                REQUIRE (api->image_layers (engine, id, layers, 4, &count) == GLIMS_STATUS_OK && count <= 4,
                         "read committed layer effects");
                for (i = 0; i < count; i++)
                  if (layers[i].id == layer && layers[i].filter_count == 1)
                    retained_effect = TRUE;
                REQUIRE (retained_effect, "fixture retains the committed effect on its actual layer");
              }
            initial.struct_size = sizeof initial;
            REQUIRE (api->select_shape (engine, id, GLIMS_SHAPE_RECTANGLE, corners, 2, &initial) == GLIMS_STATUS_OK,
                     "establish a known existing selection for all four combination operations");
            REQUIRE (capture (engine, id, directory, number, "before", before, &before_history), "capture before mask/history");
            options.struct_size = sizeof options;
            options.operation = number % 4;
            options.antialias = soft != 0;
            options.feather = soft ? 1.35 : 0.0;
            options.threshold = 0.22;
            options.contiguous = contiguous != 0;
            options.sample_merged = merged != 0;
            REQUIRE (api->select_color (engine, id, (GlimsPoint) {offset_x + 3, offset_y + 3}, &options, &error) == GLIMS_STATUS_OK,
                     "select color through the actual facade");
            REQUIRE (capture (engine, id, directory, number, "after", after, &after_history), "capture selected mask/history");
            REQUIRE (after_history.undo_count == before_history.undo_count + 1 && after_history.redo_count == 0,
                     "selection is exactly one native undo step");
            REQUIRE (api->image_undo (engine, id) == GLIMS_STATUS_OK &&
                     capture (engine, id, directory, number, "undo", returned, &history), "undo and capture its mask/history");
            REQUIRE (memcmp (before, returned, sizeof before) == 0 &&
                     history.undo_count == before_history.undo_count && history.redo_count == 1,
                     "Undo restores every original selection sample and history position");
            REQUIRE (api->image_redo (engine, id) == GLIMS_STATUS_OK &&
                     capture (engine, id, directory, number, "redo", returned, &history), "redo and capture its mask/history");
            REQUIRE (memcmp (after, returned, sizeof after) == 0 &&
                     history.undo_count == after_history.undo_count && history.redo_count == 0,
                     "Redo restores every selected sample and history position");
            printf ("ok case=%u contiguous=%u merged=%u aa=%u feather=%.2f effect=%u op=%u offset=%d,%d\n",
                    number, contiguous, merged, soft, options.feather, effect, options.operation, offset_x, offset_y);
cleanup:
            if (filter) api->filter_abort (engine, filter);
            if (error) api->free_string (error);
            if (id && api->image_close (engine, id) != GLIMS_STATUS_OK) failures++;
            fflush (stdout);
          }
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config = {0};
  GlimsEngine *engine = NULL;
  gchar *home, *cache, *user, *temporary, *capture_dir;
  char *error = NULL;
  GlimsStatus status;

  if (argc != 2) { fprintf (stderr, "usage: %s PRIVATE_WORK\n", argv[0]); return 2; }
  home = g_build_filename (argv[1], "home", NULL);
  cache = g_build_filename (argv[1], "cache", NULL);
  user = g_build_filename (argv[1], "user", NULL);
  temporary = g_build_filename (argv[1], "tmp", NULL);
  capture_dir = g_build_filename (argv[1], "capture", NULL);
  if (g_strcmp0 (g_getenv ("HOME"), home) || g_strcmp0 (g_getenv ("XDG_CACHE_HOME"), cache) ||
      g_strcmp0 (g_getenv ("GIMP3_DIRECTORY"), user) || g_strcmp0 (g_getenv ("TMPDIR"), temporary))
    { fprintf (stderr, "use the parity driver with private settings\n"); return 2; }
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->api_version != GLIMS_ENGINE_API_VERSION || api->struct_size < sizeof *api) return 2;
  config.struct_size = sizeof config;
  config.user_directory = user;
  config.cache_directory = cache;
  status = api->start (&config, &engine, &error);
  if (error) { fprintf (stderr, "%s\n", error); api->free_string (error); }
  if (status != GLIMS_STATUS_OK || !engine) return 1;
  printf ("PARITY engine=%s native float masks; fixture version=1\n", api->engine_version (engine));
  status = glims_engine_call (engine, exercise, capture_dir);
  api->stop (engine);
  printf ("%s: %d parity fixture failures\n", failures || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED", failures);
  g_free (home); g_free (cache); g_free (user); g_free (temporary); g_free (capture_dir);
  return failures || status != GLIMS_STATUS_OK ? 1 : 0;
}
