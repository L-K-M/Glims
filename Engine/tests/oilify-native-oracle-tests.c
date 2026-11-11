/* Direct GEGL and Core behavior oracle. Existing facade calls only start the
 * engine, create/select/close fixtures and read native history. */
#define main oilify_existing_input_main
#include "filter-input-tests.c"
#undef main
#undef CHECK
#undef NEED
#include <glib/gstdio.h>

#define OILIFY "gegl:oilify"
#define RAW_SIDE 5
#define RAW_PIXELS (RAW_SIDE * RAW_SIDE)
#define RAW_FLOATS (RAW_PIXELS * 4)
static gint oilify_checks;
static gchar *oilify_artifacts;
#define CHECK(c, text) do { \
  gboolean ok_ = (c); oilify_checks++; \
  printf ("%s Oilify oracle: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); \
} while (0)
#define NEED(c, text) do { \
  gboolean need_ok_ = (c); CHECK (need_ok_, text); \
  if (!need_ok_) goto cleanup; \
} while (0)

static gboolean
save_pixels (const gchar *name, const void *bytes, gsize size)
{
  gchar *path = g_build_filename (oilify_artifacts, name, NULL);
  GError *error = NULL;
  gboolean ok = !g_file_test (path, G_FILE_TEST_EXISTS) &&
                g_file_set_contents (path, bytes, (gssize) size, &error);
  if (!ok) fprintf (stderr, "Artifact %s: %s\n", name, error ? error->message : "already exists");
  g_clear_error (&error);
  g_free (path);
  return ok;
}

static GeglBuffer *
oilify_buffer (const GeglRectangle *extent, const Babl *format, const void *bytes)
{
  GeglBuffer *buffer = gegl_buffer_new (extent, format);
  if (buffer) gegl_buffer_set (buffer, extent, 0, format, bytes, GEGL_AUTO_ROWSTRIDE);
  return buffer;
}

static gboolean
oilify_connect (GeglNode *source, GeglNode *op, const gchar *pad)
{
  gboolean connected;
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  connected = gegl_node_connect_to (source, "output", op, pad);
  G_GNUC_END_IGNORE_DEPRECATIONS
  return connected;
}

static GeglNode *
oilify_node (GeglNode *graph, gint radius, gint exponent, gint intensities, gboolean use_inten)
{
  return gegl_node_new_child (graph, "operation", OILIFY,
                              "mask-radius", radius, "exponent", exponent,
                              "intensities", intensities, "use-inten", use_inten, NULL);
}

static gboolean
close_float (gfloat actual, gdouble expected)
{
  return isfinite (actual) && fabs ((gdouble) actual - expected) <= 0.000002;
}

static gboolean
same_floats (const gfloat *a, const gfloat *b, guint count)
{
  for (guint i = 0; i < count; i++)
    if (!close_float (a[i], b[i])) return FALSE;
  return TRUE;
}

static gboolean
raw_oilify (const gchar *label, GeglBuffer *input, GeglBuffer *radius, GeglBuffer *exponent,
            gint radius_value, gint exponent_value, gint intensities, gboolean use_inten,
            gfloat pixels[RAW_FLOATS], GeglRectangle *bounds)
{
  const GeglRectangle roi = {0, 0, RAW_SIDE, RAW_SIDE};
  GeglNode *graph = gegl_node_new ();
  GeglNode *in = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", input, NULL);
  GeglNode *op = oilify_node (graph, radius_value, exponent_value, intensities, use_inten);
  gboolean ok = in && op && oilify_connect (in, op, "input");
  if (ok) {
    gint radius_read = 0, exponent_read = 0, intensities_read = 0;
    gboolean intensity_mode_read = FALSE;
    gegl_node_get (op, "mask-radius", &radius_read, "exponent", &exponent_read,
                   "intensities", &intensities_read, "use-inten", &intensity_mode_read, NULL);
    ok = radius_read == radius_value && exponent_read == exponent_value &&
         intensities_read == intensities && intensity_mode_read == use_inten;
  }
  GeglBuffer *maps[] = {radius, exponent};
  const gchar *pads[] = {"aux", "aux2"};
  for (guint i = 0; ok && i < G_N_ELEMENTS (maps); i++) {
    if (!maps[i]) continue;
    GeglNode *node = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", maps[i], NULL);
    ok = node && oilify_connect (node, op, pads[i]);
  }
  if (ok) {
    *bounds = gegl_node_get_bounding_box (op);
    for (guint i = 0; i < RAW_FLOATS; i++) pixels[i] = NAN;
    gint64 start = g_get_monotonic_time ();
    gegl_node_blit (op, 1.0, &roi, babl_format ("RGBA float"), pixels,
                    GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
    gint64 elapsed = g_get_monotonic_time () - start;
    for (guint i = 0; i < RAW_FLOATS; i++) if (!isfinite (pixels[i])) ok = FALSE;
    gchar *name = g_strdup_printf ("raw-%s.rgba-f32", label);
    ok = save_pixels (name, pixels, RAW_FLOATS * sizeof (gfloat)) && ok;
    g_free (name);
    const gfloat *center = pixels + 4 * (2 * RAW_SIDE + 2);
    printf ("OBS raw %s bounds=%d,%d,%d,%d center=%.9g,%.9g,%.9g,%.9g elapsed_us=%" G_GINT64_FORMAT "\n",
            label, bounds->x, bounds->y, bounds->width, bounds->height,
            center[0], center[1], center[2], center[3], elapsed);
  }
  g_object_unref (graph);
  return ok;
}

static gboolean
center_is (const gfloat *pixels, gdouble gray, gdouble alpha)
{
  const gfloat *center = pixels + 4 * (2 * RAW_SIDE + 2);
  return close_float (center[0], gray) && close_float (center[1], gray) &&
         close_float (center[2], gray) && close_float (center[3], alpha);
}

static void
raw_cases (void)
{
  enum { BLACK, HIGH, NEGATIVE, FRACTION_EXP, FRACTION_RADIUS, RADIUS_EXTENT,
         EXPONENT_EXTENT, TINY, ALPHA_LOW, ALPHA_HIGH, MAP_COUNT };
  GeglBuffer *input = NULL, *maps[MAP_COUNT] = {NULL};
  GeglRectangle roi = {0, 0, RAW_SIDE, RAW_SIDE}, bounds;
  const GeglRectangle radius_extent = {-1, -1, 4, 6}, exponent_extent = {1, 0, 6, 5}, tiny = {2, 2, 1, 1};
  gfloat target[RAW_FLOATS], values[30], alpha_values[RAW_FLOATS];
  gfloat plain[RAW_FLOATS], zero_exp[RAW_FLOATS], frac_exp[RAW_FLOATS];
  gfloat out[RAW_FLOATS], alpha_low[RAW_FLOATS];
  for (gint y = 0; y < RAW_SIDE; y++) for (gint x = 0; x < RAW_SIDE; x++) {
    gfloat *p = target + 4 * (y * RAW_SIDE + x);
    p[0] = 0.0625f + 0.0625f * x; p[1] = 0.125f + 0.0625f * y;
    p[2] = 0.1875f + 0.03125f * (x + 2 * y); p[3] = 0.25f + 0.0625f * (x + y);
    if (x >= 1 && x <= 3 && y >= 1 && y <= 3) {
      gboolean bright = (x == 2) == (y == 2);
      p[0] = p[1] = p[2] = bright ? 0.875f : 0.125f;
      p[3] = bright ? 0.75f : 0.25f;
    }
  }
  input = oilify_buffer (&roi, babl_format ("RGBA float"), target);
  NEED (input && save_pixels ("raw-input.rgba-f32", target, sizeof target), "bounded literal linear RGBA input is retained");
  const gfloat scales[] = {0.f, 1.25f, -0.25f, 0.49f, 0.75f};
  for (guint i = 0; i < G_N_ELEMENTS (scales); i++) {
    for (guint j = 0; j < RAW_PIXELS; j++) values[j] = scales[i];
    maps[i] = oilify_buffer (&roi, babl_format ("Y float"), values);
  }
  for (guint i = 0; i < 24; i++) values[i] = 1.f;
  values[5] = 0.f; /* (0,0) in radius_extent; the center remains white. */
  maps[RADIUS_EXTENT] = oilify_buffer (&radius_extent, babl_format ("Y float"), values);
  memset (values, 0, sizeof values);
  maps[EXPONENT_EXTENT] = oilify_buffer (&exponent_extent, babl_format ("Y float"), values);
  const gfloat tiny_value = 0.49f;
  maps[TINY] = oilify_buffer (&tiny, babl_format ("Y float"), &tiny_value);
  for (guint i = ALPHA_LOW; i <= ALPHA_HIGH; i++) {
    for (guint j = 0; j < RAW_PIXELS; j++) {
      gfloat *p = alpha_values + 4 * j;
      p[0] = p[1] = p[2] = 0.49f;
      p[3] = i == ALPHA_LOW ? 0.25f : 1.f;
    }
    maps[i] = oilify_buffer (&roi, babl_format ("RGBA float"), alpha_values);
  }
  for (guint i = 0; i < MAP_COUNT; i++) if (!maps[i]) { CHECK (FALSE, "finite fixture maps allocate"); goto cleanup; }
  CHECK (TRUE, "finite fixture maps allocate");
  NEED (raw_oilify ("plain", input, NULL, NULL, 1, 8, 8, TRUE, plain, &bounds), "plain Oilify renders with both pads absent");
  const gdouble weight = 1.0 / 65536.0;
  CHECK (gegl_rectangle_equal (&bounds, &roi) &&
         center_is (plain, (0.125 + weight * 0.875) / (1 + weight), (0.25 + weight * 0.75) / (1 + weight)),
         "plain center follows the literal four-to-one radius-one histogram and mixes alpha");
  NEED (raw_oilify ("radius-zero", input, maps[BLACK], NULL, 1, 8, 8, TRUE, out, &bounds), "radius-only graph renders");
  CHECK (same_floats (out, target, RAW_FLOATS), "black radius map makes Intensity mode sample only the center pixel");
  NEED (raw_oilify ("exponent-zero", input, NULL, maps[BLACK], 1, 8, 8, TRUE, zero_exp, &bounds), "exponent-only graph renders");
  CHECK (center_is (zero_exp, 0.5, 0.5), "black exponent map gives equal weights to the two occupied bins");
  NEED (raw_oilify ("both-offset-extents", input, maps[RADIUS_EXTENT], maps[EXPONENT_EXTENT], 1, 8, 8, TRUE, out, &bounds), "both native map extents render");
  const GeglRectangle union_extent = {-1, -1, 8, 6};
  CHECK (gegl_rectangle_equal (&bounds, &union_extent) && center_is (out, 0.5, 0.5)
         && same_floats (out, target, 4), "union bounds and distinct radius/exponent roles match literal center and corner facts");
  NEED (raw_oilify ("radius-high-clamp", input, maps[HIGH], NULL, 1, 8, 8, TRUE, out, &bounds), "finite high map renders");
  CHECK (same_floats (out, plain, RAW_FLOATS), "luminance above one clamps to full scalar radius");
  NEED (raw_oilify ("exponent-low-clamp", input, NULL, maps[NEGATIVE], 1, 8, 8, TRUE, out, &bounds), "finite negative map renders");
  CHECK (same_floats (out, zero_exp, RAW_FLOATS), "negative luminance clamps to zero exponent");
  NEED (raw_oilify ("fractional-exponent", input, NULL, maps[FRACTION_EXP], 1, 8, 8, TRUE, frac_exp, &bounds), "fractional exponent map renders");
  CHECK (center_is (frac_exp, (0.125 * 64 + 0.875) / 65, (0.25 * 64 + 0.75) / 65),
         "scaled exponent 3.92 truncates to three");
  NEED (raw_oilify ("tiny-exponent-map", input, NULL, maps[TINY], 1, 8, 8, TRUE, out, &bounds), "one-pixel native map renders over wider result");
  CHECK (same_floats (out, frac_exp, RAW_FLOATS), "map edge clamping extends the one-pixel luminance across this ROI");
  NEED (raw_oilify ("fractional-radius", input, maps[FRACTION_RADIUS], NULL, 2, 1, 8, TRUE, out, &bounds), "fractional radius map renders");
  CHECK (center_is (out, (4 * 0.125 + 5 * 0.875) / 9, (4 * 0.25 + 5 * 0.75) / 9),
         "radius 1.5 includes four diagonal samples and excludes distance two");
  NEED (raw_oilify ("map-alpha-low", input, NULL, maps[ALPHA_LOW], 1, 8, 8, TRUE, alpha_low, &bounds) &&
        raw_oilify ("map-alpha-high", input, NULL, maps[ALPHA_HIGH], 1, 8, 8, TRUE, out, &bounds), "straight RGBA maps with different alpha render");
  CHECK (same_floats (alpha_low, out, RAW_FLOATS) && same_floats (out, frac_exp, RAW_FLOATS),
         "map alpha does not scale the equal linear luminance in these straight RGBA buffers");
  NEED (raw_oilify ("channel-mode", input, maps[BLACK], NULL, 1, 8, 8, FALSE, out, &bounds), "per-channel Oilify renders");
  CHECK (center_is (out, 6.0 / 7.0, 5.0 / 7.0), "per-channel mode quantizes even the radius-zero color and alpha");
  CHECK (raw_oilify ("max-radius-small-roi", input, maps[HIGH], NULL, 100, 20, 256, TRUE, out, &bounds),
         "maximum scalar values render a bounded 5x5 CPU result");
cleanup:
  g_clear_object (&input);
  for (guint i = 0; i < MAP_COUNT; i++) g_clear_object (&maps[i]);
}

static gboolean
core_pixels_in_selection (const guint8 *before, const guint8 *after, gboolean *changed_alpha)
{
  gboolean changed = FALSE;
  *changed_alpha = FALSE;
  /* Image selection (9,11)..(23,26), target item at (3,4). */
  for (gint y = 0; y < SIDE; y++) for (gint x = 0; x < SIDE; x++) {
    guint i = 4 * (y * SIDE + x);
    gboolean inside = x >= 6 && x < 20 && y >= 7 && y < 22;
    if (memcmp (before + i, after + i, 4) == 0) continue;
    if (!inside) return FALSE;
    changed = TRUE;
    if (before[i + 3] != after[i + 3]) *changed_alpha = TRUE;
  }
  return changed;
}

static gboolean
save_core (const gchar *label, const gchar *stage, const guint8 pixels[BYTES])
{
  gchar *name = g_strdup_printf ("core-%s-%s.rgba-u8", label, stage);
  gboolean ok = save_pixels (name, pixels, BYTES);
  g_free (name);
  return ok;
}

static void
core_case (GlimsEngine *engine, gboolean with_maps)
{
  Fixture f = {0};
  const gchar *label = with_maps ? "both-maps" : "plain";
  GeglNode *op = NULL, *radius = NULL, *exponent = NULL;
  GeglBuffer *rmap = NULL, *emap = NULL;
  GimpDrawableFilter *filter = NULL;
  gboolean attached = FALSE, changed_alpha;
  guint8 before[BYTES], preview[BYTES], actual[BYTES], applied[BYTES];
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  gint x = 0, y = 0;
  NEED (fixture_open (engine, &f, FALSE), "direct Core fixture opens a small native target");
  gimp_item_set_offset (GIMP_ITEM (f.target), 3, 4);
  gimp_item_set_offset (GIMP_ITEM (f.source), -5, 7);
  const GlimsPoint corners[] = {{9, 11}, {23, 26}};
  GlimsSelectOptions options = {.struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE};
  NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK &&
        read_pixels (f.target, FALSE, before) &&
        api->image_undo_info (engine, f.id, &undo_before) == GLIMS_STATUS_OK && save_core (label, "before", before),
        "Core target bytes and history captured after offset and rectangular selection");
  if (with_maps) {
    guint8 source[BYTES];
    NEED (read_pixels (f.source, TRUE, source), "source snapshot uses its own drawable-local native pixels");
    GeglBuffer *live = gimp_drawable_get_buffer (GIMP_DRAWABLE (f.source));
    const GeglRectangle *extent = gegl_buffer_get_extent (live);
    NEED (extent->x == 0 && extent->y == 0 && extent->width == SIDE && extent->height == SIDE,
          "source item offset is distinct from its buffer origin");
    rmap = oilify_buffer (extent, babl_format ("R'G'B'A u8"), source);
    const gfloat black = 0.f;
    emap = oilify_buffer (GEGL_RECTANGLE (-2, 3, 1, 1), babl_format ("Y float"), &black);
    NEED (rmap && emap, "independent mapped buffers retain extent and finite samples");
    radius = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", rmap, NULL);
    exponent = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", emap, NULL);
    NEED (radius && exponent, "independent map source nodes open");
  }
  for (guint applying = 0; applying < 2; applying++) {
    op = oilify_node (NULL, 6, 8, 16, TRUE);
    NEED (op && (!with_maps || (oilify_connect (radius, op, "aux") && oilify_connect (exponent, op, "aux2"))),
          "direct Core Oilify graph connects the requested roles");
    filter = gimp_drawable_filter_new (GIMP_DRAWABLE (f.target), "Oilify native oracle", op, NULL);
    NEED (filter != NULL, "native drawable filter is created");
    g_object_set (filter, "to-be-merged", TRUE, NULL);
    gimp_drawable_filter_set_temporary (filter, TRUE);
    gimp_drawable_filter_apply (filter, NULL); attached = TRUE;
    gimp_drawable_filter_set_preview (filter, TRUE);
    gimp_image_flush (f.image);
    NEED (read_pixels (f.target, TRUE, preview) && read_pixels (f.target, FALSE, actual) &&
          save_core (label, applying ? "apply-preview" : "cancel-preview", preview), "Core preview bytes are retained");
    CHECK (!memcmp (before, actual, BYTES) && undo_equal (engine, f.id, &undo_before), "preview keeps stored bytes and history intact");
    CHECK (core_pixels_in_selection (before, preview, &changed_alpha), "offset preview changes pixels only within the literal selection");
    printf ("OBS core %s preview=%s changed_alpha=%d\n", label, applying ? "apply" : "cancel", changed_alpha);
    if (!applying) {
      gimp_drawable_filter_abort (filter); attached = FALSE;
      gimp_image_flush (f.image);
      CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (before, actual, BYTES) &&
             undo_equal (engine, f.id, &undo_before) && save_core (label, "cancel", actual), "native Cancel restores exact pixels and history");
    } else {
      gimp_drawable_filter_layer_mask_freeze (filter);
      NEED (gimp_drawable_filter_commit (filter, FALSE, NULL, FALSE), "native Apply merges the direct graph");
      attached = FALSE;
      gimp_image_flush (f.image);
      NEED (read_pixels (f.target, FALSE, applied) && save_core (label, "apply", applied) &&
            api->image_undo_info (engine, f.id, &undo_after) == GLIMS_STATUS_OK, "merged bytes and native history are retained");
      CHECK (core_pixels_in_selection (before, applied, &changed_alpha) &&
             undo_after.undo_count == undo_before.undo_count + 1,
             "Apply changes only selected pixels and creates one native Undo");
      printf ("OBS core %s preview_equals_apply=%d applied_alpha_changed=%d\n",
              label, memcmp (preview, applied, BYTES) == 0, changed_alpha);
      gimp_item_get_offset (GIMP_ITEM (f.target), &x, &y);
      const GeglRectangle *extent = gegl_buffer_get_extent (gimp_drawable_get_buffer (GIMP_DRAWABLE (f.target)));
      CHECK (x == 3 && y == 4 && extent->width == SIDE && extent->height == SIDE,
             "clipped merge preserves target item offset and buffer dimensions");
      CHECK (gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (f.target))) == 0,
             "merged native filter leaves no committed auxiliary effect");
      NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK && read_pixels (f.target, FALSE, actual) &&
            !memcmp (before, actual, BYTES) && save_core (label, "undo", actual), "Undo restores the entire original native target");
      CHECK (api->image_redo (engine, f.id) == GLIMS_STATUS_OK && read_pixels (f.target, FALSE, actual) &&
             !memcmp (applied, actual, BYTES) && save_core (label, "redo", actual), "Redo restores the entire merged native target");
      printf ("OBS core %s item_offset=%d,%d undo_before=%d undo_after=%d\n", label, x, y,
              undo_before.undo_count, undo_after.undo_count);
    }
    g_clear_object (&filter); g_clear_object (&op);
  }
cleanup:
  if (attached) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter); g_clear_object (&op);
  g_clear_object (&radius); g_clear_object (&exponent);
  g_clear_object (&rmap); g_clear_object (&emap);
  if (f.id) {
    CHECK (api->image_close (engine, f.id) == GLIMS_STATUS_OK, "native fixture image closes");
    f.id = 0;
  }
}

static GlimsStatus
run_oilify_oracle (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  g_object_set (gegl_config (), "use-opencl", FALSE, NULL);
  CHECK (gegl_has_operation (OILIFY), "pinned producer has Oilify");
  if (!gegl_has_operation (OILIFY)) return GLIMS_STATUS_UNSUPPORTED;
  raw_cases ();
  core_case (engine, FALSE);
  core_case (engine, TRUE);
  return GLIMS_STATUS_OK;
}

#include "oilify-native-oracle-diagnostics.h"

static gboolean
private_environment (const gchar *root)
{
  const gchar *keys[] = {"HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "GIMP3_DIRECTORY", "TMPDIR", "GEGL_SWAP"};
  const gchar *leaves[] = {"home", "cache", "config", "data", "user", "tmp", "swap"};
  for (guint i = 0; i < G_N_ELEMENTS (keys); i++) {
    gchar *path = g_build_filename (root, leaves[i], NULL);
    gboolean matches = !g_strcmp0 (g_getenv (keys[i]), path) && g_file_test (path, G_FILE_TEST_IS_DIR);
    g_free (path);
    if (!matches) return FALSE;
  }
  return TRUE;
}

int
main (int argc, char **argv)
{
  gboolean diagnostics = argc == 3 && !strcmp (argv[2], "--diagnostics");
  if ((argc != 2 && !diagnostics) || !g_path_is_absolute (argv[1]) || !private_environment (argv[1])) {
    fprintf (stderr, "Run this fixture with test-oilify-native-oracle.py run and a private work directory.\n");
    return 2;
  }
  work_dir = argv[1];
  oilify_artifacts = g_build_filename (work_dir, "artifacts", NULL);
  if (g_mkdir (oilify_artifacts, 0700) != 0) { g_free (oilify_artifacts); return 2; }
  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "native engine startup failed");
    if (api) clear_error (&error);
    g_free (user); g_free (cache); g_free (oilify_artifacts);
    return 2;
  }
  CHECK (glims_engine_call (engine, run_oilify_oracle, NULL) == GLIMS_STATUS_OK, "direct native cases execute on the engine thread");
  if (diagnostics && !failures) {
    PROBE (glims_engine_call (engine, run_oilify_diagnostics, NULL) == GLIMS_STATUS_OK,
           "comparison controls execute on the engine thread");
    printf ("Oilify diagnostic checks: %d, failures: %d\n", oilify_diagnostic_checks, oilify_diagnostic_failures);
  }
  api->stop (engine);
  g_free (user); g_free (cache); g_free (oilify_artifacts);
  printf ("%s: %d Oilify oracle checks, %d failures\n", failures ? "FAILED" : "PASSED", oilify_checks, failures);
  return failures != 0 || oilify_diagnostic_failures != 0;
}
