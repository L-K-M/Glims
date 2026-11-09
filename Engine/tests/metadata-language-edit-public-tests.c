/* Public-facade-only slot141 mutation, Undo and refusal checks. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int failures;
#define CHECK(c, text) do { printf("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); fflush(stdout); } while (0)
static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }

static int title_is (GlimsImageID image, const char *french)
{
  GlimsMetadataLanguageValue *values = NULL;
  int32_t count = 0, i;
  int seen = 0;
  char *error = NULL;
  GlimsStatus status = api->image_metadata_languages (engine, image, "Xmp.dc.title", &values, &count, &error);
  for (i = 0; status == GLIMS_STATUS_OK && values && i < count; i++) {
    if (!strcmp (values[i].language, "x-default") && !strcmp (values[i].text, "Hello")) seen |= 1;
    if (!strcmp (values[i].language, "fr") && !strcmp (values[i].text, french)) seen |= 2;
    if (!strcmp (values[i].language, "de") && !strcmp (values[i].text, "Hallo")) seen |= 4;
  }
  api->metadata_languages_free (values);
  clear_error (&error);
  return status == GLIMS_STATUS_OK && count == 3 && seen == 7;
}

static int rights_is (GlimsImageID image)
{
  GlimsMetadataLanguageValue *values = NULL;
  int32_t count = 0, i;
  int seen = 0;
  char *error = NULL;
  GlimsStatus status = api->image_metadata_languages (engine, image, "Xmp.dc.rights", &values, &count, &error);
  for (i = 0; status == GLIMS_STATUS_OK && values && i < count; i++) {
    if (!strcmp (values[i].language, "x-default") && !strcmp (values[i].text, "Default rights")) seen |= 1;
    if (!strcmp (values[i].language, "ja") && !strcmp (values[i].text, "権利")) seen |= 2;
  }
  api->metadata_languages_free (values); clear_error (&error);
  return status == GLIMS_STATUS_OK && count == 2 && seen == 3;
}

static int ordinary_is (GlimsImageID image, const char *tag, const char *expected)
{
  char **values = NULL, *error = NULL;
  int32_t count = 0;
  GlimsStatus status = api->image_metadata_values (engine, image, tag, &values, &count, &error);
  int valid = status == GLIMS_STATUS_OK && count == 1 && values && !strcmp (values[0], expected);
  api->free_metadata_strings (values); clear_error (&error);
  return valid;
}

static void refusal (GlimsImageID image, const char *root, const char *language, const char *text, GlimsStatus expected)
{
  GlimsImageInfo before = {0}, after = {0};
  GlimsUndoInfo u_before = {0}, u_after = {0};
  char *error = NULL;
  api->image_info (engine, image, &before); api->image_undo_info (engine, image, &u_before);
  CHECK (api->image_metadata_edit_language (engine, image, root, language, text, &error) == expected,
         "a refused request reports its expected status");
  clear_error (&error);
  api->image_info (engine, image, &after); api->image_undo_info (engine, image, &u_after);
  CHECK (!memcmp (&before, &after, sizeof before) && !memcmp (&u_before, &u_after, sizeof u_before) && title_is (image, "Bonjour 山") && rights_is (image),
         "refusal preserves all title languages, image facts, dirty state and history");
}

int main (int argc, char **argv)
{
  void *library;
  const GlimsEngineAPI *(*get_api) (uint32_t);
  GlimsEngineConfig config = { .struct_size = sizeof config };
  GlimsImageID image = 0, reopened = 0;
  GlimsImageInfo before = {0}, after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  char user[4096], cache[4096], copy[4096], *error = NULL;
  uint8_t pixel_before[4], pixel_after[4];
  if (argc != 4) return 2;
  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf (stderr, "%s\n", dlerror ()); return 2; }
  *(void **) (&get_api) = dlsym (library, "glims_engine_get_api");
  if (!get_api || !(api = get_api (1)) || api->struct_size < sizeof *api || !api->image_metadata_edit_language) return 2;
  CHECK (api->api_version == 1, "API1 serves the additive141-slot facade");
  snprintf (user, sizeof user, "%s/user", argv[3]); snprintf (cache, sizeof cache, "%s/cache", argv[3]);
  snprintf (copy, sizeof copy, "%s/changed.xcf", argv[3]);
  config.user_directory = user; config.cache_directory = cache;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) return 2;
  CHECK (api->image_open (engine, argv[2], &image, &error) == GLIMS_STATUS_OK, "opens the independent known-map fixture");
  clear_error (&error); if (!image) goto done;
  CHECK (title_is (image, "Salut") && rights_is (image), "the original complete title map matches its independent oracle");
  api->image_info (engine, image, &before); api->image_undo_info (engine, image, &undo_before);
  CHECK (api->image_render (engine, image, 1, (GlimsRect) {0, 0, 1, 1}, pixel_before, 4) == GLIMS_STATUS_OK,
         "captures a native pixel before the metadata edit");
  CHECK (api->image_metadata_edit_language (engine, image, "Xmp.dc.title", "fr", "Bonjour 山", &error) == GLIMS_STATUS_OK,
         "changes exactly one existing language through the public writer");
  clear_error (&error);
  CHECK (title_is (image, "Bonjour 山") && rights_is (image), "the changed title preserves default and German text");
  CHECK (ordinary_is (image, "Exif.Image.Artist", "Fixture Artist") && ordinary_is (image, "Iptc.Application2.Caption", "Fixture caption"),
         "unrelated EXIF and IPTC values survive the public mutation");
  api->image_info (engine, image, &after); api->image_undo_info (engine, image, &undo_after);
  CHECK (undo_after.undo_count == undo_before.undo_count + 1 && after.dirty,
         "the language edit creates exactly one Undo step and marks the image dirty");
  CHECK (api->image_render (engine, image, 1, (GlimsRect) {0, 0, 1, 1}, pixel_after, 4) == GLIMS_STATUS_OK &&
         !memcmp (pixel_before, pixel_after, 4) && before.width == after.width && before.height == after.height,
         "metadata editing preserves native pixels and dimensions");
  CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK && title_is (image, "Salut"),
         "one Undo restores the original complete language map");
  CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK && title_is (image, "Bonjour 山") && rights_is (image),
         "one Redo restores the complete edited map");
  refusal (image, "Xmp.dc.title", "fr", "Bonjour 山", GLIMS_STATUS_OK);
  refusal (image, "Xmp.dc.title", "zz", "Missing", GLIMS_STATUS_NOT_FOUND);
  refusal (image, "Xmp.dc.title", "FR", "Wrong spelling", GLIMS_STATUS_NOT_FOUND);
  refusal (image, "Xmp.dc.format", "fr", "Wrong kind", GLIMS_STATUS_UNSUPPORTED);
  refusal (image, "Xmp.dc.title", "fr", "", GLIMS_STATUS_INVALID_ARGUMENT);
  refusal (image, "Xmp.dc.title", NULL, "Missing key", GLIMS_STATUS_INVALID_ARGUMENT);
  refusal (image, "Xmp.dc.title", "fr", "\xff", GLIMS_STATUS_INVALID_ARGUMENT);
  {
    GlimsLayerInfo layer = {0}; int32_t count = 0;
    GlimsStrokeID stroke = 0; GlimsFilterID filter = 0;
    GlimsBrushSettings brush = { .struct_size = sizeof brush, .size = 3, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
    GlimsStrokePoint point = { .x = 10, .y = 10, .pressure = 1 };
    CHECK (api->image_layers (engine, image, &layer, 1, &count) == GLIMS_STATUS_OK && count > 0, "finds a real stroke/filter target");
    CHECK (api->stroke_begin (engine, image, layer.id, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK, "starts a native busy stroke");
    clear_error (&error);
    if (stroke) {
      refusal (image, "Xmp.dc.title", "fr", "Busy change", GLIMS_STATUS_BUSY);
      refusal (image, "Xmp.dc.title", "fr", "Bonjour 山", GLIMS_STATUS_OK);
      api->stroke_end (engine, stroke);
    }
    CHECK (api->filter_begin (engine, image, layer.id, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK, "starts a native filter preview");
    clear_error (&error);
    if (filter) {
      refusal (image, "Xmp.dc.title", "fr", "Busy change", GLIMS_STATUS_BUSY);
      refusal (image, "Xmp.dc.title", "fr", "Bonjour 山", GLIMS_STATUS_OK);
      api->filter_abort (engine, filter);
    }
  }
  CHECK (api->image_save_copy (engine, image, copy, &error) == GLIMS_STATUS_OK, "saves an independent native copy of the edited metadata");
  clear_error (&error);
  CHECK (api->image_open (engine, copy, &reopened, &error) == GLIMS_STATUS_OK && title_is (reopened, "Bonjour 山") && rights_is (reopened),
         "the complete edited language map survives native save/reopen");
  clear_error (&error);
  api->image_close (engine, image);
  CHECK (api->image_metadata_edit_language (engine, image, "Xmp.dc.title", "fr", "Late", &error) == GLIMS_STATUS_NOT_FOUND,
         "a closed image refuses a late write without crashing");
  clear_error (&error); image = 0;
done:
  if (reopened) api->image_close (engine, reopened);
  if (image) api->image_close (engine, image);
  api->stop (engine); dlclose (library);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}
