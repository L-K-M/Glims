/* Test-only native entry wrappers. Only the alias in the private fixture
 * directory changes. Both loaders otherwise get their real inputs. */
#define main gzip_original_fixture_main
#include "foreign-xcf-effect-fields-tests.c"
#undef main
#include "xcf/xcf.h"
#include <glib/gstdio.h>
#include <unistd.h>

int main (int argc, char **argv);

static const gchar *alias_path, *first_path, *second_path, *next_path;
static GFile *alias_file;
static guint path_calls, stream_calls;
static gboolean original_link_base;

static gboolean
replace_alias (const gchar *target)
{
  if (symlink (target, next_path) != 0) return FALSE;
  if (g_rename (next_path, alias_path) == 0) return TRUE;
  g_unlink (next_path);
  return FALSE;
}

static gboolean
test_alias (GFile *file)
{
  return alias_file && file && g_file_equal (file, alias_file);
}

static void
swap_error (GError **error)
{
  if (error) g_clear_error (error);
  g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not switch the fixture-owned XCF alias");
}

GimpImage *glims_test_file_open_image (Gimp *, GimpContext *, GimpProgress *, GFile *,
    gint, gint, gboolean, gboolean, GimpPlugInProcedure *, GimpRunMode, gboolean *,
    GimpPDBStatusType *, const gchar **, GError **);
GimpImage *glims_test_xcf_load_stream (Gimp *, GInputStream *, GFile *, GimpProgress *, GError **);

GimpImage *
glims_test_file_open_image (Gimp *gimp, GimpContext *context, GimpProgress *progress, GFile *file,
    gint width, gint height, gboolean keep_ratio, gboolean as_new, GimpPlugInProcedure *procedure,
    GimpRunMode mode, gboolean *vector, GimpPDBStatusType *status, const gchar **mime, GError **error)
{
  gboolean switch_source = test_alias (file);
  if (switch_source && !replace_alias (second_path)) {
    swap_error (error);
    return NULL;
  }
  if (switch_source) path_calls++;
  GimpImage *image = file_open_image (gimp, context, progress, file, width, height, keep_ratio,
      as_new, procedure, mode, vector, status, mime, error);
  if (switch_source && !replace_alias (first_path)) {
    g_clear_object (&image);
    swap_error (error);
  }
  return image;
}

GimpImage *
glims_test_xcf_load_stream (Gimp *gimp, GInputStream *input, GFile *file,
                            GimpProgress *progress, GError **error)
{
  gboolean switch_source = test_alias (file);
  if (switch_source && !replace_alias (second_path)) {
    swap_error (error);
    return NULL;
  }
  if (switch_source) {
    stream_calls++;
    g_autoptr(GFile) parent = g_file_get_parent (file);
    g_autoptr(GFile) expected = g_file_new_for_path (work_dir);
    original_link_base = parent && g_file_equal (parent, expected);
  }
  GimpImage *image = xcf_load_stream (gimp, input, file, progress, error);
  if (switch_source && !replace_alias (first_path)) {
    g_clear_object (&image);
    swap_error (error);
  }
  return image;
}

static gboolean
second_fields (GimpDrawableFilter *filter)
{
  return filter && gimp_drawable_filter_get_blend_space (filter) == GIMP_LAYER_COLOR_SPACE_RGB_LINEAR &&
      gimp_drawable_filter_get_composite_space (filter) == GIMP_LAYER_COLOR_SPACE_RGB_LINEAR &&
      gimp_drawable_filter_get_composite_mode (filter) == GIMP_LAYER_COMPOSITE_UNION;
}

static GlimsStatus
identity_regression (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture a = {0}, b = {0}, loaded = {0};
  GlimsImageID a_id = 0, b_id = 0, opened = 0;
  char *error = NULL;
  g_autofree gchar *plain = g_build_filename (work_dir, "foreign-explicit-effect-v20.xcf", NULL);
  g_autofree gchar *gzip_a = g_build_filename (work_dir, "foreign-explicit-effect-v20.xcf.gz", NULL);
  g_autofree gchar *native_b = g_build_filename (work_dir, "identity-b-native.xcf", NULL);
  g_autofree gchar *plain_b = g_build_filename (work_dir, "identity-b-explicit.xcf", NULL);
  g_autofree gchar *gzip_b = g_build_filename (work_dir, "identity-b.xcf.gz", NULL);
  g_autofree gchar *alias = g_build_filename (work_dir, "identity-original.xcf.gz", NULL);
  g_autofree gchar *next = g_build_filename (work_dir, "identity-next", NULL);
  g_autofree gchar *a_bytes = NULL, *b_bytes = NULL, *b_native = NULL, *restored = NULL;
  gsize a_size = 0, b_size = 0, native_size = 0;
  gboolean own_alias = FALSE;
  gfloat a_rendered[COMPONENTS], b_raw[COMPONENTS], b_rendered[COMPONENTS];
  gfloat a_mask[WIDTH * HEIGHT], actual_mask[WIDTH * HEIGHT], actual[COMPONENTS];
  EffectRecord record = {0}, patched = {0};
  static const guint32 other_values[] = {1, 1, 1};
  G_STATIC_ASSERT (GIMP_LAYER_COLOR_SPACE_RGB_LINEAR == 1);
  G_STATIC_ASSERT (GIMP_LAYER_COMPOSITE_UNION == 1);

  NEED (api->image_open (engine, plain, &a_id, &error) == GLIMS_STATUS_OK &&
        opened_fixture (engine, a_id, &a), "identity A is the independently validated legacy oracle");
  GimpDrawableFilter *effect = one_effect (&a);
  NEED (effect && explicit_fields (effect) && read_pixels (&a, TRUE, a_rendered) &&
        read_effect_mask (effect, a_mask), "identity A provides explicit fields, rendered pixels and native mask");

  memcpy (b_raw, source_pixels, sizeof b_raw);
  b_raw[0] = .88f;
  b_raw[5] = .82f;
  b_raw[27] = .3125f;
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (a.layer)),
      GEGL_RECTANGLE (0, 0, WIDTH, HEIGHT), 0, babl_format ("RGBA float"), b_raw, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (a.layer), 0, 0, WIDTH, HEIGHT);
  gimp_drawable_filter_set_mode (effect, GIMP_LAYER_MODE_MULTIPLY, GIMP_LAYER_COLOR_SPACE_RGB_LINEAR,
      GIMP_LAYER_COLOR_SPACE_RGB_LINEAR, GIMP_LAYER_COMPOSITE_UNION);
  NEED (second_fields (effect) && read_pixels (&a, TRUE, b_rendered) &&
        pixel_delta (a_rendered, b_rendered) > .05, "identity B differs in pixels and fields with the same effect topology");
  NEED (native_save (&a, native_b) && read_file (native_b, &b_native, &native_size) &&
        no_glims_namespace ((guint8 *) b_native, native_size) &&
        locate_record ((guint8 *) b_native, native_size, &record), "B's separate native save has the validated foreign record");
  for (guint i = 0; i < G_N_ELEMENTS (other_values); i++) {
    guint32 value = GUINT32_TO_BE (other_values[i]);
    memcpy (b_native + record.fields[i], &value, sizeof value);
  }
  NEED (locate_record ((guint8 *) b_native, native_size, &patched) &&
        !memcmp (patched.fields, record.fields, sizeof record.fields) &&
        !memcmp (patched.values, other_values, sizeof other_values) &&
        g_file_set_contents (plain_b, b_native, (gssize) native_size, NULL) &&
        gzip_write_oracle (gzip_b, (guint8 *) b_native, native_size),
        "identity B's only patched payloads are the three validated words, then the independent gzip round-trip");
  NEED (api->image_open (engine, plain_b, &b_id, &error) == GLIMS_STATUS_OK &&
        opened_fixture (engine, b_id, &b) && second_fields (one_effect (&b)) &&
        read_pixels (&b, FALSE, actual) && !memcmp (actual, b_raw, sizeof actual) &&
        read_pixels (&b, TRUE, actual) && pixel_delta (actual, b_rendered) < 2e-4,
        "identity B independently reopens with its own raw and rendered pixels and different native fields");
  NEED (read_file (gzip_a, &a_bytes, &a_size) && read_file (gzip_b, &b_bytes, &b_size),
        "both original gzip members are captured before changing the owned alias");
  own_alias = symlink (gzip_a, alias) == 0;
  NEED (own_alias, "fixture creates a private alias initially pointing to A");
  alias_path = alias;
  first_path = gzip_a;
  second_path = gzip_b;
  next_path = next;
  alias_file = g_file_new_for_path (alias);
  GlimsStatus status = api->image_open (engine, alias, &opened, &error);
  printf ("OBS alias path_calls=%u stream_calls=%u status=%d\n", path_calls, stream_calls, (int) status);
  restored = g_file_read_link (alias, NULL);
  CHECK (path_calls + stream_calls == 1 && !g_strcmp0 (restored, gzip_a),
         "the native boundary witnesses one A to B to A switch on the fixture alias");
  CHECK (stream_calls == 1 && !path_calls && original_link_base,
         "native loads the retained stream with the original alias and its lexical parent");
  CHECK (gzip_unchanged (gzip_a, a_bytes, a_size) && gzip_unchanged (gzip_b, b_bytes, b_size),
         "neither original gzip member is modified by the swap or open");
  NEED (status == GLIMS_STATUS_OK && !error && opened_fixture (engine, opened, &loaded),
        "the open publishes exactly one valid image despite the alias switch");
  GimpPlugInProcedure *procedure = gimp_image_get_load_proc (loaded.image);
  CHECK (original_gzip_file (loaded.image, alias_file) && clean_open (&loaded) &&
         procedure && !g_strcmp0 (gimp_object_get_name (GIMP_OBJECT (procedure)), "gimp-xcf-load"),
         "native image retains original file identity, XCF load procedure and clean history");
  effect = one_effect (&loaded);
  CHECK (effect && explicit_fields (effect) && read_effect_mask (effect, actual_mask) &&
         !memcmp (actual_mask, a_mask, sizeof actual_mask),
         "image publishes exactly A's explicit fields and native mask");
  gboolean raw_read = read_pixels (&loaded, FALSE, actual);
  gboolean raw_is_a = raw_read && !memcmp (actual, source_pixels, sizeof actual);
  printf ("OBS alias raw_matches_A=%d raw_matches_B=%d\n", raw_is_a,
          raw_read && !memcmp (actual, b_raw, sizeof actual));
  CHECK (raw_is_a && read_pixels (&loaded, TRUE, actual) && pixel_delta (actual, a_rendered) < 2e-4,
         "native pixels and recovered effect fields both come from A");
cleanup:
  if (error) fprintf (stderr, "OBS identity facade open: %s\n", error);
  clear_error (&error);
  if (opened) CHECK (api->image_close (engine, opened) == GLIMS_STATUS_OK, "identity image closes");
  if (b_id) api->image_close (engine, b_id);
  if (a_id) api->image_close (engine, a_id);
  g_clear_object (&alias_file);
  if (own_alias) CHECK (g_unlink (alias) == 0, "fixture removes its alias");
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api) return 2;
  g_autofree gchar *user = g_build_filename (work_dir, "user", NULL);
  g_autofree gchar *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    clear_error (&error);
    return 2;
  }
  CHECK (glims_engine_call (engine, regression, NULL) == GLIMS_STATUS_OK,
         "foreign XCF regression runs on the real engine worker");
  if (!failures)
    CHECK (glims_engine_call (engine, identity_regression, NULL) == GLIMS_STATUS_OK,
           "gzip identity regression runs on the real engine worker");
  api->stop (engine);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures != 0;
}
