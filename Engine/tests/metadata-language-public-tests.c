/* Public-header-only ownership and read conformance. The separately built
 * Core fixture generator supplies known XCF maps; no private types or setter
 * backdoor are available to this process. Usage: LIBRARY FIXTURE WORK_DIR. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int failures;
#define CHECK(c, text) do { printf("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); fflush(stdout); } while (0)

static void
clear_error (char **error)
{
  if (*error) api->free_string (*error);
  *error = NULL;
}

static int
has_pair (GlimsMetadataLanguageValue *pairs, int32_t count, const char *language, const char *text)
{
  int32_t i;
  for (i = 0; pairs && i < count; i++)
    if (pairs[i].language && pairs[i].text && !strcmp (pairs[i].language, language) && !strcmp (pairs[i].text, text))
      return 1;
  return 0;
}

static void
refuses (GlimsImageID image, const char *tag, GlimsStatus expected)
{
  GlimsMetadataLanguageValue *pairs = (void *) (uintptr_t) 1;
  int32_t count = 91;
  char *error = NULL;
  GlimsStatus status = api->image_metadata_languages (engine, image, tag, &pairs, &count, &error);
  CHECK (status == expected && pairs == NULL && count == 0, "refusal clears both outputs");
  clear_error (&error);
}

static void
check_map (GlimsImageID image)
{
  GlimsMetadataLanguageValue *pairs = NULL;
  int32_t count = 0;
  char *error = NULL;
  GlimsStatus status = api->image_metadata_languages (engine, image, "Xmp.dc.title", &pairs, &count, &error);
  CHECK (status == GLIMS_STATUS_OK && count == 3 &&
         has_pair (pairs, count, "x-default", "Hello") && has_pair (pairs, count, "fr", "Salut") &&
         has_pair (pairs, count, "de", "Hallo"), "known title map returns exact language/text pairs");
  CHECK (pairs && count == 3 && !pairs[count].language && !pairs[count].text, "count is followed by an all-NULL sentinel");
  api->metadata_languages_free (pairs);
  clear_error (&error);
}

int
main (int argc, char **argv)
{
  void *library;
  const GlimsEngineAPI *(*get_api)(uint32_t);
  GlimsEngineConfig config = {0};
  GlimsImageID image = 0, empty = 0;
  GlimsImageInfo before = {0}, after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  GlimsMetadataLanguageValue *retained = NULL;
  int32_t retained_count = 0;
  char user[4096], cache[4096], copy[4096], *error = NULL;
  if (argc != 4) return 2;
  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf (stderr, "%s\n", dlerror ()); return 2; }
  *(void **) (&get_api) = dlsym (library, "glims_engine_get_api");
  if (!get_api || !(api = get_api (GLIMS_ENGINE_API_VERSION)) || api->struct_size < sizeof *api) return 2;
  CHECK (api->api_version == 1 && api->image_metadata_languages && api->metadata_languages_free,
         "API1 serves the complete140-slot footer");
  {
    GlimsMetadataLanguageValue *out = (void *) (uintptr_t) 1;
    int32_t count = 71;
    CHECK (api->image_metadata_languages (NULL, 1, "Xmp.dc.title", &out, &count, &error) == GLIMS_STATUS_NOT_RUNNING &&
           out == NULL && count == 0, "NULL engine clears outputs before dispatch");
    clear_error (&error);
  }
  snprintf (user, sizeof user, "%s/user", argv[3]);
  snprintf (cache, sizeof cache, "%s/cache", argv[3]);
  snprintf (copy, sizeof copy, "%s/roundtrip.xcf", argv[3]);
  config.struct_size = sizeof config;
  config.user_directory = user;
  config.cache_directory = cache;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "start: %s\n", error ? error : "failed"); clear_error (&error); dlclose (library); return 2;
  }
  CHECK (api->image_open (engine, argv[2], &image, &error) == GLIMS_STATUS_OK, "opens the independently seeded native fixture");
  clear_error (&error);
  if (!image) goto done;
  api->image_info (engine, image, &before);
  api->image_undo_info (engine, image, &undo_before);
  check_map (image);
  {
    GlimsMetadataLanguageValue *pairs = NULL;
    int32_t count = 0;
    CHECK (api->image_metadata_languages (engine, image, "Xmp.dc.rights", &pairs, &count, &error) == GLIMS_STATUS_OK && count == 2 &&
           has_pair (pairs, count, "x-default", "Default rights") && has_pair (pairs, count, "ja", "権利"),
           "a second map preserves Unicode text and explicit languages");
    api->metadata_languages_free (pairs);
    clear_error (&error);
  }
  refuses (image, NULL, GLIMS_STATUS_INVALID_ARGUMENT);
  refuses (image, "", GLIMS_STATUS_INVALID_ARGUMENT);
  refuses (image, "Xmp.dc.format", GLIMS_STATUS_UNSUPPORTED);
  refuses (image, "Xmp.dc.description", GLIMS_STATUS_NOT_FOUND);
  refuses (image, "Xmp.nosuchgroup.tag", GLIMS_STATUS_NOT_FOUND);
  refuses (-1, "Xmp.dc.title", GLIMS_STATUS_NOT_FOUND);
  {
    GlimsMetadataLanguageValue *pairs = (void *) (uintptr_t) 1;
    int32_t count = 91;
    CHECK (api->image_metadata_languages (engine, image, "Xmp.dc.title", NULL, &count, &error) == GLIMS_STATUS_INVALID_ARGUMENT && count == 0,
           "NULL array output refuses and clears the count");
    clear_error (&error);
    CHECK (api->image_metadata_languages (engine, image, "Xmp.dc.title", &pairs, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT && !pairs,
           "NULL count refuses and clears the array");
    clear_error (&error);
  }
  api->image_info (engine, image, &after);
  api->image_undo_info (engine, image, &undo_after);
  CHECK (!memcmp (&before, &after, sizeof before) && !memcmp (&undo_before, &undo_after, sizeof undo_before),
         "successful and refused reads preserve image facts, dirty state and native history");
  {
    GlimsLayerInfo layer = {0};
    int32_t count = 0;
    GlimsStrokeID stroke = 0;
    GlimsFilterID filter = 0;
    GlimsBrushSettings brush = { .struct_size = sizeof brush, .size = 3, .opacity = 1,
                                .hardness = -1, .rate = -1, .flow = -1, .exposure = -1 };
    GlimsStrokePoint point = { .x = 10, .y = 10, .pressure = 1 };
    CHECK (api->image_layers (engine, image, &layer, 1, &count) == GLIMS_STATUS_OK && count > 0,
           "fixture exposes a real drawable for read-during-edit checks");
    CHECK (api->stroke_begin (engine, image, layer.id, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK,
           "starts a native stroke");
    clear_error (&error);
    if (stroke) { check_map (image); api->stroke_end (engine, stroke); }
    CHECK (api->filter_begin (engine, image, layer.id, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK,
           "opens a real filter preview");
    clear_error (&error);
    if (filter) { check_map (image); api->filter_abort (engine, filter); }
  }
  CHECK (api->image_metadata_languages (engine, image, "Xmp.dc.title", &retained, &retained_count, &error) == GLIMS_STATUS_OK,
         "retains one independently owned result");
  clear_error (&error);
  CHECK (api->image_save_copy (engine, image, copy, &error) == GLIMS_STATUS_OK, "saves a native copy after reads");
  clear_error (&error);
  api->image_close (engine, image);
  image = 0;
  CHECK (has_pair (retained, retained_count, "fr", "Salut"), "owned result survives image closure");
  CHECK (api->image_open (engine, copy, &image, &error) == GLIMS_STATUS_OK, "reopens native serialization");
  clear_error (&error);
  if (image) check_map (image);
  if (api->image_new (engine, 8, 8, &empty, &error) == GLIMS_STATUS_OK) refuses (empty, "Xmp.dc.title", GLIMS_STATUS_NOT_FOUND);
  else CHECK (0, "creates an image without metadata");
  clear_error (&error);
done:
  if (empty) api->image_close (engine, empty);
  if (image) api->image_close (engine, image);
  api->stop (engine);
  CHECK (has_pair (retained, retained_count, "de", "Hallo"), "owned strings survive engine shutdown");
  api->metadata_languages_free (retained);
  api->metadata_languages_free (NULL);
  dlclose (library);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}
