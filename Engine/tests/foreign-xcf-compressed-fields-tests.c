/* Test-only bzip2/xz compressed foreign XCF regression, pinned to GIMP 3.2.8.
 * Reuses the independently validated patched plain-XCF fixture from
 * foreign-xcf-effect-fields-tests.c by including it with its main renamed,
 * the same pattern foreign-xcf-gzip-identity-tests.c uses. Production stages
 * gzip only today; this harness pins the target for the two ordinary
 * compressed variants .xcf.bz2 and .xcf.xz: opening them through the public
 * facade must preserve the validated nondefault blend/composite fields.
 * The fixture independently encodes and round-trips the exact plain bytes
 * with the system bz2/lzma libraries; those links are fixture-only and no
 * production link or dependency changes. Ordinary small fixtures only: no
 * extreme inputs and no parser fault injection. */
#define main foreign_effect_fields_fixture_main
#include "foreign-xcf-effect-fields-tests.c"
#undef main

#include <bzlib.h>
#include <stdint.h>

#include <lzma.h>

int main (int argc, char **argv);

static gboolean
write_bytes (const gchar *path, const guint8 *bytes, gsize size)
{
  GError *error = NULL;
  gboolean ok = g_file_set_contents (path, (const gchar *) bytes, (gssize) size, &error);
  if (!ok) fprintf (stderr, "OBS fixture write: %s\n", error ? error->message : "unknown error");
  g_clear_error (&error);
  return ok;
}

/* Independently encode the exact plain bytes and round-trip them through the
 * same library before any native or facade open. The compressed bytes are
 * returned preserved for the on-disk source checks. */
static gboolean
bz2_encode (const guint8 *plain, gsize size, guint8 **out, gsize *out_size)
{
  if (!size || size > MAX_FILE_BYTES) return FALSE;
  gsize bound = size + size / 100 + 601;
  guint8 *compressed = g_malloc (bound);
  unsigned int compressed_len = (unsigned int) bound;
  if (BZ2_bzBuffToBuffCompress ((char *) compressed, &compressed_len, (char *) plain,
                                (unsigned int) size, 9, 0, 0) != BZ_OK)
    {
      g_free (compressed);
      return FALSE;
    }
  guint8 *decoded = g_malloc (size);
  unsigned int decoded_len = (unsigned int) size;
  gboolean ok = compressed_len >= 12u && !memcmp (compressed, "BZh", 3) &&
      compressed[3] >= '1' && compressed[3] <= '9' &&
      BZ2_bzBuffToBuffDecompress ((char *) decoded, &decoded_len, (char *) compressed,
                                  compressed_len, 0, 0) == BZ_OK &&
      decoded_len == (unsigned int) size && !memcmp (decoded, plain, size);
  g_free (decoded);
  if (!ok)
    {
      g_free (compressed);
      return FALSE;
    }
  *out = compressed;
  *out_size = compressed_len;
  return TRUE;
}

static gboolean
xz_encode (const guint8 *plain, gsize size, guint8 **out, gsize *out_size)
{
  if (!size || size > MAX_FILE_BYTES) return FALSE;
  static const guint8 magic[6] = { 0xfd, '7', 'z', 'X', 'Z', 0x00 };
  gsize bound = lzma_stream_buffer_bound (size);
  guint8 *compressed = g_malloc (bound);
  size_t written = 0;
  if (lzma_easy_buffer_encode (LZMA_PRESET_DEFAULT, LZMA_CHECK_CRC64, NULL,
                               plain, size, compressed, &written, bound) != LZMA_OK)
    {
      g_free (compressed);
      return FALSE;
    }
  guint8 *decoded = g_malloc (size);
  uint64_t memlimit = UINT64_MAX;
  size_t in_pos = 0, out_pos = 0;
  lzma_ret status = lzma_stream_buffer_decode (&memlimit, 0, NULL, compressed, &in_pos, written,
                                           decoded, &out_pos, size);
  gboolean ok = written >= sizeof magic && !memcmp (compressed, magic, sizeof magic) &&
      status == LZMA_OK && in_pos == written && out_pos == size &&
      !memcmp (decoded, plain, size);
  g_free (decoded);
  if (!ok)
    {
      g_free (compressed);
      return FALSE;
    }
  *out = compressed;
  *out_size = written;
  return TRUE;
}

static void
compressed_case (GlimsEngine *engine, const gchar *suffix, const guint8 *patched, gsize size,
                 const gfloat rendered[COMPONENTS], const gint control[3])
{
  Fixture loaded = {0};
  GlimsImageID opened = 0;
  char *error = NULL;
  gchar *name = g_strdup_printf ("foreign-explicit-effect.xcf.%s", suffix);
  gchar *path = g_build_filename (work_dir, name, NULL);
  GFile *file = g_file_new_for_path (path);
  guint8 *compressed = NULL;
  gchar *reread = NULL;
  gsize compressed_size = 0, reread_size = 0;
  gfloat actual[COMPONENTS];
  printf ("OBS compressed case=%s\n", name);
  gboolean encoded = !g_strcmp0 (suffix, "bz2")
      ? bz2_encode (patched, size, &compressed, &compressed_size)
      : xz_encode (patched, size, &compressed, &compressed_size);
  NEED (encoded, "independent member encodes and round-trips the exact patched plain bytes");
  NEED (write_bytes (path, compressed, compressed_size) &&
        read_file (path, &reread, &reread_size) &&
        reread_size == compressed_size && !memcmp (reread, compressed, compressed_size),
        "compressed source bytes are preserved on disk before any open");
  gchar *plain_sha = g_compute_checksum_for_data (G_CHECKSUM_SHA256, patched, size);
  gchar *compressed_sha = g_compute_checksum_for_data (G_CHECKSUM_SHA256, compressed, compressed_size);
  printf ("OBS %s xcf_sha256=%s %s_sha256=%s\n", name, plain_sha, suffix, compressed_sha);
  g_free (plain_sha);
  g_free (compressed_sha);
  g_clear_pointer (&reread, g_free);

  GlimsStatus status = api->image_open (engine, path, &opened, &error);
  printf ("OBS %s facade status=%d image=%d\n", name, (int) status, (int) opened);
  CHECK (status == GLIMS_STATUS_OK && opened != 0 && !error,
         "facade accepts the compressed foreign XCF with explicit effect fields");
  CHECK (read_file (path, &reread, &reread_size) &&
         reread_size == compressed_size && !memcmp (reread, compressed, compressed_size),
         "facade open leaves the original compressed file byte-identical");
  if (status != GLIMS_STATUS_OK || !opened)
    {
      CHECK (!opened, "refused compressed open does not publish an image");
      goto cleanup;
    }
  NEED (opened_fixture (engine, opened, &loaded),
        "compressed facade open retains one ordinary FLOAT_LINEAR alpha layer");
  CHECK (original_gzip_file (loaded.image, file) && clean_open (&loaded),
         "compressed facade open keeps the original GFile identity and starts clean without a carrier or history");
  GimpDrawableFilter *effect = one_effect (&loaded);
  NEED (effect != NULL, "compressed facade open retains exactly one native effect");
  CHECK (!g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (effect)), SENTINEL) &&
         !g_strcmp0 (gegl_node_get_operation (gimp_drawable_filter_get_operation (effect)), OPERATION),
         "compressed facade open preserves the exact operation and effect name");
  gint blend = gimp_drawable_filter_get_blend_space (effect);
  gint composite_space = gimp_drawable_filter_get_composite_space (effect);
  gint composite_mode = gimp_drawable_filter_get_composite_mode (effect);
  printf ("OBS %s loaded_fields=%d,%d,%d oracle_fields=%u,%u,%u control_fields=%d,%d,%d\n",
          name, blend, composite_space, composite_mode,
          explicit_values[0], explicit_values[1], explicit_values[2],
          control[0], control[1], control[2]);
  CHECK (blend == (gint) explicit_values[0] && composite_space == (gint) explicit_values[1] &&
         composite_mode == (gint) explicit_values[2],
         "compressed open matches the patched oracle blend/composite fields exactly");
  CHECK (explicit_fields (effect) &&
         (blend != control[0] || composite_space != control[1] || composite_mode != control[2]),
         "compressed open differs from the raw native AUTO normalization control");
  CHECK (read_pixels (&loaded, FALSE, actual) && !memcmp (actual, source_pixels, sizeof actual),
         "compressed facade open preserves exact raw FLOAT_LINEAR pixels");
  CHECK (read_pixels (&loaded, TRUE, actual) && pixel_delta (actual, rendered) < 2e-4,
         "compressed facade open matches the independent effect-rendered float oracle");
cleanup:
  if (error) fprintf (stderr, "OBS %s facade open: %s\n", name, error);
  if (opened) CHECK (api->image_close (engine, opened) == GLIMS_STATUS_OK,
                     "owned compressed image closes");
  clear_error (&error);
  g_object_unref (file);
  g_free (reread);
  g_free (compressed);
  g_free (path);
  g_free (name);
}

static GlimsStatus
compressed_regression (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture source = {0}, loaded = {0};
  GlimsImageID opened = 0;
  GimpDrawableFilter *filter = NULL, *control_effect = NULL, *oracle = NULL;
  GeglNode *node = NULL;
  gboolean committed = FALSE;
  char *error = NULL;
  gchar *native_path = g_build_filename (work_dir, "compressed-native-unpatched.xcf", NULL);
  gchar *foreign_path = g_build_filename (work_dir, "compressed-explicit-effect.xcf", NULL);
  gchar *original = NULL, *patched = NULL;
  gsize size = 0;
  EffectRecord record = {0}, encoded = {0};
  gfloat expected[COMPONENTS], actual[COMPONENTS];
  gint control[3] = { -1, -1, -1 };
  NEED (!strcmp (api->engine_version (engine), "3.2.8"), "oracle runs only on pinned GIMP 3.2.8");
  NEED (create_source (engine, &source), "fixture creates an ordinary FLOAT_LINEAR alpha layer");
  NEED (gegl_has_operation (OPERATION), "non-Curves exposure operation is installed");
  node = gegl_node_new ();
  gegl_node_set (node, "operation", OPERATION, "black-level", .03125, "exposure", 1.25, NULL);
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (source.layer), SENTINEL, node, ICON);
  NEED (filter != NULL, "fixture creates its one independently configured native effect");
  gimp_drawable_filter_set_temporary (filter, FALSE);
  gimp_drawable_filter_set_opacity (filter, .625);
  gimp_drawable_filter_set_clip (filter, TRUE);
  gimp_drawable_filter_set_region (filter, GIMP_FILTER_REGION_DRAWABLE);
  set_explicit (filter);
  gimp_drawable_filter_apply (filter, NULL);
  gimp_drawable_filter_layer_mask_freeze (filter);
  committed = gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
  NEED (committed && gimp_drawable_filter_get_mask (filter) && one_effect (&source) == filter,
        "fixture commits exactly one genuine effect with its native mask");
  CHECK (explicit_fields (filter), "source independently owns the three explicit nondefault fields");
  NEED (read_pixels (&source, FALSE, actual) && !memcmp (actual, source_pixels, sizeof actual) &&
        read_pixels (&source, TRUE, expected),
        "source raw bytes and explicit effect-rendered pixels are captured before file I/O");
  NEED (native_save (&source, native_path), "fixture saves through direct native file_save without Glims preservation");
  NEED (read_file (native_path, &original, &size) && no_glims_namespace ((guint8 *) original, size) &&
        locate_record ((guint8 *) original, size, &record),
        "bounded direct-native XCF bytes validate their unique effect record");
  patched = g_memdup2 (original, size);
  for (guint i = 0; i < 3; i++)
    {
      guint32 value = GUINT32_TO_BE (explicit_values[i]);
      memcpy (patched + record.fields[i], &value, sizeof value);
    }
  NEED (locate_record ((guint8 *) patched, size, &encoded) &&
        !memcmp (record.fields, encoded.fields, sizeof record.fields) &&
        !memcmp (encoded.values, explicit_values, sizeof explicit_values),
        "patched plain XCF revalidates with the exact explicit payload integers");
  NEED (write_bytes (foreign_path, (const guint8 *) patched, size),
        "independently validated patched plain XCF oracle is written");

  /* Raw native normalization control: the same unpatched native file opens
   * through the facade with the three fields normalized to AUTO. */
  NEED (api->image_open (engine, native_path, &opened, &error) == GLIMS_STATUS_OK,
        "facade opens the unpatched native normalization control");
  NEED (opened_fixture (engine, opened, &loaded), "control retains one ordinary FLOAT_LINEAR alpha layer");
  control_effect = one_effect (&loaded);
  NEED (control_effect != NULL, "control retains exactly one native effect");
  control[0] = gimp_drawable_filter_get_blend_space (control_effect);
  control[1] = gimp_drawable_filter_get_composite_space (control_effect);
  control[2] = gimp_drawable_filter_get_composite_mode (control_effect);
  printf ("OBS control_fields=%d,%d,%d\n", control[0], control[1], control[2]);
  CHECK (control[0] == GIMP_LAYER_COLOR_SPACE_AUTO && control[1] == GIMP_LAYER_COLOR_SPACE_AUTO &&
         control[2] == GIMP_LAYER_COMPOSITE_AUTO,
         "raw native control normalizes the three fields to AUTO without the patched payloads");
  CHECK (api->image_close (engine, opened) == GLIMS_STATUS_OK, "control image closes");
  opened = 0;

  /* Patched plain oracle: its facade open carries the explicit fields the
   * compressed variants must match. */
  NEED (api->image_open (engine, foreign_path, &opened, &error) == GLIMS_STATUS_OK,
        "facade opens the validated patched plain oracle");
  NEED (opened_fixture (engine, opened, &loaded), "patched plain oracle retains one ordinary layer");
  oracle = one_effect (&loaded);
  CHECK (oracle && explicit_fields (oracle),
         "patched plain oracle preserves the three explicit fields through the facade");
  CHECK (api->image_close (engine, opened) == GLIMS_STATUS_OK, "oracle image closes");
  opened = 0;

  compressed_case (engine, "bz2", (const guint8 *) patched, size, expected, control);
  compressed_case (engine, "xz", (const guint8 *) patched, size, expected, control);
cleanup:
  if (error) fprintf (stderr, "OBS public open: %s\n", error);
  if (opened) api->image_close (engine, opened);
  if (filter && !committed) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter);
  g_clear_object (&node);
  if (source.id) api->image_close (engine, source.id);
  clear_error (&error);
  g_free (native_path);
  g_free (foreign_path);
  g_free (original);
  g_free (patched);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api) return 2;
  gchar *user = g_build_filename (work_dir, "user", NULL);
  gchar *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    clear_error (&error);
    g_free (user);
    g_free (cache);
    return 2;
  }
  CHECK (glims_engine_call (engine, compressed_regression, NULL) == GLIMS_STATUS_OK,
         "compressed foreign XCF regression runs on the real engine worker");
  api->stop (engine);
  g_free (user);
  g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}
