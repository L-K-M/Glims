#include "engine-private.h"
#include "metadata-language.h"
#include "metadata-language-write.h"
#include "metadata-inventory.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static int failures;
#define CHECK(c, text) do { printf("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); fflush(stdout); } while (0)

static const char *
text_for (GPtrArray *pairs, const char *language)
{
  guint i;
  for (i = 0; pairs && i < pairs->len; i++) {
    GlimsMetadataLanguagePair *p = g_ptr_array_index (pairs, i);
    if (!strcmp (p->language, language)) return p->text;
  }
  return NULL;
}

static void
refuses_unchanged (GimpImage *image, const char *label)
{
  GimpMetadata *current = gimp_image_get_metadata (image), *copy = NULL;
  char *before = gimp_metadata_serialize (current), *error = NULL;
  GlimsStatus status = glims_metadata_language_prepare (image, "Xmp.dc.title", "fr", "Changed", &copy, &error);
  char *after = gimp_metadata_serialize (current);
  CHECK (status == GLIMS_STATUS_UNSUPPORTED && !copy && gimp_image_get_metadata (image) == current &&
         before && after && !strcmp (before, after), label);
  if (status != GLIMS_STATUS_UNSUPPORTED) fprintf (stderr, "unexpected refusal status %d: %s\n", status, error ? error : "none");
  if (copy) g_object_unref (copy);
  g_free (before); g_free (after); g_free (error);
}

static GlimsStatus
exercise (GlimsEngine *engine, gpointer data)
{
  GlimsImageID id = *(GlimsImageID *) data;
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpMetadata *seed = gimp_metadata_new (), *current, *copy = NULL;
  GError *native_error = NULL;
  char *error = NULL, *before, *after;
  GPtrArray *pairs = NULL;
  GlimsImageInfo info_before = {0}, info_after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  GlimsStatus status;
  const char *title[] = { "lang=\"x-default\" Hello", "lang=\"fr\" Salut", NULL };
  const char *rights[] = { "lang=\"x-default\" Rights", "lang=\"ja\" 権利", NULL };
  gboolean seeded = gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (seed), "Xmp.dc.title", title, &native_error);
  if (seeded && !native_error) seeded = gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (seed), "Xmp.dc.rights", rights, &native_error);
  if (seeded && !native_error) seeded = gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (seed), "Exif.Image.Artist", "Unrelated artist", &native_error);
  CHECK (seeded && !native_error, "seeds two independent language maps and unrelated metadata");
  g_clear_error (&native_error);
  if (!seeded) { g_object_unref (seed); return GLIMS_STATUS_FAILED; }
  gimp_image_set_metadata (image, seed, FALSE);
  g_object_unref (seed);
  current = gimp_image_get_metadata (image);
  before = gimp_metadata_serialize (current);
  api->image_info (engine, id, &info_before);
  api->image_undo_info (engine, id, &undo_before);
  status = glims_metadata_language_prepare (image, "Xmp.dc.title", "fr", "Bonjour 山", &copy, &error);
  CHECK (status == GLIMS_STATUS_OK && copy && copy != current, "prepares one existing-language edit on an owned detached copy");
  if (status != GLIMS_STATUS_OK) fprintf (stderr, "prepare: %d %s\n", status, error ? error : "none");
  g_clear_pointer (&error, g_free);
  if (copy) {
    CHECK (glims_metadata_language_read (copy, "Xmp.dc.title", &pairs, &error) == GLIMS_STATUS_OK && pairs && pairs->len == 2 &&
           !g_strcmp0 (text_for (pairs, "fr"), "Bonjour 山") && !g_strcmp0 (text_for (pairs, "x-default"), "Hello"),
           "the candidate changes only the requested language text");
    if (pairs) g_ptr_array_unref (pairs);
    pairs = NULL; g_clear_pointer (&error, g_free);
    CHECK (glims_metadata_language_read (copy, "Xmp.dc.rights", &pairs, &error) == GLIMS_STATUS_OK && pairs && pairs->len == 2 &&
           !g_strcmp0 (text_for (pairs, "ja"), "権利") && !g_strcmp0 (text_for (pairs, "x-default"), "Rights"),
           "the other complete language map remains unchanged");
    if (pairs) g_ptr_array_unref (pairs);
    pairs = NULL; g_clear_pointer (&error, g_free);
    g_object_unref (copy); copy = NULL;
  }
  CHECK (glims_metadata_language_prepare (image, "Xmp.dc.title", "fr", "Salut", &copy, &error) == GLIMS_STATUS_OK && !copy,
         "an unchanged text returns OK without allocating a replacement");
  g_clear_pointer (&error, g_free);
  CHECK (glims_metadata_language_prepare (image, "Xmp.dc.title", "de", "Hallo", &copy, &error) == GLIMS_STATUS_NOT_FOUND && !copy,
         "a missing language refuses instead of creating a new map entry");
  g_clear_pointer (&error, g_free);
  CHECK (glims_metadata_language_prepare (image, "Xmp.dc.title", "FR", "Bonjour", &copy, &error) == GLIMS_STATUS_NOT_FOUND && !copy,
         "the existing language spelling must match exactly");
  g_clear_pointer (&error, g_free);
  CHECK (glims_metadata_language_prepare (image, "Xmp.dc.title", "fr", "", &copy, &error) == GLIMS_STATUS_INVALID_ARGUMENT && !copy,
         "empty replacement text refuses");
  g_clear_pointer (&error, g_free);
  {
    const char *hidden[] = { "lang=\"x-default\" Rights", "lang=\"ja\" ", NULL };
    CHECK (gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (current), "Xmp.dc.rights", hidden, &native_error) && !native_error,
           "seeds a hidden empty alternative in the unrelated map");
    g_clear_error (&native_error);
    refuses_unchanged (image, "an unrelated hidden-empty language map refuses before any image replacement");
    CHECK (gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (current), "Xmp.dc.rights", rights, &native_error) && !native_error,
           "restores the known unrelated map fixture");
    g_clear_error (&native_error);
    gimp_metadata_set_pixel_size (current, 999, 777);
    refuses_unchanged (image, "non-stable original image facts refuse before native normalization could change them");
    gimp_metadata_set_pixel_size (current, 64, 64);
    CHECK (gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (current), "Xmp.dc.format", "lang=\"fr\" ambiguous", &native_error) && !native_error,
           "seeds an ambiguous unrelated scalar representation");
    g_clear_error (&native_error);
    refuses_unchanged (image, "a LangAlt-looking unrelated scalar conservatively refuses without mutation");
    CHECK (gexiv2_metadata_try_clear_tag (GEXIV2_METADATA (current), "Xmp.dc.format", &native_error) && !native_error,
           "removes the ambiguous scalar fixture");
    g_clear_error (&native_error);
  }
  after = gimp_metadata_serialize (current);
  api->image_info (engine, id, &info_after);
  api->image_undo_info (engine, id, &undo_after);
  CHECK (gimp_image_get_metadata (image) == current && !g_strcmp0 (before, after) &&
         !memcmp (&info_before, &info_after, sizeof info_before) && !memcmp (&undo_before, &undo_after, sizeof undo_before),
         "preparation and refusals preserve the attached object, all metadata, image facts and history");
  g_free (after); g_free (before);
  {
    GimpMetadata *pristine = gimp_metadata_duplicate (gimp_image_get_metadata (image));
    const char *empty_tags[] = { "Exif.Photo.MakerNote", "Iptc.Application2.Caption" };
    guint i;
    for (i = 0; pristine && i < G_N_ELEMENTS (empty_tags); i++) {
      GimpMetadata *fixture = gimp_metadata_duplicate (pristine);
      gsize empty_count = 0;
      gboolean added = gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (fixture), empty_tags[i], "", &native_error);
      CHECK (added && !native_error, "seeds an actual zero-count EXIF or IPTC entry independently");
      g_clear_error (&native_error);
      gimp_image_set_metadata (image, fixture, FALSE);
      CHECK (glims_metadata_empty_entry_count (GEXIV2_METADATA (fixture), &empty_count, &error) == GLIMS_STATUS_OK && empty_count > 0,
             "complete native inventory detects the zero-count entry outside XMP");
      g_clear_pointer (&error, g_free);
      refuses_unchanged (image, "zero-count EXIF/IPTC data refuses preparation without changing the image");
      g_object_unref (fixture);
    }
    if (pristine) g_object_unref (pristine);
  }
  {
    const char *packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
      "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
      "<dc:title><rdf:Alt><rdf:li xml:lang=\"fr\">Salut</rdf:li></rdf:Alt></dc:title>"
      "<dc:rights><rdf:Alt/></dc:rights></rdf:Description></rdf:RDF></x:xmpmeta>";
    GimpMetadata *imported = gimp_metadata_new ();
    char **zero_before = NULL, **zero_candidate = NULL;
    gboolean loaded = gexiv2_metadata_open_buf (GEXIV2_METADATA (imported), (const guint8 *) packet, strlen (packet), &native_error);
    CHECK (loaded && !native_error, "imports a legal raw XMP packet with an empty rights alternative map");
    g_clear_error (&native_error);
    if (loaded) {
      gimp_image_set_metadata (image, imported, FALSE);
      zero_before = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (imported), "Xmp.dc.rights", &native_error);
      CHECK (zero_before && zero_before[0] && !*zero_before[0] && !zero_before[1] && !native_error,
             "the imported zero-entry LangAlt exists through direct native lookup");
      g_clear_error (&native_error);
      status = glims_metadata_language_prepare (image, "Xmp.dc.title", "fr", "Changed", &copy, &error);
      if (copy) zero_candidate = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (copy), "Xmp.dc.rights", &native_error);
      CHECK (status == GLIMS_STATUS_UNSUPPORTED && !copy,
             "a zero-entry unrelated LangAlt refuses before a copy can lose its presence");
      if (copy) fprintf (stderr, "zero LangAlt candidate lookup: %s\n",
                        zero_candidate && zero_candidate[0] ? "PRESENT EMPTY VALUE" : "LOST (empty native vector)");
      if (copy) g_object_unref (copy);
      copy = NULL;
      g_clear_pointer (&error, g_free);
      {
        const char *artist[] = { "Would drop the hidden entry" };
        char **still_zero;
        CHECK (api->image_metadata_edit (engine, id, "Exif.Image.Artist", GLIMS_METADATA_SET, artist, 1, &error) == GLIMS_STATUS_UNSUPPORTED,
               "the existing generic metadata writer also refuses a hidden zero-entry map");
        g_clear_pointer (&error, g_free);
        still_zero = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (gimp_image_get_metadata (image)), "Xmp.dc.rights", &native_error);
        CHECK (gimp_image_get_metadata (image) == imported && still_zero && still_zero[0] && !*still_zero[0] && !still_zero[1] && !native_error,
               "generic refusal preserves the original hidden native entry and attached object");
        g_strfreev (still_zero);
      }
      g_strfreev (zero_before); g_strfreev (zero_candidate);
      g_clear_error (&native_error); g_clear_pointer (&error, g_free);
    }
    g_object_unref (imported);
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
