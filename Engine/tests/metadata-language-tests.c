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
 *   - An injected-packet suite arms a test-only wrapper of
 *     gexiv2_metadata_try_generate_xmp_packet (defined in this harness
 *     object so the standalone binary binds it before libgexiv2, falling
 *     back to the real symbol through dlsym(RTLD_NEXT)) only around the
 *     reader call; snapshots keep the real generator.
 */
#include "engine-private.h"
#include "metadata-language.h"

#include <dlfcn.h>
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

/* ---- injected-packet fault/namespace suite -------------------------------
 * One test-only wrapper of gexiv2_metadata_try_generate_xmp_packet (the
 * exact public GExiv2 signature) is defined in this harness object, so the
 * standalone binary binds the reader's call — and every intra-image
 * reference — here before libgexiv2. While disarmed it forwards to the real
 * generator resolved once through dlsym(RTLD_NEXT); inject_arm() serves one
 * controlled packet (or one controlled GError) for the duration of a single
 * glims_metadata_language_read call. Never linked into the adapter or any
 * shared producer. */
typedef gchar *(*GeneratePacket) (GExiv2Metadata *, GExiv2XmpFormatFlags,
                                  guint32, GError **);

static const gchar *injected_packet;
static const gchar *injected_gerror;
static const gchar *expected_reason;

static GeneratePacket
real_generate (void)
{
  static GeneratePacket real;
  if (! real)
    real = (GeneratePacket) dlsym (RTLD_NEXT,
                                   "gexiv2_metadata_try_generate_xmp_packet");
  return real;
}

gchar *
gexiv2_metadata_try_generate_xmp_packet (GExiv2Metadata *self,
                                         GExiv2XmpFormatFlags xmp_format_flags,
                                         guint32 padding, GError **error)
{
  GeneratePacket real;
  if (injected_packet || injected_gerror)
    {
      if (injected_gerror)
        g_set_error_literal (error, g_quark_from_static_string ("glims-metadata-fault"),
                             1, injected_gerror);
      return g_strdup (injected_packet);
    }
  real = real_generate ();
  if (! real)
    {
      g_set_error_literal (error, g_quark_from_static_string ("glims-metadata-fault"), 1,
                           "test shim could not resolve the real packet generator");
      return NULL;
    }
  return real (self, xmp_format_flags, padding, error);
}

static void
inject_arm (const gchar *packet, const gchar *gerror_message)
{
  injected_packet = packet;
  injected_gerror = gerror_message;
}

/* Runs the reader once under the armed shim; the arm is cleared straight
 * after the call, whatever the outcome. Asserts the exact status, the
 * *out/owned-error contract (the one known pair on OK) and the full
 * before/after packet/vector/metadata/undo/dirty invariance taken through
 * the real generator. */
static void
expect_injected (Probe *probe, const char *root, const char *packet,
                 const char *gerror, GlimsStatus expected,
                 const char *expect_lang, const char *expect_text, const char *label)
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

  inject_arm (packet, gerror);
  status = glims_metadata_language_read (metadata, root, &out, &error);
  inject_arm (NULL, NULL);

  CHECK (status == expected, "%s: status %d (got %d, error %s)", label, (int) expected,
         (int) status, error ? error : "none");
  if (expected == GLIMS_STATUS_OK)
    {
      GlimsMetadataLanguagePair *pair =
        out && out->len == 1 ? g_ptr_array_index (out, 0) : NULL;
      CHECK (pair && ! strcmp (pair->language, expect_lang) &&
             ! strcmp (pair->text, expect_text),
             "%s: exact pair %s=%s", label, expect_lang, expect_text);
    }
  else
    {
      CHECK (out == NULL, "%s: *out reset to NULL", label);
      CHECK (error != NULL, "%s: owned error message", label);
      if (expected_reason)
        CHECK (error && strstr (error, expected_reason), "%s: the intended guard reports its reason", label);
    }
  expected_reason = NULL;
  if (out)
    g_ptr_array_unref (out);
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
  FIXTURE (real_generate () != NULL &&
           real_generate () != gexiv2_metadata_try_generate_xmp_packet,
           "[setup] RTLD_NEXT resolves the real generator");

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

  /* Injected-packet fault/namespace suite: each scenario arms the shim
   * only around the reader call and is checked against the real seeded
   * vector (the one-element baseline "lang=\"x-default\" Base"). Statuses
   * follow the sealed contract: semantic refusals carry the reader's
   * LANGALT_ERROR domain (UNSUPPORTED); GMarkup and native errors do not
   * (FAILED). */
  {
    const char *one[] = { "lang=\"x-default\" Base" };
    FIXTURE (seed (probe, "Xmp.dc.title", one, 1), "[inject] seeded x-default=Base");
  }

#define PKT(body) \
  "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF" \
  " xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" \
  "<rdf:Description>" body "</rdf:Description></rdf:RDF></x:xmpmeta>"
#define TITLE(body) \
  "<dc:title xmlns:dc=\"http://purl.org/dc/elements/1.1/\">" body "</dc:title>"
#define ALT(body) "<rdf:Alt>" body "</rdf:Alt>"
#define LI(lang, txt) "<rdf:li xml:lang=\"" lang "\">" txt "</rdf:li>"

  /* Prefix aliases bound to the same URIs expand identically; the only
   * injectable acceptance, checked against the real baseline vector. */
  expect_injected (probe, "Xmp.dc.title",
    "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><y:RDF xmlns:y=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><y:Description><zz:title xmlns:zz=\"http://purl.org/dc/elements/1.1/\"><y:Alt><y:li xml:lang=\"x-default\">Base</y:li></y:Alt></zz:title></y:Description></y:RDF></x:xmpmeta>",
    NULL, GLIMS_STATUS_OK, "x-default", "Base", "[aliases] OK");
  /* Same local name under the wrong URI never matches the target. */
  expect_injected (probe, "Xmp.dc.title",
    PKT ("<dc:title xmlns:dc=\"http://example.com/not-dc/\">"
         ALT (LI ("x-default", "Base")) "</dc:title>"),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[wrong-uri] UNSUPPORTED");
  /* xmlns redeclaration on the container shadows rdf: the Alt expands to
   * the shadow URI and the nesting guard refuses it. */
  expect_injected (probe, "Xmp.dc.title",
    PKT (TITLE ("<rdf:Alt xmlns:rdf=\"http://example.com/shadow/\">"
                LI ("x-default", "Base") "</rdf:Alt>")),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[shadow] UNSUPPORTED");
  /* One property, two rdf:Alt containers: refused by cardinality. */
  expect_injected (probe, "Xmp.dc.title",
    PKT (TITLE (ALT (LI ("x-default", "Base")) "<rdf:Alt/>")),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[second-alt] UNSUPPORTED");
  /* Qualifiers beyond xml:lang on the li or on the container are refused;
   * non-whitespace text inside a container is mixed content. */
  expect_injected (probe, "Xmp.dc.title",
    PKT (TITLE (ALT ("<rdf:li xml:lang=\"x-default\" rdf:dummy=\"q\">Base</rdf:li>"))),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[li-qualifier] UNSUPPORTED");
  expect_injected (probe, "Xmp.dc.title",
    PKT (TITLE ("<rdf:Alt rdf:ID=\"q\">" LI ("x-default", "Base") "</rdf:Alt>")),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[alt-qualifier] UNSUPPORTED");
  expect_injected (probe, "Xmp.dc.title",
    PKT (TITLE ("oops" ALT (LI ("x-default", "Base")))),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[mixed] UNSUPPORTED");
  /* Nesting past the 32-deep bound is refused; the partial frame freed
   * there is still fully zeroed, so cleanup must stay quiet. */
  {
    GString *deep = g_string_new (
      "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
      "<rdf:Description xmlns:d=\"urn:d\">" TITLE (ALT (LI ("x-default", "Base"))));
    for (int i = 0; i < 33; i++) g_string_append (deep, "<d:e>");
    for (int i = 0; i < 33; i++) g_string_append (deep, "</d:e>");
    g_string_append (deep, "</rdf:Description></rdf:RDF></x:xmpmeta>");
    expect_injected (probe, "Xmp.dc.title", deep->str, NULL,
                     GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[depth] UNSUPPORTED");
    g_string_free (deep, TRUE);
  }
  /* An undeclared prefix is a semantic refusal (LANGALT_ERROR domain):
   * UNSUPPORTED. A well-formedness failure is a GMarkup error outside
   * that domain: FAILED ("The XMP packet could not be parsed."). */
  expect_injected (probe, "Xmp.dc.title",
    PKT ("<zz:title>" ALT (LI ("x-default", "Base")) "</zz:title>"),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[undeclared] UNSUPPORTED");
  expect_injected (probe, "Xmp.dc.title",
    "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF",
    NULL, GLIMS_STATUS_FAILED, NULL, NULL, "[malformed] FAILED");
  /* Case-folded duplicate language keys are refused even though the
   * native map cannot produce them. */
  expected_reason = "Duplicate language key";
  expect_injected (probe, "Xmp.dc.title",
    PKT (TITLE (ALT (LI ("en-US", "A") LI ("EN-us", "B")))),
    NULL, GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[dup-lang] UNSUPPORTED");
  /* Bounds: namespace URI over 4096, XML name over 512, language key over
   * 255. */
  {
    gchar *uri = g_strnfill (4097, 'u');
    gchar *pkt = g_strdup_printf (PKT (TITLE (ALT (LI ("x-default", "Base"))) "<d:e xmlns:d=\"%s\"></d:e>"), uri);
    expect_injected (probe, "Xmp.dc.title", pkt, NULL,
                     GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[ns-bound] UNSUPPORTED");
    g_free (uri);
    g_free (pkt);
  }
  {
    gchar *nm = g_strnfill (511, 'e');
    gchar *pkt = g_strdup_printf (PKT (TITLE (ALT (LI ("x-default", "Base"))) "<d:%s xmlns:d=\"urn:d\"></d:%s>"), nm, nm);
    expect_injected (probe, "Xmp.dc.title", pkt, NULL,
                     GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[name-bound] UNSUPPORTED");
    g_free (nm);
    g_free (pkt);
  }
  {
    gchar *lg = g_strnfill (256, 'q');
    gchar *pkt = g_strdup_printf (
      PKT (TITLE (ALT ("<rdf:li xml:lang=\"%s\">v</rdf:li>"))), lg);
    gchar *prefixed = g_strdup_printf ("lang=\"%s\" v", lg);
    const gchar *one_long[] = { prefixed };
    FIXTURE (seed (probe, "Xmp.dc.title", one_long, 1), "[lang-bound] native long language exists");
    expect_injected (probe, "Xmp.dc.title", pkt, NULL,
                     GLIMS_STATUS_UNSUPPORTED, NULL, NULL, "[lang-bound] UNSUPPORTED");
    g_free (prefixed);
    g_free (lg);
    g_free (pkt);
  }
  {
    const char *one[] = { "lang=\"x-default\" Base" };
    FIXTURE (seed (probe, "Xmp.dc.title", one, 1), "[inject] restore baseline after long language");
  }
  /* A native generator GError is a native failure: FAILED with an owned
   * message through glims_fail. */
  expect_injected (probe, "Xmp.dc.title", NULL, "injected generator failure",
                   GLIMS_STATUS_FAILED, NULL, NULL, "[gen-error] FAILED");

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
