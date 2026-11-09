/* Core-only normalization oracle: native setter on a separate image.
 * Run with an isolated HOME/cache/user and two newly created64x64 images. */
#include "engine-private.h"
#include "metadata-normalization.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-convert-precision.h"
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static int failures;
#define CHECK(c, text) do { printf("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); } while (0)
typedef struct { GlimsImageID image, reference; const char *bits, *space; } Probe;

static gboolean
tag_is (GimpMetadata *metadata, const char *tag, const char *expected)
{
  GError *error = NULL;
  char *value = gexiv2_metadata_try_get_tag_string (GEXIV2_METADATA (metadata), tag, &error);
  gboolean matches = !error && !g_strcmp0 (value, expected);
  g_free (value);
  g_clear_error (&error);
  return matches;
}

static GlimsStatus
exercise (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  GimpImage *image = glims_lookup_image (engine, probe->image)->image;
  GimpImage *reference = glims_lookup_image (engine, probe->reference)->image;
  GimpMetadata *seed = gimp_metadata_new (), *current, *copy, *reference_copy;
  GError *native_error = NULL;
  char *before, *after, *candidate_xml, *reference_xml, *error = NULL;
  GlimsImageInfo info_before = {0}, info_after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  const char *title[] = { "lang=\"x-default\" Hello", "lang=\"fr\" Salut", NULL };
  gboolean seeded = gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (seed), "Xmp.dc.title", title, &native_error);
  if (seeded && !native_error) seeded = gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (seed), "Exif.Image.Artist", "Known artist", &native_error);
  if (seeded && !native_error) seeded = gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (seed), "Iptc.Application2.Caption", "Known caption", &native_error);
  CHECK (seeded && !native_error, "seeds independent known unrelated metadata and language map");
  g_clear_error (&native_error);
  if (!seeded) { g_object_unref (seed); return GLIMS_STATUS_FAILED; }
  gimp_image_set_metadata (image, seed, FALSE);
  g_object_unref (seed);
  current = gimp_image_get_metadata (image);
  before = gimp_metadata_serialize (current);
  copy = gimp_metadata_duplicate (current);
  if (!before || !copy) { g_free (before); if (copy) g_object_unref (copy); return GLIMS_STATUS_FAILED; }
  api->image_info (engine, probe->image, &info_before);
  api->image_undo_info (engine, probe->image, &undo_before);
  CHECK (glims_metadata_normalize_private_copy (NULL, copy, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL image refuses before changing the detached copy");
  g_clear_pointer (&error, g_free);
  after = gimp_metadata_serialize (copy);
  CHECK (!g_strcmp0 (before, after), "NULL-image refusal preserves all serialized copy metadata");
  g_free (after);
  CHECK (glims_metadata_normalize_private_copy (image, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "NULL copy refuses");
  g_clear_pointer (&error, g_free);
  CHECK (glims_metadata_normalize_private_copy (image, current, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
         "the borrowed attached metadata alias refuses");
  g_clear_pointer (&error, g_free);

  gimp_metadata_set_pixel_size (copy, 999, 777);
  gimp_metadata_set_bits_per_sample (copy, 64);
  gimp_metadata_set_resolution (copy, 72, 150, gimp_unit_inch ());
  gimp_metadata_set_colorspace (copy, GIMP_METADATA_COLORSPACE_ADOBERGB);
  reference_copy = gimp_metadata_duplicate (copy);
  if (!reference_copy) { g_free (before); g_object_unref (copy); return GLIMS_STATUS_FAILED; }
  /* The oracle uses native installation on another image, not this helper. */
  gimp_image_set_metadata (reference, reference_copy, FALSE);
  g_object_unref (reference_copy);
  CHECK (glims_metadata_normalize_private_copy (image, copy, &error) == GLIMS_STATUS_OK,
         "normalizes the detached mismatched copy");
  g_clear_pointer (&error, g_free);
  candidate_xml = gimp_metadata_serialize (copy);
  reference_xml = gimp_metadata_serialize (gimp_image_get_metadata (reference));
  CHECK (candidate_xml && reference_xml && !strcmp (candidate_xml, reference_xml),
         "complete metadata matches the separate native-setter oracle");
  CHECK (tag_is (copy, "Exif.Image.ImageWidth", "64") && tag_is (copy, "Exif.Image.ImageLength", "64"),
         "normalizes to the actual64x64 dimensions");
  CHECK (tag_is (copy, "Exif.Image.BitsPerSample", probe->bits), "normalizes the actual component bit depth");
  if (probe->space)
    CHECK (tag_is (copy, "Exif.Photo.ColorSpace", probe->space), "normalizes the expected native colorspace value");
  else
    {
      gboolean present = gexiv2_metadata_try_has_tag (GEXIV2_METADATA (copy), "Exif.Photo.ColorSpace", &native_error);
      CHECK (!present && !native_error, "another explicit profile clears the native colorspace tag");
      g_clear_error (&native_error);
    }
  CHECK (tag_is (copy, "Exif.Image.XResolution", "300/1") && tag_is (copy, "Exif.Image.YResolution", "300/1"),
         "normalizes each resolution axis to the native image's300dpi");
  CHECK (tag_is (copy, "Exif.Image.Artist", "Known artist") && tag_is (copy, "Iptc.Application2.Caption", "Known caption"),
         "normalization preserves known unrelated EXIF and IPTC values");
  CHECK (glims_metadata_normalize_private_copy (image, copy, &error) == GLIMS_STATUS_OK,
         "a second normalization completes");
  g_clear_pointer (&error, g_free);
  after = gimp_metadata_serialize (copy);
  CHECK (!g_strcmp0 (candidate_xml, after), "normalization is idempotent on the detached copy");
  g_free (after);
  g_free (candidate_xml);
  g_free (reference_xml);
  g_object_unref (copy);
  after = gimp_metadata_serialize (current);
  api->image_info (engine, probe->image, &info_after);
  api->image_undo_info (engine, probe->image, &undo_after);
  CHECK (gimp_image_get_metadata (image) == current && !g_strcmp0 (before, after) &&
         !memcmp (&info_before, &info_after, sizeof info_before) && !memcmp (&undo_before, &undo_after, sizeof undo_before),
         "all paths preserve the attached metadata pointer/content, dirty state and history");
  g_free (before);
  g_free (after);
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

static GlimsStatus
matrix (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  const GimpPrecision precision[] = { GIMP_PRECISION_U8_NON_LINEAR, GIMP_PRECISION_U16_NON_LINEAR,
    GIMP_PRECISION_HALF_LINEAR, GIMP_PRECISION_U32_NON_LINEAR, GIMP_PRECISION_FLOAT_LINEAR, GIMP_PRECISION_DOUBLE_LINEAR };
  const char *bits[] = { "8 8 8", "16 16 16", "16 16 16", "32 32 32", "32 32 32", "64 64 64" };
  GimpImage *images[] = { glims_lookup_image (engine, probe->image)->image,
                         glims_lookup_image (engine, probe->reference)->image };
  guint i, j;
  for (i = 0; i < G_N_ELEMENTS (precision); i++)
    {
      for (j = 0; j < G_N_ELEMENTS (images); j++)
        if (gimp_image_get_precision (images[j]) != precision[i])
          gimp_image_convert_precision (images[j], precision[i], GEGL_DITHER_NONE, GEGL_DITHER_NONE, GEGL_DITHER_NONE, NULL);
      probe->bits = bits[i]; probe->space = "1";
      printf ("precision case %u\n", i);
      exercise (engine, probe);
    }
  for (j = 0; j < G_N_ELEMENTS (images); j++)
    if (gimp_image_get_precision (images[j]) != GIMP_PRECISION_U8_NON_LINEAR)
      gimp_image_convert_precision (images[j], GIMP_PRECISION_U8_NON_LINEAR, GEGL_DITHER_NONE, GEGL_DITHER_NONE, GEGL_DITHER_NONE, NULL);
  for (i = 0; i < 2; i++)
    {
      GimpColorProfile *profile = i == 0 ? gimp_color_profile_new_rgb_adobe () : gimp_color_profile_new_rgb_srgb_linear ();
      if (!profile) { CHECK (0, "constructs the explicit profile fixture"); return GLIMS_STATUS_FAILED; }
      for (j = 0; j < G_N_ELEMENTS (images); j++)
        CHECK (gimp_image_set_color_profile (images[j], profile, NULL) && gimp_image_get_color_profile (images[j]),
               "the explicit profile is installed on both native oracle images");
      g_object_unref (profile);
      probe->bits = bits[0]; probe->space = i == 0 ? "2" : NULL;
      printf ("profile case %u\n", i);
      exercise (engine, probe);
    }
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int main (int argc, char **argv)
{
  GlimsEngineConfig config = { .struct_size = sizeof config };
  GlimsEngine *engine = NULL;
  Probe probe = {0};
  char user[4096], cache[4096], *error = NULL;
  GlimsStatus status;
  if (argc != 2) return 2;
  snprintf (user, sizeof user, "%s/user", argv[1]);
  snprintf (cache, sizeof cache, "%s/cache", argv[1]);
  config.user_directory = user; config.cache_directory = cache;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api || api->start (&config, &engine, &error) != GLIMS_STATUS_OK) return 2;
  status = api->image_new (engine, 64, 64, &probe.image, &error);
  if (status == GLIMS_STATUS_OK) status = api->image_new (engine, 64, 64, &probe.reference, &error);
  if (error) api->free_string (error);
  if (status == GLIMS_STATUS_OK) status = glims_engine_call (engine, matrix, &probe);
  if (probe.reference) api->image_close (engine, probe.reference);
  if (probe.image) api->image_close (engine, probe.image);
  api->stop (engine);
  printf ("%s: %d failures\n", status == GLIMS_STATUS_OK && !failures ? "PASSED" : "FAILED", failures);
  return status != GLIMS_STATUS_OK || failures != 0;
}
