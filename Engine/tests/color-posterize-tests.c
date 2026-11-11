/*
 * Conformance tests for the adapter's owned glims:posterize operation,
 * through the public facade header only.
 *
 *   glims-color-posterize-tests LIBRARY WORK_DIR
 *
 * The adapter is loaded with dlopen() exactly as the app does: nothing is
 * linked against it and no Engine/ private header is included. The pixel
 * oracle is literal arithmetic in this file — no GEGL or engine code
 * computes the expected output. One line per check; the exit status is
 * non-zero when any check failed.
 */
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "glims_engine.h"

#define OP "glims:posterize"
#define IMG_W 4
#define IMG_H 2

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   checks, failures;

#define CHECK(condition, ...)                 \
  do {                                        \
    checks++;                                 \
    if (condition) printf ("ok    ");        \
    else { printf ("FAIL  "); failures++; }   \
    printf (__VA_ARGS__);                     \
    printf ("\n");                            \
    fflush (stdout);                          \
  } while (0)

/* Literal oracle: one channel value 0..255 posterized to `levels` levels,
 * computed here from first principles — quantize v/255 onto levels-1
 * steps, back to a byte. Alpha is never part of it: the operation must
 * leave alpha untouched, so no alpha oracle exists. */
static int
posterize_u8 (int v, int levels)
{
  double steps = levels - 1.0;
  return (int) lrint ((lrint ((v / 255.0) * steps) / steps) * 255.0);
}

static GlimsItemID
only_layer (GlimsImageID image)
{
  GlimsLayerInfo row;
  int32_t        count = 0;

  if (api->image_layers (engine, image, &row, 1, &count) != GLIMS_STATUS_OK ||
      count != 1)
    return 0;
  return row.id;
}

static bool
pixel_rows (GlimsImageID image, bool merged, uint8_t out[IMG_W * IMG_H * 4])
{
  GlimsPixelBuffer buffer;
  bool             ok = false;

  memset (&buffer, 0, sizeof buffer);
  if (api->image_copy_pixels (engine, image, merged, &buffer, NULL) != GLIMS_STATUS_OK)
    return false;
  if (buffer.pixels && buffer.byte_count == IMG_W * IMG_H * 4)
    {
      memcpy (out, buffer.pixels, IMG_W * IMG_H * 4);
      ok = true;
    }
  api->free_pixels (buffer.pixels);
  return ok;
}

/* The literal oracle on the composite: every color channel is within one
 * byte of the arithmetic above (the engine's float->u8 boundary rounding
 * can differ from lrint's half-even by one at exact .5 steps), and alpha
 * must be the input's bytes exactly. The merged copy of this single-layer
 * image reads the composited pixels with no premultiply loss — the
 * unfiltered source comes back byte-identical. */
static bool
composite_matches_oracle (const uint8_t in[IMG_W * IMG_H * 4],
                          const uint8_t got[IMG_W * IMG_H * 4],
                          int levels)
{
  int i, c;

  for (i = 0; i < IMG_W * IMG_H; i++)
    {
      for (c = 0; c < 3; c++)
        if (abs (got[4 * i + c] - posterize_u8 (in[4 * i + c], levels)) > 1)
          return false;
      if (got[4 * i + 3] != in[4 * i + 3])
        return false;
    }
  return true;
}

/* The fixture: row one is partially transparent — alphas that
 * gimp:posterize destroys at 3 levels (32 -> 0, 96/160 -> 128,
 * 224 -> 255) — row two is the same colors fully opaque, where the
 * composite shows the posterized color without premultiply loss. */
static const uint8_t FIXTURE[IMG_W * IMG_H * 4] =
  { 77, 140, 209, 32,  77, 140, 209, 96,  77, 140, 209, 160,  77, 140, 209, 224,
    77, 140, 209, 255, 90, 180, 60,  255, 200, 30,  120, 255, 11, 250, 99, 255 };

static GlimsImageID
make_image (void)
{
  GlimsImageID image = 0;

  if (api->image_from_pixels (engine, IMG_W, IMG_H, FIXTURE, sizeof FIXTURE,
                              &image, NULL) != GLIMS_STATUS_OK)
    return 0;
  return image;
}

static void
dump_rows (const uint8_t got[IMG_W * IMG_H * 4])
{
  int i;

  printf ("      got");
  for (i = 0; i < IMG_W * IMG_H; i++)
    printf (" (%u,%u,%u,%u)", got[4 * i], got[4 * i + 1], got[4 * i + 2], got[4 * i + 3]);
  printf ("\n");
}

static void
test_discovery (void)
{
  GlimsOperationInfo   ops[512];
  GlimsFilterProperty  props[32];
  int32_t              count = 0, pcount = 0, i;
  bool                 found = false, levels_found = false;

  CHECK (api->filter_operations (engine, ops, 512, &count) == GLIMS_STATUS_OK && count > 0,
         "filter_operations lists %d operations", count > 512 ? 512 : count);
  for (i = 0; i < count && i < 512; i++)
    if (! strcmp (ops[i].name, OP))
      {
        found = true;
        CHECK (strstr (ops[i].title, "Posterize") != NULL,
               "glims:posterize title is \"%s\"", ops[i].title);
        CHECK (strstr (ops[i].categories, "color") != NULL,
               "glims:posterize categories are \"%s\"", ops[i].categories);
        CHECK (ops[i].support == GLIMS_FILTER_OP_SUPPORTED,
               "glims:posterize support is %u (SUPPORTED)", ops[i].support);
      }
  if (! found)
    for (i = 0; i < count && i < 512; i++)
      if (strstr (ops[i].name, "posterize") || strstr (ops[i].name, "glims"))
        printf ("      listed op: %s\n", ops[i].name);
  CHECK (found, "glims:posterize appears in the operation list");

  CHECK (api->filter_operation_properties (engine, OP, props, 32, &pcount) == GLIMS_STATUS_OK &&
         pcount > 0, "glims:posterize lists %d properties", pcount);
  for (i = 0; i < pcount && i < 32; i++)
    if (! strcmp (props[i].name, "levels"))
      {
        levels_found = true;
        CHECK (props[i].kind == GLIMS_FILTER_VALUE_INTEGER,
               "levels kind is %u (INTEGER)", props[i].kind);
        CHECK (props[i].min == 2 && props[i].max == 256,
               "levels bounds are %g..%g", props[i].min, props[i].max);
        CHECK (props[i].default_number == 3,
               "levels default is %g", props[i].default_number);
      }
  CHECK (levels_found, "glims:posterize exposes a levels property");
}

static void
test_filter_path (const char *work_dir)
{
  uint8_t       out[IMG_W * IMG_H * 4] = { 0 };
  GlimsImageID  image;
  GlimsItemID   layer;
  GlimsFilterID filter = 0;
  GlimsFilterValue value = { 0 };
  char         *error = NULL;
  char          path[4096];
  bool          ok;

  image = make_image ();
  CHECK (image != 0, "fixture image created");
  if (! image) return;
  layer = only_layer (image);
  CHECK (layer != 0, "fixture has one layer");
  if (! layer) { api->image_close (engine, image); return; }

  /* Abort: an open session that is thrown away changes nothing. */
  CHECK (api->filter_begin (engine, image, layer, OP, &filter, &error) == GLIMS_STATUS_OK &&
         filter != 0, "filter_begin opens a glims:posterize session");
  if (filter)
    {
      value.kind = GLIMS_FILTER_VALUE_INTEGER; value.integer = 3;
      CHECK (api->filter_set_property (engine, filter, "levels", &value) == GLIMS_STATUS_OK,
             "levels accepts 3 on the live session");
      CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "filter_abort succeeds");
    }
  memset (out, 0, sizeof out);
  ok = pixel_rows (image, false, out);
  CHECK (ok && ! memcmp (out, FIXTURE, sizeof FIXTURE),
         "the aborted session leaves every stored source byte untouched");

  /* Commit at 5 levels: literal RGB oracle, exact alpha. */
  filter = 0;
  CHECK (api->filter_begin (engine, image, layer, OP, &filter, NULL) == GLIMS_STATUS_OK &&
         filter != 0, "filter_begin reopens after the abort");
  if (filter)
    {
      memset (&value, 0, sizeof value);
      CHECK (api->filter_get_property (engine, filter, "levels", &value) == GLIMS_STATUS_OK &&
             value.kind == GLIMS_FILTER_VALUE_INTEGER && value.integer == 3,
             "levels reads back the default 3 (got %lld)", (long long) value.integer);
      value.kind = GLIMS_FILTER_VALUE_INTEGER; value.integer = 5;
      CHECK (api->filter_set_property (engine, filter, "levels", &value) == GLIMS_STATUS_OK,
             "levels accepts 5");
      CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK,
             "filter_commit succeeds%s%s", error ? ": " : "", error ? error : "");
      if (error) { api->free_string (error); error = NULL; }
    }
  memset (out, 0, sizeof out);
  ok = pixel_rows (image, true, out);
  CHECK (ok && composite_matches_oracle (FIXTURE, out, 5),
         "posterize at 5 levels: literal RGB oracle matches, alpha is exact");
  if (ok && ! composite_matches_oracle (FIXTURE, out, 5))
    dump_rows (out);
  /* The stored source under the non-destructive effect stays the input. */
  memset (out, 0, sizeof out);
  ok = pixel_rows (image, false, out);
  CHECK (ok && ! memcmp (out, FIXTURE, sizeof FIXTURE),
         "the committed effect keeps the stored source bytes unchanged");

  /* One undo restores the source; one redo reapplies the effect. */
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "image_undo succeeds");
  memset (out, 0, sizeof out);
  ok = pixel_rows (image, true, out);
  CHECK (ok && ! memcmp (out, FIXTURE, sizeof FIXTURE),
         "undo restores the unfiltered composite byte-for-byte");
  if (ok && memcmp (out, FIXTURE, sizeof FIXTURE)) dump_rows (out);
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK, "image_redo succeeds");
  memset (out, 0, sizeof out);
  ok = pixel_rows (image, true, out);
  CHECK (ok && composite_matches_oracle (FIXTURE, out, 5),
         "redo reproduces the 5-level result");

  /* XCF round trip: the committed effect keeps operation and levels,
   * and stays editable. */
  snprintf (path, sizeof path, "%s/posterize-roundtrip.xcf", work_dir);
  CHECK (api->image_save (engine, image, path, &error) == GLIMS_STATUS_OK,
         "image_save writes the XCF%s%s", error ? ": " : "", error ? error : "");
  if (error) { api->free_string (error); error = NULL; }
  CHECK (api->image_close (engine, image) == GLIMS_STATUS_OK, "image_close succeeds");

  {
    GlimsImageID    reopened = 0;
    GlimsItemID     rlayer;
    GlimsEffectInfo effects[4];
    int32_t         ecount = 0;
    GlimsFilterID   efilter = 0;

    CHECK (api->image_open (engine, path, &reopened, &error) == GLIMS_STATUS_OK &&
           reopened != 0, "image_open reopens the XCF%s%s",
           error ? ": " : "", error ? error : "");
    if (error) { api->free_string (error); error = NULL; }
    if (! reopened) return;
    rlayer = only_layer (reopened);
    CHECK (rlayer != 0, "reopened image has one layer");
    memset (effects, 0, sizeof effects);
    CHECK (api->drawable_effects (engine, reopened, rlayer, effects, 4, &ecount) == GLIMS_STATUS_OK &&
           ecount == 1 && ! strcmp (effects[0].operation, OP),
           "reopen keeps one %s effect (count %d, first is %s)", OP, ecount,
           ecount > 0 ? effects[0].operation : "-");
    if (ecount == 1)
      {
        memset (&value, 0, sizeof value);
        CHECK (api->filter_edit_begin (engine, reopened, rlayer, effects[0].id,
                                     &efilter, NULL) == GLIMS_STATUS_OK && efilter != 0,
               "filter_edit_begin edits the reloaded effect");
        if (efilter)
          {
            CHECK (api->filter_get_property (engine, efilter, "levels", &value) == GLIMS_STATUS_OK &&
                   value.kind == GLIMS_FILTER_VALUE_INTEGER && value.integer == 5,
                   "the reloaded effect reads levels=5 (got %lld)", (long long) value.integer);
            value.kind = GLIMS_FILTER_VALUE_INTEGER; value.integer = 7;
            CHECK (api->filter_set_property (engine, efilter, "levels", &value) == GLIMS_STATUS_OK &&
                   api->filter_commit (engine, efilter, NULL) == GLIMS_STATUS_OK,
                   "the reloaded effect accepts and commits levels=7");
            memset (out, 0, sizeof out);
            ok = pixel_rows (reopened, true, out);
            CHECK (ok && composite_matches_oracle (FIXTURE, out, 7),
                   "re-edit produces the literal 7-level result with exact alpha");
            if (ok && ! composite_matches_oracle (FIXTURE, out, 7))
              dump_rows (out);
          }
      }
    api->image_close (engine, reopened);
  }
}

static void
test_adjustment_path (void)
{
  uint8_t       out[IMG_W * IMG_H * 4] = { 0 };
  GlimsImageID  image;
  GlimsItemID   layer = 0;
  GlimsEffectID effect = 0;
  GlimsFilterID filter = 0;
  GlimsFilterValue value = { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 3 };
  char         *error = NULL;
  bool          ok;

  image = make_image ();
  CHECK (image != 0, "adjustment fixture created");
  if (! image) return;

  CHECK (api->adjustment_layer_new (engine, image, 0, 0, OP, "Posterize",
                                    &layer, &effect, &error) == GLIMS_STATUS_OK &&
         layer > 0 && effect > 0,
         "adjustment_layer_new creates a glims:posterize group%s%s",
         error ? ": " : "", error ? error : "");
  if (error) { api->free_string (error); error = NULL; }
  if (! effect) { api->image_close (engine, image); return; }

  CHECK (api->filter_edit_begin (engine, image, layer, effect, &filter, NULL) == GLIMS_STATUS_OK &&
         filter != 0, "filter_edit_begin edits the adjustment effect");
  if (filter)
    {
      CHECK (api->filter_set_property (engine, filter, "levels", &value) == GLIMS_STATUS_OK,
             "levels accepts 3 on the adjustment effect");
      CHECK (api->filter_commit (engine, filter, NULL) == GLIMS_STATUS_OK,
             "the adjustment effect commits");
    }
  memset (out, 0, sizeof out);
  ok = pixel_rows (image, true, out);
  CHECK (ok && composite_matches_oracle (FIXTURE, out, 3),
         "adjustment group: literal RGB oracle matches, alpha is exact");
  if (ok && ! composite_matches_oracle (FIXTURE, out, 3))
    dump_rows (out);
  api->image_close (engine, image);
}

int
main (int argc, char **argv)
{
  void                      *library;
  GlimsEngineGetAPIFunction  get_api;
  GlimsEngineConfig          config = { 0 };
  char                      *error = NULL;

  if (argc != 3)
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR\n", argv[0]);
      return 2;
    }
  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      return 2;
    }
  get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (! api)
    {
      fprintf (stderr, "no facade for API version %u\n", GLIMS_ENGINE_API_VERSION);
      return 2;
    }

  config.struct_size     = sizeof config;
  config.user_directory  = argv[2];
  config.cache_directory = argv[2];
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start: %s\n", error ? error : "failed");
      return 1;
    }

  test_discovery ();
  test_filter_path (argv[2]);
  test_adjustment_path ();

  api->stop (engine);
  printf ("%d checks, %d failure(s)\n", checks, failures);
  return failures ? 1 : 0;
}
