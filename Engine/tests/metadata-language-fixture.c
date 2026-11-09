/*
 * metadata-language-fixture.c — seeds and saves the LangAlt fixture XCF
 * for the future public LangAlt facade tests.
 *
 *   metadata-language-fixture OUTPUT.xcf WORK_DIR
 *
 * Test-only: links the adapter objects and gimp-console objects directly
 * (no dlopen, no libgimp), includes engine-private.h, runs the body on
 * the engine thread via one glims_engine_call(). The worker image_new's
 * 64x64, seeds a private metadata copy with the real native setters and
 * explicit lang="..." prefixes, installs it with
 * gimp_image_set_metadata(..., FALSE), validates the internal reader's
 * map against the hard-coded oracle, then returns; main calls facade
 * image_save on the caller's path only, closes the image, stops engine.
 * Oracle: Xmp.dc.title x-default="Hello" fr="Salut" de="Hallo";
 * Xmp.dc.rights x-default="Default rights" ja="権利"; unrelated
 * Exif.Image.Artist="Fixture Artist",
 * Iptc.Application2.Caption="Fixture caption".
 * HOME/XDG_CACHE_HOME/GIMP3_DIRECTORY point inside WORK_DIR; the real
 * home, ~/.cache and GIMP settings are never touched.
 */
#include "engine-private.h"
#include "metadata-language.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"

static const GlimsEngineAPI *api;

typedef struct { GlimsImageID image_id; int failures; } Probe;

#define CHECK(cond, ...) do {                                  \
    if (! (cond)) {                                            \
      probe->failures++;                                       \
      fprintf (stderr, "FAIL %s: ", __func__);                 \
      fprintf (stderr, __VA_ARGS__);                           \
      fputc ('\n', stderr);                                    \
    }                                                          \
  } while (0)

#define FIXTURE(cond, ...) do {                                \
    if (! (cond)) {                                            \
      fprintf (stderr, "FIXTURE-FAIL %s: ", __func__);         \
      fprintf (stderr, __VA_ARGS__);                           \
      fputc ('\n', stderr);                                    \
      probe->failures++;                                       \
      return GLIMS_STATUS_FAILED;                              \
    }                                                          \
  } while (0)

/* One native multiple-value write on the private copy; `strv` is ours
 * because the caller's array carries no NULL terminator. */
static gboolean
set_multiple (GimpMetadata *metadata, const char *tag,
              const char *const *values, int count)
{
  const gchar **strv = g_new0 (const gchar *, (gsize) count + 1);
  GError *gerror = NULL;
  gboolean ok;
  int i;

  for (i = 0; i < count; i++)
    strv[i] = values[i];
  ok = gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (metadata), tag,
                                             strv, &gerror) && ! gerror;
  if (! ok)
    fprintf (stderr, "native setter %s: %s\n", tag, gerror ? gerror->message : "refused");
  g_clear_error (&gerror);
  g_free (strv);
  return ok;
}

/* The reader's typed map must equal the oracle by language key in any
 * order: every expected (language, text) pair occurs exactly once and
 * the pair count matches, so no extra or wrong-text pair survives. */
static void
expect_langalt (Probe *probe, GimpMetadata *metadata, const char *root,
                const char *const *langs, const char *const *texts, int count)
{
  GPtrArray *out = NULL;
  char *error = NULL;
  GlimsStatus status = glims_metadata_language_read (metadata, root, &out, &error);
  int i, j;

  CHECK (status == GLIMS_STATUS_OK && out && out->len == (guint) count,
         "%s: %d pairs (status %d, got %u, error %s)", root, count,
         (int) status, out ? out->len : 0, error ? error : "none");
  for (i = 0; out && i < count && out->len == (guint) count; i++)
    {
      int found = 0;

      for (j = 0; j < (int) out->len; j++)
        {
          GlimsMetadataLanguagePair *p = g_ptr_array_index (out, j);
          found += p && ! strcmp (p->language, langs[i]) &&
                    ! strcmp (p->text, texts[i]);
        }
      CHECK (found == 1, "%s: %s=\"%s\" once (got %d)",
             root, langs[i], texts[i], found);
    }
  if (out)
    g_ptr_array_unref (out);
  free (error);
}

/* Independent native getter check for an unrelated single-value tag. */
#define EXPECT_TAG(tag, want) do {                             \
    GError *ge = NULL;                                         \
    gchar *v = gexiv2_metadata_try_get_tag_string (             \
      GEXIV2_METADATA (metadata), tag, &ge);                   \
    CHECK (v && ! ge && ! strcmp (v, want), "%s = %s", tag, want); \
    g_free (v);                                                \
    g_clear_error (&ge);                                       \
  } while (0)

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  static const char *const tv[] = { "lang=\"x-default\" Hello",
      "lang=\"fr\" Salut", "lang=\"de\" Hallo" };
  static const char *const tl[] = { "x-default", "fr", "de" };
  static const char *const tt[] = { "Hello", "Salut", "Hallo" };
  static const char *const rv[] = { "lang=\"x-default\" Default rights",
      "lang=\"ja\" \xe6\xa8\xa9\xe5\x88\xa9" };
  static const char *const rl[] = { "x-default", "ja" };
  static const char *const rt[] = { "Default rights", "\xe6\xa8\xa9\xe5\x88\xa9" };
  static const char *const av[] = { "Fixture Artist" };
  static const char *const cv[] = { "Fixture caption" };
  Probe *probe = data;
  GlimsOpenImage *open;
  GimpMetadata *current, *metadata;
  gboolean seeded;
  char *error = NULL;
  GlimsStatus result;

  result = api->image_new (engine, 64, 64, &probe->image_id, &error);
  if (error)
    { fprintf (stderr, "image_new: %s\n", error); api->free_string (error); error = NULL; }
  FIXTURE (result == GLIMS_STATUS_OK, "[setup] image_new 64x64");
  open = glims_lookup_image (engine, probe->image_id);
  FIXTURE (open && open->image, "[setup] image lookup");

  /* Private copy only: a refused setter discards it before install. */
  current = gimp_image_get_metadata (open->image);
  metadata = current ? gimp_metadata_duplicate (current) : gimp_metadata_new ();
  FIXTURE (metadata != NULL, "[setup] private metadata");
  seeded = set_multiple (metadata, "Xmp.dc.title", tv, 3) &&
           set_multiple (metadata, "Xmp.dc.rights", rv, 2) &&
           set_multiple (metadata, "Exif.Image.Artist", av, 1) &&
           set_multiple (metadata, "Iptc.Application2.Caption", cv, 1);
  if (! seeded) g_object_unref (metadata);
  FIXTURE (seeded, "[seed] native setters");
  gimp_image_set_metadata (open->image, metadata, FALSE);
  g_object_unref (metadata);

  /* Validate the typed reader map by key BEFORE any save; expectations
   * are the hard-coded oracle, never values read back from the reader. */
  metadata = gimp_image_get_metadata (open->image);
  FIXTURE (metadata != NULL, "[check] metadata installed");
  expect_langalt (probe, metadata, "Xmp.dc.title", tl, tt, 3);
  expect_langalt (probe, metadata, "Xmp.dc.rights", rl, rt, 2);
  EXPECT_TAG ("Exif.Image.Artist", "Fixture Artist");
  EXPECT_TAG ("Iptc.Application2.Caption", "Fixture caption");

  return probe->failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  Probe probe;
  char *error = NULL, *save_error = NULL;
  char home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status, save_status = GLIMS_STATUS_OK;
  const char *output;

  if (argc != 3 || ! *argv[1] || ! *argv[2])
    {
      fprintf (stderr, "usage: %s OUTPUT.xcf WORK_DIR\n", argv[0]);
      return 2;
    }
  output = argv[1];
  snprintf (home_dir, sizeof home_dir, "%s/home", argv[2]);
  snprintf (user_dir, sizeof user_dir, "%s/user", argv[2]);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", argv[2]);
  if ((mkdir (argv[2], 0755) < 0 && errno != EEXIST) ||
      (mkdir (home_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (user_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (cache_dir, 0755) < 0 && errno != EEXIST))
    {
      fprintf (stderr, "cannot create work dirs under %s: %s\n",
               argv[2], strerror (errno));
      return 1;
    }
  g_setenv ("HOME", home_dir, TRUE);
  g_setenv ("XDG_CACHE_HOME", cache_dir, TRUE);
  g_setenv ("GIMP3_DIRECTORY", user_dir, TRUE);

  memset (&probe, 0, sizeof probe);
  memset (&config, 0, sizeof config);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (api == NULL || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fputs ("glims_engine_get_api did not serve the facade\n", stderr);
      return 1;
    }
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n",
               error ? error : "unknown error");
      if (error)
        api->free_string (error);
      return 1;
    }

  printf ("metadata-language-fixture: engine %s, output %s, work %s\n",
          api->engine_version (engine), output, argv[2]);
  status = glims_engine_call (engine, run_all, &probe);

  /* The worker returned: facade image_save is its own engine call and
   * writes only the caller's path. */
  if (status == GLIMS_STATUS_OK && ! probe.failures && probe.image_id)
    {
      save_status = api->image_save (engine, probe.image_id, output,
                                     &save_error);
      if (save_status == GLIMS_STATUS_OK)
        printf ("wrote %s\n", output);
      else
        {
          fprintf (stderr, "image_save %s failed: %s\n", output,
                   save_error ? save_error : "unknown error");
          if (save_error)
            api->free_string (save_error);
          probe.failures++;
        }
    }
  else
    fprintf (stderr, "fixture seed/validation failed; %s not written\n",
             output);

  if (probe.image_id &&
      api->image_close (engine, probe.image_id) != GLIMS_STATUS_OK)
    {
      fputs ("image_close failed\n", stderr);
      probe.failures++;
    }
  api->stop (engine);

  probe.failures += status != GLIMS_STATUS_OK ||
                    save_status != GLIMS_STATUS_OK;
  printf ("%s\n", probe.failures ? "fixture FAILED" : "fixture written");
  return probe.failures ? 1 : 0;
}
