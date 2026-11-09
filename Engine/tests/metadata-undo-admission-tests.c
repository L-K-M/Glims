#include "engine-private.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"
#include "core/gimpimage-undo.h"
#include <stdio.h>
#include <string.h>
static const GlimsEngineAPI *api;
static int failures;
#define CHECK(c, text) do { printf("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); fflush(stdout); } while (0)
static GlimsStatus exercise (GlimsEngine *engine, gpointer data)
{
  GlimsImageID id = *(GlimsImageID *) data;
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpMetadata *seed = gimp_metadata_new ();
  GError *native_error = NULL;
  char *error = NULL, *before, *after;
  const char *title[] = { "lang=\"x-default\" Hello", "lang=\"fr\" Salut", NULL };
  const char *artist[] = { "Changed artist" };
  const char *same_artist[] = { "Original artist" };
  GlimsImageInfo info_before = {0}, info_after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  int pass;
  CHECK (gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (seed), "Xmp.dc.title", title, &native_error)
         && gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (seed), "Exif.Image.Artist", "Original artist", &native_error)
         && !native_error, "seeds independently known title and artist metadata");
  g_clear_error (&native_error);
  gimp_image_set_metadata (image, seed, FALSE); g_object_unref (seed);
  for (pass = 0; pass < 2; pass++) {
    GimpMetadata *original = gimp_image_get_metadata (image);
    before = gimp_metadata_serialize (original);
    api->image_info (engine, id, &info_before); api->image_undo_info (engine, id, &undo_before);
    if (pass == 0) gimp_image_undo_freeze (image); else gimp_image_undo_disable (image);
    CHECK (!gimp_image_undo_is_enabled (image), "the fixture really disables native Undo");
    CHECK (api->image_metadata_edit_language (engine, id, "Xmp.dc.title", "fr", "Bonjour", &error) == GLIMS_STATUS_BUSY,
           "a changed language refuses while Undo is frozen or disabled");
    g_clear_pointer (&error, g_free);
    CHECK (api->image_metadata_edit (engine, id, "Exif.Image.Artist", GLIMS_METADATA_SET, artist, 1, &error) == GLIMS_STATUS_BUSY,
           "a generic metadata change refuses while Undo is frozen or disabled");
    g_clear_pointer (&error, g_free);
    CHECK (api->image_metadata_edit_language (engine, id, "Xmp.dc.title", "fr", "Salut", &error) == GLIMS_STATUS_OK,
           "an exact language no-op remains allowed with Undo disabled");
    g_clear_pointer (&error, g_free);
    CHECK (api->image_metadata_edit (engine, id, "Exif.Image.Artist", GLIMS_METADATA_SET, same_artist, 1, &error) == GLIMS_STATUS_OK,
           "an exact generic no-op remains allowed with Undo disabled");
    g_clear_pointer (&error, g_free);
    after = gimp_metadata_serialize (gimp_image_get_metadata (image));
    api->image_info (engine, id, &info_after); api->image_undo_info (engine, id, &undo_after);
    CHECK (gimp_image_get_metadata (image) == original && !strcmp (before, after)
           && !memcmp (&info_before, &info_after, sizeof info_before)
           && !memcmp (&undo_before, &undo_after, sizeof undo_before),
           "Undo-disabled refusals and no-ops preserve the metadata object, all values, dirty state and history");
    g_free (before); g_free (after);
    gimp_image_undo_thaw (image);
  }
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int main (int argc, char **argv)
{
  GlimsEngineConfig config = { .struct_size = sizeof config };
  GlimsEngine *engine = NULL;
  GlimsImageID image = 0;
  GlimsStatus status;
  char user[4096], cache[4096], *error = NULL;
  if (argc != 2) return 2;
  snprintf (user, sizeof user, "%s/user", argv[1]); snprintf (cache, sizeof cache, "%s/cache", argv[1]);
  config.user_directory = user; config.cache_directory = cache;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api || api->start (&config, &engine, &error) != GLIMS_STATUS_OK) return 2;
  status = api->image_new (engine, 64, 64, &image, &error);
  if (error) api->free_string (error);
  if (status == GLIMS_STATUS_OK) status = glims_engine_call (engine, exercise, &image);
  if (image) api->image_close (engine, image);
  api->stop (engine);
  printf ("%s: %d failures\n", status == GLIMS_STATUS_OK && !failures ? "PASSED" : "FAILED", failures);
  return status != GLIMS_STATUS_OK || failures != 0;
}
