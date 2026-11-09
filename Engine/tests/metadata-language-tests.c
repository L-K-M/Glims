/*
 * metadata-language-tests.c — deterministic standalone harness for the
 * engine-internal read-only LangAlt reader (Engine/metadata-language.c).
 *
 *   metadata-language-tests WORK_DIR
 *
 * Test-only file. Like saved-set-undo-tests.c it links the adapter objects
 * and GIMP's gimp-console objects directly (no dlopen, no libgimp), includes
 * Engine/engine-private.h, and runs the whole fixture/test body on the
 * engine thread through one glims_engine_call(). It modifies no production
 * file. The runtime scenarios below are executed only by the owner of the
 * runtime decision (scripts/test-metadata-language.py run); building them
 * (build / --compile-only) never runs anything.
 *
 * Fixtures are seeded through the native multiple setter with explicit
 * lang="..." prefixes (x-default/fr/de and friends); the expected pairs are
 * hard-coded independently of the reader, in the native map order
 * (LangAltValueComparator: longer keys first, then case-insensitive
 * alphanumeric). Asserted semantics:
 *   - Success returns owned pairs with exact language spelling and exact
 *     text (XML characters, quotes, unicode, whitespace, newlines, literal
 *     "lang=" syntax) when the native vector represents them exactly;
 *     a missing x-default is fine.
 *   - Refusals: absent tag NOT_FOUND, wrong kind / indexed / path /
 *     non-XMP root UNSUPPORTED, NULL required pointers INVALID_ARGUMENT,
 *     empty alternative in any position, all-empty map, comma ambiguity in
 *     a later text, pair/text/packet bound overflows — all UNSUPPORTED with
 *     *out == NULL and an owned message.
 *   - Every read and every refusal leaves the generated packet, the native
 *     value vector, the metadata object pointer, the undo/redo stack depths
 *     and the dirty flag unchanged (read-only, no undo).
 */
#include "engine-private.h"
#include "metadata-language.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"
#include "core/gimpimage-undo.h"
#include "core/gimpundostack.h"

int main (int argc, char **argv);

typedef struct
{
  GimpImage   *image;
  GlimsImageID image_id;
  int failures;
} Probe;

static const GlimsEngineAPI *api;

#define CHECK(condition, ...)                     \
  do {                                            \
    if (condition) {                              \
      printf ("ok    ");                          \
    } else {                                      \
      printf ("FAIL  ");                          \
      probe->failures++;                          \
    }                                             \
    printf (__VA_ARGS__);                         \
    printf ("\n");                                \
    fflush (stdout);                              \
  } while (0)

#define FIXTURE(condition, ...)                   \
  do {                                            \
    if (! (condition)) {                          \
      printf ("FIXTURE-FAIL  ");                  \
      printf (__VA_ARGS__);                       \
      printf ("\n");                              \
      fflush (stdout);                            \
      probe->failures++;                          \
      return GLIMS_STATUS_FAILED;                 \
    }                                             \
  } while (0)

typedef struct
{
  char *packet;
  char **vector;
} Snapshot;

static void
snapshot_take (Probe *probe, const char *root, Snapshot *snap)
{
  GimpMetadata *metadata = gimp_image_get_metadata (probe->image);
  GError *gerror = NULL;

  snap->packet = metadata ? gexiv2_metadata_try_generate_xmp_packet (
    GEXIV2_METADATA (metadata),
    GEXIV2_OMIT_PACKET_WRAPPER | GEXIV2_USE_COMPACT_FORMAT | GEXIV2_OMIT_ALL_FORMATTING,
    0, &gerror) : NULL;
  snap->vector = metadata ? gexiv2_metadata_try_get_tag_multiple (
    GEXIV2_METADATA (metadata), root, &gerror) : NULL;
  g_clear_error (&gerror);
}

static void
snapshot_free (Snapshot *snap)
{
  g_free (snap->packet);
  g_strfreev (snap->vector);
  snap->packet = NULL;
  snap->vector = NULL;
}

/* Seeds one LangAlt root through the native multiple setter on a private
 * metadata copy installed with one native undo step (fixture setup only). */
static gboolean
seed (Probe *probe, const char *root, const char *const *values, int count)
{
  GimpMetadata *current = gimp_image_get_metadata (probe->image);
  GimpMetadata *copy = current ? gimp_metadata_duplicate (current) : gimp_metadata_new ();
  const gchar **terminated = g_new0 (const gchar *, (gsize) count + 1);
  GError *gerror = NULL;
  gboolean ok;
  int i;

  for (i = 0; i < count; i++)
    terminated[i] = values[i];
  ok = gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (copy), root,
                                              terminated, &gerror) && ! gerror;
  g_clear_error (&gerror);
  g_free (terminated);
  if (ok)
    {
      gimp_image_set_metadata (probe->image, copy, TRUE);
      g_object_unref (copy);
    }
  else if (copy != current)
    g_object_unref (copy);
  return ok;
}

/* Runs the reader and checks a successful result against the independently
 * expected map (count + exact language spelling and text). */
static gboolean
vectors_equal (gchar **left, gchar **right)
{
  return (! left || ! right) ? left == right
    : g_strv_equal ((const gchar * const *) left, (const gchar * const *) right);
}

static void
expect_pairs (Probe *probe, const char *root,
              const char *const *expected_lang, const char *const *expected_text,
              int count, const char *label)
{
  GPtrArray *out = (GPtrArray *) 0x1;
  char *error = NULL;
  GlimsStatus status;
  Snapshot before, after;
  GimpMetadata *metadata = gimp_image_get_metadata (probe->image);
  gint undo, redo;
  gint dirty;

  snapshot_take (probe, root, &before);
  undo = gimp_undo_stack_get_depth (gimp_image_get_undo_stack (probe->image));
  redo = gimp_undo_stack_get_depth (gimp_image_get_redo_stack (probe->image));
  dirty = gimp_image_is_dirty (probe->image);

  status = glims_metadata_language_read (metadata, root, &out, &error);
  CHECK (status == GLIMS_STATUS_OK, "%s: status OK (got %d, error %s)", label, (int) status,
         error ? error : "none");
  CHECK (out != NULL && out->len == (guint) count, "%s: %d pairs (got %u)", label, count,
         out ? out->len : 0);
  if (out && out->len == (guint) count)
    for (int i = 0; i < count; i++)
      {
        GlimsMetadataLanguagePair *pair = NULL;
        guint matches = 0, j;

        for (j = 0; j < out->len; j++)
          {
            GlimsMetadataLanguagePair *candidate = g_ptr_array_index (out, j);
            if (candidate && ! strcmp (candidate->language, expected_lang[i]))
              { pair = candidate; matches++; }
          }
        CHECK (matches == 1 && pair && ! strcmp (pair->text, expected_text[i]),
               "%s: language %s has exact text (got %s; expected %s)", label,
               expected_lang[i], pair ? pair->text : "<missing>", expected_text[i]);
      }
  if (out)
    g_ptr_array_unref (out);
  free (error);

  snapshot_take (probe, root, &after);
  CHECK ((before.packet == NULL) == (after.packet == NULL) &&
         (! before.packet || ! strcmp (before.packet, after.packet)),
         "%s: generated packet unchanged", label);
  CHECK (vectors_equal (before.vector, after.vector),
         "%s: native vector unchanged", label);
  CHECK (gimp_image_get_metadata (probe->image) == metadata, "%s: metadata object unchanged",
         label);
  CHECK (gimp_undo_stack_get_depth (gimp_image_get_undo_stack (probe->image)) == undo &&
         gimp_undo_stack_get_depth (gimp_image_get_redo_stack (probe->image)) == redo &&
         gimp_image_is_dirty (probe->image) == dirty,
         "%s: no undo/redo/dirty change", label);
  snapshot_free (&before);
  snapshot_free (&after);
}

/* Runs the reader and checks the expected refusal status, *out NULL and an
 * owned message, plus full before/after invariance. */
static void
expect_refusal (Probe *probe, const char *root, GlimsStatus expected, const char *label)
{
  GPtrArray *out = (GPtrArray *) 0x1;
  char *error = NULL;
  GlimsStatus status;
  Snapshot before, after;
  GimpMetadata *metadata = gimp_image_get_metadata (probe->image);
  gint undo, redo;
  gint dirty;

  snapshot_take (probe, root, &before);
  undo = gimp_undo_stack_get_depth (gimp_image_get_undo_stack (probe->image));
  redo = gimp_undo_stack_get_depth (gimp_image_get_redo_stack (probe->image));
  dirty = gimp_image_is_dirty (probe->image);

  status = glims_metadata_language_read (metadata, root, &out, &error);
  CHECK (status == expected, "%s: status %d (got %d, error %s)", label, (int) expected,
         (int) status, error ? error : "none");
  CHECK (out == NULL, "%s: *out reset to NULL", label);
  CHECK (error != NULL, "%s: owned error message", label);
  free (error);

  snapshot_take (probe, root, &after);
  CHECK ((before.packet == NULL) == (after.packet == NULL) &&
         (! before.packet || ! strcmp (before.packet, after.packet)) &&
         vectors_equal (before.vector, after.vector) &&
         gimp_image_get_metadata (probe->image) == metadata &&
         gimp_undo_stack_get_depth (gimp_image_get_undo_stack (probe->image)) == undo &&
         gimp_undo_stack_get_depth (gimp_image_get_redo_stack (probe->image)) == redo &&
         gimp_image_is_dirty (probe->image) == dirty,
         "%s: packet/vector/metadata/undo/dirty unchanged", label);
  snapshot_free (&before);
  snapshot_free (&after);
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  char *error = NULL;
  GlimsStatus result = api->image_new (engine, 64, 64, &probe->image_id, &error);

  FIXTURE (result == GLIMS_STATUS_OK, "[setup] image created");
  free (error);
  error = NULL;
  probe->image = glims_lookup_image (engine, probe->image_id)->image;
  FIXTURE (probe->image != NULL, "[setup] image looked up");

  /* NULL required pointers. */
  {
    GPtrArray *out = NULL;
    GimpMetadata *metadata = gimp_image_get_metadata (probe->image);

    CHECK (glims_metadata_language_read (NULL, "Xmp.dc.title", &out, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "[args] NULL metadata INVALID");
    CHECK (glims_metadata_language_read (metadata, NULL, &out, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "[args] NULL root INVALID");
    CHECK (glims_metadata_language_read (metadata, "Xmp.dc.title", NULL, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "[args] NULL out INVALID");
    CHECK (glims_metadata_language_read (metadata, "notatag", &out, NULL) ==
           GLIMS_STATUS_INVALID_ARGUMENT, "[args] malformed root INVALID");
  }

  /* Absent registered LangAlt tag. */
  expect_refusal (probe, "Xmp.dc.rights", GLIMS_STATUS_NOT_FOUND, "[absent] NOT_FOUND");
  /* Unregistered name, wrong kind, indexed/path forms, other domains. */
  expect_refusal (probe, "Xmp.nosuchgroup.tag", GLIMS_STATUS_NOT_FOUND, "[unregistered] NOT_FOUND");
  expect_refusal (probe, "Xmp.dc.format", GLIMS_STATUS_UNSUPPORTED, "[wrongkind] XmpText UNSUPPORTED");
  expect_refusal (probe, "Exif.Image.ImageWidth", GLIMS_STATUS_UNSUPPORTED, "[wrongkind] Exif UNSUPPORTED");
  expect_refusal (probe, "Xmp.dc.title[1]", GLIMS_STATUS_UNSUPPORTED, "[indexed] UNSUPPORTED");
  expect_refusal (probe, "Xmp.dc.a.b", GLIMS_STATUS_UNSUPPORTED, "[path] UNSUPPORTED");

  /* Seeded x-default/fr/de; native map order is x-default, de, fr. */
  {
    const char *values[] = { "lang=\"x-default\" Hello", "lang=\"fr\" Salut",
                             "lang=\"de\" Hallo" };
    const char *langs[] = { "x-default", "fr", "de" };
    const char *texts[] = { "Hello", "Salut", "Hallo" };

    FIXTURE (seed (probe, "Xmp.dc.title", values, 3), "[seed] title");
    expect_pairs (probe, "Xmp.dc.title", langs, texts, 3, "[basic] x-default/fr/de");
  }

  /* Missing default is fine when the native vector represents the map. */
  {
    const char *values[] = { "lang=\"fr\" Salut", "lang=\"de\" Hallo" };
    const char *langs[] = { "de", "fr" };
    const char *texts[] = { "Hallo", "Salut" };

    FIXTURE (seed (probe, "Xmp.dc.description", values, 2), "[seed] description");
    expect_pairs (probe, "Xmp.dc.description", langs, texts, 2, "[nodefault] de/fr");
  }

  /* XML characters, quotes, unicode, whitespace and newlines, exact. */
  {
    const char *values[] = { "lang=\"x-default\" A & B <t> \"q\" 'x'",
                             "lang=\"fr\"  pad\nd\xc3\xa9j\xc3\xa0 \xf0\x9f\x98\x80  " };
    const char *langs[] = { "x-default", "fr" };
    const char *texts[] = { "A & B <t> \"q\" 'x'", " pad\nd\xc3\xa9j\xc3\xa0 \xf0\x9f\x98\x80  " };

    FIXTURE (seed (probe, "Xmp.dc.rights", values, 2), "[seed] rights");
    expect_pairs (probe, "Xmp.dc.rights", langs, texts, 2, "[exact] special text");
  }

  /* Literal lang= syntax inside a later text is represented exactly. */
  {
    const char *values[] = { "lang=\"x-default\" A", "lang=\"fr\" lang=\"x\" junk" };
    const char *langs[] = { "x-default", "fr" };
    const char *texts[] = { "A", "lang=\"x\" junk" };

    FIXTURE (seed (probe, "Xmp.dc.rights", values, 2), "[seed] literal lang");
    expect_pairs (probe, "Xmp.dc.rights", langs, texts, 2, "[literal] lang= in text");
  }

  /* A comma in a later text makes the native split ambiguous: refuse. */
  {
    const char *values[] = { "lang=\"x-default\" A", "lang=\"fr\" a, b" };

    FIXTURE (seed (probe, "Xmp.dc.title", values, 2), "[seed] comma");
    expect_refusal (probe, "Xmp.dc.title", GLIMS_STATUS_UNSUPPORTED, "[comma] UNSUPPORTED");
  }

  /* An empty alternative in any position is omitted by the encoder: refuse. */
  {
    const char *values[] = { "lang=\"x-default\" A", "lang=\"fr\" " };

    FIXTURE (seed (probe, "Xmp.dc.description", values, 2), "[seed] empty later");
    expect_refusal (probe, "Xmp.dc.description", GLIMS_STATUS_UNSUPPORTED,
                    "[empty-later] UNSUPPORTED");
  }

  /* All-empty map: the encoder omits the property, the native zero-count
   * sentinel returns one empty string: refuse. */
  {
    const char *values[] = { "lang=\"x-default\" " };

    FIXTURE (seed (probe, "Xmp.dc.rights", values, 1), "[seed] all empty");
    expect_refusal (probe, "Xmp.dc.rights", GLIMS_STATUS_UNSUPPORTED, "[all-empty] UNSUPPORTED");
  }

  /* Pair bound: 257 alternatives exceed the 256 pair bound. */
  {
    const char *values[257];
    char storage[257][16];
    char *langs[257];
    int i;

    for (i = 0; i < 257; i++)
      {
        snprintf (storage[i], sizeof storage[i], "l%c%c", 'a' + i / 26, 'a' + i % 26);
        values[i] = storage[i];
        langs[i] = storage[i];
      }
    /* values need the lang="..." prefix form for the native setter */
    {
      char prefixed[257][24];
      const char *pv[257];

      for (i = 0; i < 257; i++)
        {
          snprintf (prefixed[i], sizeof prefixed[i], "lang=\"%s\" v%d", langs[i], i);
          pv[i] = prefixed[i];
        }
      FIXTURE (seed (probe, "Xmp.dc.title", pv, 257), "[seed] 257 pairs");
    }
    expect_refusal (probe, "Xmp.dc.title", GLIMS_STATUS_UNSUPPORTED, "[pairs-bound] UNSUPPORTED");
  }

  /* Text aggregate bound: two 600 KiB entries exceed the 1 MiB aggregate. */
  {
    char *big = g_malloc0 (600 * 1024);
    char *v0, *v1;
    const char *values[2];

    memset (big, 'x', 600 * 1024 - 1);
    v0 = g_strdup_printf ("lang=\"x-default\" %s", big);
    v1 = g_strdup_printf ("lang=\"fr\" %s", big);
    values[0] = v0;
    values[1] = v1;

    FIXTURE (seed (probe, "Xmp.dc.description", values, 2), "[seed] aggregate");
    expect_refusal (probe, "Xmp.dc.description", GLIMS_STATUS_UNSUPPORTED,
                    "[text-bound] UNSUPPORTED");
    g_free (big);
    g_free (v0);
    g_free (v1);
  }

  /* Packet bound: one 3 MiB entry exceeds the 2 MiB packet bound. */
  {
    char *big = g_malloc0 (3 * 1024 * 1024);
    char *v0;
    const char *values[1];

    memset (big, 'y', 3 * 1024 * 1024 - 1);
    v0 = g_strdup_printf ("lang=\"x-default\" %s", big);
    values[0] = v0;

    FIXTURE (seed (probe, "Xmp.dc.rights", values, 1), "[seed] packet bound");
    expect_refusal (probe, "Xmp.dc.rights", GLIMS_STATUS_UNSUPPORTED, "[packet-bound] UNSUPPORTED");
    g_free (big);
    g_free (v0);
  }

  /* A good read after all refusals still succeeds. Reset the fixture:
   * the size bound applies to the entire packet, including other tags. */
  gimp_image_set_metadata (probe->image, NULL, FALSE);
  {
    const char *values[] = { "lang=\"x-default\" Hello", "lang=\"fr\" Salut",
                             "lang=\"de\" Hallo" };
    const char *langs[] = { "x-default", "fr", "de" };
    const char *texts[] = { "Hello", "Salut", "Hallo" };

    FIXTURE (seed (probe, "Xmp.dc.title", values, 3), "[seed] title again");
    expect_pairs (probe, "Xmp.dc.title", langs, texts, 3, "[final] x-default/fr/de");
  }

  result = api->image_close (engine, probe->image_id);
  free (error);
  CHECK (result == GLIMS_STATUS_OK, "[teardown] image closed");

  return probe->failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  Probe probe;
  char *error = NULL;
  char work[1024], home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status;

  if (argc != 2)
    {
      fprintf (stderr, "usage: %s WORK_DIR\n", argv[0]);
      return 2;
    }

  snprintf (work, sizeof work, "%s", argv[1]);
  snprintf (home_dir, sizeof home_dir, "%s/home", work);
  snprintf (user_dir, sizeof user_dir, "%s/user", work);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work);
  if ((mkdir (work, 0755) < 0 && errno != EEXIST) ||
      (mkdir (home_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (user_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (cache_dir, 0755) < 0 && errno != EEXIST))
    {
      fprintf (stderr, "cannot create work dirs under %s: %s\n", work, strerror (errno));
      return 1;
    }

  memset (&probe, 0, sizeof probe);
  memset (&config, 0, sizeof config);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = NULL;

  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (api == NULL || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fprintf (stderr, "glims_engine_get_api(%u) did not serve the facade\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 1;
    }

  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error != NULL ? error : "unknown error");
      if (error != NULL)
        api->free_string (error);
      return 1;
    }

  printf ("metadata-language-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n", probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && probe.failures == 0) ? 0 : 1;
}
