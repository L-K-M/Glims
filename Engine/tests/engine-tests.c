/*
 * Conformance tests for the engine adapter, through the facade only.
 *
 *   glims-engine-tests LIBRARY WORK_DIR FIXTURES_DIR
 *
 * Loads the adapter with dlopen() exactly as the app does, starts the engine
 * with directories under WORK_DIR, and checks behavior the app relies on:
 * rendering, painting, undo accounting, filter sessions, saving and
 * reopening XCF, and exporting through the engine's file plug-ins. Prints
 * one line per check and exits non-zero if any check fails.
 */
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "glims_engine.h"

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   failures;
static atomic_int            projection_events;
static atomic_int            undo_events;

#define CHECK(condition, ...)                       \
  do {                                              \
    if (condition) {                                \
      printf ("ok    ");                            \
    } else {                                        \
      printf ("FAIL  ");                            \
      failures++;                                   \
    }                                               \
    printf (__VA_ARGS__);                           \
    printf ("\n");                                  \
    fflush (stdout);                                \
  } while (0)

static double
now_ms (void)
{
  struct timespec t;
  clock_gettime (CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void
on_event (void *context, const GlimsEvent *event)
{
  (void) context;
  if (event->kind == GLIMS_EVENT_PROJECTION_CHANGED)
    atomic_fetch_add (&projection_events, 1);
  else if (event->kind == GLIMS_EVENT_UNDO_CHANGED)
    atomic_fetch_add (&undo_events, 1);
  else if (event->kind == GLIMS_EVENT_MESSAGE && event->text)
    printf ("      engine message: %s\n", event->text);
}

/* Renders the whole image at scale 1. The caller frees the result. */
static uint8_t *
render_all (GlimsImageID image, int32_t *width, int32_t *height)
{
  GlimsImageInfo info;
  uint8_t       *pixels;

  if (api->image_info (engine, image, &info) != GLIMS_STATUS_OK)
    return NULL;
  pixels = calloc ((size_t) info.width * info.height, 4);
  if (api->image_render (engine, image, 1.0,
                         (GlimsRect) { 0, 0, info.width, info.height },
                         pixels, (size_t) info.width * 4) != GLIMS_STATUS_OK)
    {
      free (pixels);
      return NULL;
    }
  *width  = info.width;
  *height = info.height;
  return pixels;
}

static const uint8_t *
pixel_at (const uint8_t *pixels, int32_t width, int32_t x, int32_t y)
{
  return pixels + ((size_t) y * width + x) * 4;
}

static GlimsItemID
first_layer (GlimsImageID image)
{
  GlimsLayerInfo row;
  int32_t        count = 0;

  if (api->image_layers (engine, image, &row, 1, &count) != GLIMS_STATUS_OK || count < 1)
    return 0;
  return row.id;
}

static int32_t
undo_depth (GlimsImageID image)
{
  GlimsUndoInfo info;
  return api->image_undo_info (engine, image, &info) == GLIMS_STATUS_OK ? info.undo_count : -1;
}

static void
paint_line (GlimsImageID image, GlimsItemID layer, double x0, double x1, double y)
{
  GlimsBrushSettings brush = { sizeof (GlimsBrushSettings), 9.0, 1.0, 0.0, 0.0, 0.0, false };
  GlimsStrokePoint   first = { x0, y, 1.0, 0.0, 0.0, 0 };
  GlimsStrokePoint   points[16];
  GlimsStrokeID      stroke = 0;
  char              *error  = NULL;
  int                i;

  for (i = 0; i < 16; i++)
    points[i] = (GlimsStrokePoint) { x0 + (x1 - x0) * (i + 1) / 16.0, y, 1.0, 0.0, 0.0, (uint32_t) (i + 1) * 8 };

  CHECK (api->stroke_begin (engine, image, layer, &brush, &first, &stroke, &error) == GLIMS_STATUS_OK,
         "stroke begins%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  CHECK (api->stroke_continue (engine, stroke, points, 16) == GLIMS_STATUS_OK, "stroke takes 16 points");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke ends");
}

static int
file_size (const char *path)
{
  struct stat st;
  return stat (path, &st) == 0 ? (int) st.st_size : -1;
}

static int
count_differences (const uint8_t *a, const uint8_t *b, size_t bytes)
{
  int    n = 0;
  size_t i;

  for (i = 0; i < bytes; i += 4)
    if (memcmp (a + i, b + i, 4) != 0)
      n++;
  return n;
}

/* ---- Tests ------------------------------------------------------------- */

static void
test_new_image_and_render (GlimsImageID *out)
{
  GlimsImageID   image = 0;
  GlimsImageInfo info;
  GlimsLayerInfo rows[4];
  int32_t        count = 0, width = 0, height = 0;
  uint8_t       *pixels;
  uint8_t        half[32 * 24 * 4];
  char          *error = NULL;
  int            white = 1;
  int            i;

  CHECK (api->image_new (engine, 64, 48, &image, &error) == GLIMS_STATUS_OK && image > 0,
         "new 64x48 image");
  api->free_string (error);

  CHECK (api->image_info (engine, image, &info) == GLIMS_STATUS_OK &&
         info.width == 64 && info.height == 48 && info.layer_count == 1 && ! info.dirty,
         "image info: 64x48, 1 layer, clean (precision %s)", info.precision);

  CHECK (api->image_layers (engine, image, rows, 4, &count) == GLIMS_STATUS_OK && count == 1 &&
         strcmp (rows[0].name, "Background") == 0 && rows[0].kind == GLIMS_LAYER_PIXEL &&
         rows[0].visible && strcmp (rows[0].mode, "normal") == 0,
         "layer tree: one visible pixel layer \"Background\" in mode \"%s\"", count ? rows[0].mode : "");

  pixels = render_all (image, &width, &height);
  for (i = 0; pixels && i < width * height; i++)
    if (memcmp (pixels + i * 4, "\xff\xff\xff\xff", 4) != 0)
      white = 0;
  CHECK (pixels && white, "render at 100%%: all pixels opaque white");
  free (pixels);

  CHECK (api->image_render (engine, image, 0.5, (GlimsRect) { 0, 0, 32, 24 }, half, 32 * 4) == GLIMS_STATUS_OK &&
         memcmp (half + (12 * 32 + 16) * 4, "\xff\xff\xff\xff", 4) == 0,
         "render at 50%%: 32x24 white");

  CHECK (api->image_render (engine, image, 0.0, (GlimsRect) { 0, 0, 1, 1 }, half, 4) == GLIMS_STATUS_INVALID_ARGUMENT,
         "render rejects scale 0");

  *out = image;
}

static void
test_paint_and_undo (GlimsImageID image)
{
  GlimsItemID layer = first_layer (image);
  int32_t     before = undo_depth (image);
  int32_t     width, height;
  uint8_t    *pixels;
  int         events_before = atomic_load (&projection_events);
  double      start = now_ms ();

  paint_line (image, layer, 8, 56, 12);

  CHECK (undo_depth (image) == before + 1, "one stroke adds exactly one undo step (%d -> %d)", before, undo_depth (image));

  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 12)[0] < 64 && pixel_at (pixels, width, 32, 40)[0] == 255,
         "stroke paints black on the line and leaves the rest white");
  free (pixels);

  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "undo");
  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 12)[0] == 255, "undo restores white");
  free (pixels);

  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK, "redo");
  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 12)[0] < 64, "redo repaints the stroke");
  free (pixels);

  CHECK (atomic_load (&projection_events) > events_before, "projection-changed events arrived (%d)",
         atomic_load (&projection_events) - events_before);
  printf ("      stroke, undo, redo and renders took %.0f ms\n", now_ms () - start);
}

static void
test_filters (GlimsImageID image)
{
  GlimsItemID    layer = first_layer (image);
  GlimsFilterID  filter = 0;
  GlimsLayerInfo row;
  int32_t        count, before = undo_depth (image), width, height;
  uint8_t       *pixels;
  char          *error = NULL;

  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK,
         "gaussian blur session opens%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  CHECK (api->filter_set_double (engine, filter, "std-dev-x", 4.0) == GLIMS_STATUS_OK &&
         api->filter_set_double (engine, filter, "std-dev-y", 4.0) == GLIMS_STATUS_OK,
         "filter properties set");
  CHECK (api->filter_set_double (engine, filter, "no-such-property", 1.0) == GLIMS_STATUS_NOT_FOUND,
         "unknown filter property is reported");

  pixels = render_all (image, &width, &height);
  CHECK (pixels && pixel_at (pixels, width, 32, 18)[0] < 255 && pixel_at (pixels, width, 32, 18)[0] > 0,
         "preview blurs the stroke edge (value %d at 6 px off the line)", pixels ? pixel_at (pixels, width, 32, 18)[0] : -1);
  free (pixels);
  CHECK (undo_depth (image) == before, "an open preview adds no undo step");

  CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "filter commits%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  CHECK (undo_depth (image) == before + 1, "commit adds exactly one undo step (%d -> %d)", before, undo_depth (image));
  CHECK (api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK && row.filter_count == 1,
         "the layer carries one non-destructive filter");

  before = undo_depth (image);
  CHECK (api->filter_begin (engine, image, layer, "gegl:invert-gamma", &filter, NULL) == GLIMS_STATUS_OK &&
         api->filter_abort (engine, filter) == GLIMS_STATUS_OK,
         "a second session opens and aborts");
  CHECK (undo_depth (image) == before, "abort adds no undo step");
  CHECK (api->image_layers (engine, image, &row, 1, &count) == GLIMS_STATUS_OK && row.filter_count == 1,
         "abort leaves the filter stack unchanged");

  CHECK (api->filter_begin (engine, image, layer, "gegl:no-such-op", &filter, NULL) == GLIMS_STATUS_INVALID_ARGUMENT,
         "unknown operation is rejected");
}

static void
test_save_reopen_export (GlimsImageID image, const char *work)
{
  char           xcf[1024], png[1024];
  GlimsImageID   reopened = 0, imported = 0;
  int32_t        w1, h1, w2, h2, w3, h3;
  uint8_t       *original, *again, *from_png;
  GlimsLayerInfo row;
  int32_t        count;
  char          *error = NULL;
  double         start;

  snprintf (xcf, sizeof xcf, "%s/roundtrip.xcf", work);
  snprintf (png, sizeof png, "%s/export.png", work);

  CHECK (api->image_save (engine, image, xcf, &error) == GLIMS_STATUS_OK && file_size (xcf) > 0,
         "save XCF%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  original = render_all (image, &w1, &h1);

  CHECK (api->image_open (engine, xcf, &reopened, &error) == GLIMS_STATUS_OK, "reopen XCF%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;
  again = render_all (reopened, &w2, &h2);
  CHECK (original && again && w1 == w2 && h1 == h2 &&
         count_differences (original, again, (size_t) w1 * h1 * 4) == 0,
         "reopened XCF renders identical pixels");
  CHECK (api->image_layers (engine, reopened, &row, 1, &count) == GLIMS_STATUS_OK && count == 1 &&
         row.filter_count == 1 && strcmp (row.name, "Background") == 0,
         "reopened XCF keeps the layer and its non-destructive filter");

  start = now_ms ();
  CHECK (api->image_export (engine, image, png, &error) == GLIMS_STATUS_OK && file_size (png) > 8,
         "export PNG through the file plug-in (%.0f ms)%s%s", now_ms () - start,
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  error = NULL;

  CHECK (api->image_open (engine, png, &imported, &error) == GLIMS_STATUS_OK,
         "import the PNG through the file plug-in%s%s", error ? ": " : "", error ? error : "");
  api->free_string (error);
  from_png = render_all (imported, &w3, &h3);
  CHECK (original && from_png && w1 == w3 && h1 == h3 &&
         count_differences (original, from_png, (size_t) w1 * h1 * 4) == 0,
         "the exported PNG holds the composited pixels (%d differ)",
         original && from_png ? count_differences (original, from_png, (size_t) w1 * h1 * 4) : -1);

  free (original);
  free (again);
  free (from_png);
  api->image_close (engine, reopened);
  api->image_close (engine, imported);
}

int
main (int argc, char **argv)
{
  GlimsEngineGetAPIFunction get_api;
  GlimsEngineConfig         config = { 0 };
  char                      user_dir[1024], cache_dir[1024];
  char                     *error = NULL;
  void                     *library;
  GlimsImageID              image = 0;
  double                    start;

  if (argc != 4)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR FIXTURES_DIR\n", argv[0]);
      return 2;
    }

  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      return 1;
    }
  get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  CHECK (api && api->api_version == GLIMS_ENGINE_API_VERSION && api->struct_size >= sizeof (GlimsEngineAPI),
         "library serves facade version %u", GLIMS_ENGINE_API_VERSION);
  if (! api)
    return 1;
  CHECK (get_api (GLIMS_ENGINE_API_VERSION + 1) == NULL, "library refuses an unknown facade version");

  snprintf (user_dir, sizeof user_dir, "%s/user", argv[2]);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", argv[2]);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = on_event;

  start = now_ms ();
  CHECK (api->start (&config, &engine, &error) == GLIMS_STATUS_OK, "engine starts%s%s",
         error ? ": " : "", error ? error : "");
  api->free_string (error);
  if (! engine)
    return 1;
  printf ("      engine %s started in %.0f ms\n", api->engine_version (engine), now_ms () - start);
  CHECK (api->start (&config, &engine, NULL) == GLIMS_STATUS_FAILED, "a second start is refused");

  test_new_image_and_render (&image);
  if (image)
    {
      test_paint_and_undo (image);
      test_filters (image);
      test_save_reopen_export (image, argv[2]);
      CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK, "close image");
      CHECK (api->image_close (engine, image) == GLIMS_STATUS_NOT_FOUND, "closing twice is reported");
    }
  CHECK (atomic_load (&undo_events) > 0, "undo-changed events arrived (%d)", atomic_load (&undo_events));

  start = now_ms ();
  api->stop (engine);
  printf ("      engine stopped in %.0f ms\n", now_ms () - start);

  printf ("%s: %d failure%s\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}
