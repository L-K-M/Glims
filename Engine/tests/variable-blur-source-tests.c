/* Independent raw GEGL oracle for the admitted snapshot-input contract.
 * Reuse fixture/lifecycle helpers without copying native private layouts. */
#define main filter_input_original_main
#include "filter-input-tests.c"
#undef main

#define VARIABLE_BLUR "gegl:variable-blur"

typedef struct {
  gdouble radius;
  gboolean linear_mask, high_quality;
  gint levels;
  gdouble gamma;
} BlurSettings;

static gboolean
has_native_property (const gchar *name)
{
  return gegl_operation_find_property (VARIABLE_BLUR, name) != NULL;
}

static void
write_blur_fixture (Fixture *f)
{
  guint8 target[BYTES], mask[BYTES];
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    target[i] = ((x / 2 + y / 3) & 1) ? 231 : 19;
    target[i + 1] = (x * 29 + y * 13) % 256;
    target[i + 2] = (x * 7 + y * 47) % 256;
    target[i + 3] = 48 + (x * 11 + y * 17) % 208;
    mask[i] = mask[i + 1] = mask[i + 2] = (x * 5 + y * 19 + (x > 19 ? 83 : 0)) % 256;
    mask[i + 3] = 255;
  }
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->target));
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("R'G'B'A u8"), target, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->target), 0, 0, SIDE, SIDE);
  buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->source));
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("R'G'B'A u8"), mask, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->source), 0, 0, SIDE, SIDE);
}

/* The oracle owns fresh buffers and graph nodes. It neither calls the
 * production snapshot helper nor reads the preview's operation or aux node. */
static gboolean
raw_blur_oracle (const guint8 target[BYTES], const guint8 mask[BYTES],
                 const Babl *target_format, const Babl *mask_format,
                 const BlurSettings *settings, guint8 output[BYTES])
{
  GeglBuffer *input = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), target_format);
  GeglBuffer *aux = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), mask_format);
  GeglNode *graph = gegl_node_new ();
  gboolean ok = FALSE;
  if (!input || !aux || !graph) goto cleanup;
  gegl_buffer_set (input, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("R'G'B'A u8"), target, GEGL_AUTO_ROWSTRIDE);
  gegl_buffer_set (aux, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("R'G'B'A u8"), mask, GEGL_AUTO_ROWSTRIDE);
  GeglNode *input_node = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", input, NULL);
  GeglNode *mask_node = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", aux, NULL);
  GeglNode *blur = gegl_node_new_child (graph, "operation", VARIABLE_BLUR,
                                       "radius", settings->radius,
                                       "linear-mask", settings->linear_mask, NULL);
  if (!input_node || !mask_node || !blur) goto cleanup;
  if (has_native_property ("high-quality"))
    gegl_node_set (blur, "high-quality", settings->high_quality, NULL);
  if (has_native_property ("levels")) gegl_node_set (blur, "levels", settings->levels, NULL);
  if (has_native_property ("gamma")) gegl_node_set (blur, "gamma", settings->gamma, NULL);
  if (!gegl_node_connect_to (input_node, "output", blur, "input") ||
      !gegl_node_connect_to (mask_node, "output", blur, "aux")) goto cleanup;
  gegl_node_blit (blur, 1.0, GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"),
                  output, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  ok = TRUE;
cleanup:
  g_clear_object (&graph); g_clear_object (&aux); g_clear_object (&input);
  return ok;
}

static gboolean
pixels_near (const guint8 *actual, const guint8 *expected)
{
  for (guint i = 0; i < BYTES; i++)
    if (ABS ((int) actual[i] - (int) expected[i]) > 1) return FALSE;
  return TRUE;
}

static gboolean
set_blur_settings (GlimsEngine *engine, GlimsFilterID filter, const BlurSettings *settings)
{
  GlimsFilterValue radius = { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = settings->radius };
  GlimsFilterValue linear = { .kind = GLIMS_FILTER_VALUE_BOOL, .boolean = settings->linear_mask };
  GlimsFilterValue quality = { .kind = GLIMS_FILTER_VALUE_BOOL, .boolean = settings->high_quality };
  GlimsFilterValue levels = { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = settings->levels };
  GlimsFilterValue gamma = { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = settings->gamma };
  if (api->filter_set_property (engine, filter, "radius", &radius) != GLIMS_STATUS_OK ||
      api->filter_set_property (engine, filter, "linear-mask", &linear) != GLIMS_STATUS_OK) return FALSE;
  if (has_native_property ("high-quality") &&
      api->filter_set_property (engine, filter, "high-quality", &quality) != GLIMS_STATUS_OK) return FALSE;
  if (has_native_property ("levels") &&
      api->filter_set_property (engine, filter, "levels", &levels) != GLIMS_STATUS_OK) return FALSE;
  if (has_native_property ("gamma") &&
      api->filter_set_property (engine, filter, "gamma", &gamma) != GLIMS_STATUS_OK) return FALSE;
  return TRUE;
}

static GlimsStatus
blur_catalog (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  int32_t count = 0;
  NEED (api->filter_operations (engine, NULL, 0, &count) == GLIMS_STATUS_OK && count > 0,
        "the installed engine exposes a real operation catalog");
  GlimsOperationInfo *rows = g_new0 (GlimsOperationInfo, count);
  GlimsStatus status = api->filter_operations (engine, rows, count, &count);
  gboolean found = FALSE;
  if (status == GLIMS_STATUS_OK) for (gint i = 0; i < count; i++)
    if (!strcmp (rows[i].name, VARIABLE_BLUR)) found = rows[i].support == GLIMS_FILTER_OP_AUX_INPUT;
  g_free (rows);
  CHECK (found, "Variable Blur is installed and classified as an auxiliary-input operation");
  CHECK (has_native_property ("radius") && has_native_property ("linear-mask"),
         "Variable Blur exposes actual radius and linear-mask properties");
  CHECK (has_native_property ("high-quality") ||
         (has_native_property ("levels") && has_native_property ("gamma")),
         "quality properties follow the installed normal/manual build variant");
cleanup:
  return GLIMS_STATUS_OK;
}

static GlimsStatus
blur_oracle_and_history (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  static const BlurSettings settings[] = {
    { 3.75, FALSE, FALSE, 5, 1.25 },
    { 7.25, TRUE, TRUE, 11, 1.75 },
    { 5.5, FALSE, TRUE, 7, 2.25 }
  };
  for (guint mode = 0; mode < G_N_ELEMENTS (settings); mode++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
    guint8 original[BYTES], mask[BYTES], expected[BYTES], preview[BYTES], actual[BYTES], committed[BYTES];
    GlimsUndoInfo before = {0}, after = {0};
    NEED (fixture_open (engine, &f, FALSE), "Variable Blur fixture opens");
    write_blur_fixture (&f);
    NEED (read_pixels (f.target, FALSE, original) && read_pixels (f.source, FALSE, mask) &&
          api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK,
          "textured partial-alpha target, asymmetric mask and history are captured independently");
    CHECK (original[3] > 0 && original[3] < 255 && mask[0] != mask[(SIDE - 1) * 4],
           "the fixture contains real partial alpha and nonconstant source values");
    const Babl *target_format = gimp_drawable_get_format (GIMP_DRAWABLE (f.target));
    const Babl *mask_format = gimp_drawable_get_format (GIMP_DRAWABLE (f.source));
    NEED (raw_blur_oracle (original, mask, target_format, mask_format, &settings[mode], expected),
          "an independent raw GEGL graph produces the exact configured-mask oracle");
    CHECK (!pixels_near (original, expected), "the oracle visibly changes the texture so absent blur cannot pass");
    gimp_item_set_lock_content (GIMP_ITEM (f.source), TRUE, FALSE);
    NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), VARIABLE_BLUR,
                                        item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && filter > 0,
          "facade admits a Variable Blur snapshot from a read-only locked source");
    NEED (set_blur_settings (engine, filter, &settings[mode]) && read_pixels (f.target, TRUE, preview),
          "the facade accepts installed quality controls and renders the configured preview");
    CHECK (pixels_near (preview, expected), "all preview RGBA bytes match the independent masked GEGL oracle within one level");
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) &&
           read_pixels (f.source, FALSE, actual) && !memcmp (mask, actual, BYTES) && undo_equal (engine, f.id, &before),
           "preview preserves stored target/source bytes and exact native history");
    if (!has_native_property ("levels")) {
      GlimsFilterValue value = { .kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 6 };
      CHECK (api->filter_set_property (engine, filter, "levels", &value) == GLIMS_STATUS_NOT_FOUND,
             "normal builds do not invent an inaccessible levels control");
    }
    if (!has_native_property ("gamma")) {
      GlimsFilterValue value = { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = 1.75 };
      CHECK (api->filter_set_property (engine, filter, "gamma", &value) == GLIMS_STATUS_NOT_FOUND,
             "normal builds do not invent an inaccessible gamma control");
    }
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Variable Blur preview cancels"); filter = 0;
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) && undo_equal (engine, f.id, &before),
           "Cancel preserves every stored target byte and all history facts");
    NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), VARIABLE_BLUR,
                                        item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
          set_blur_settings (engine, filter, &settings[mode]), "a fresh configured Variable Blur preview starts for Apply");
    NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "Variable Blur applies to target pixels"); filter = 0;
    NEED (read_pixels (f.target, FALSE, committed), "applied raw target bytes are readable");
    CHECK (pixels_near (committed, expected), "Apply matches the independent raw oracle within one level");
    CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
           "Apply adds exactly one native Undo step");
    int32_t effects = -1;
    CHECK (api->drawable_effects (engine, f.id, item_id (f.target), NULL, 0, &effects) == GLIMS_STATUS_OK && effects == 0,
           "Apply leaves no persisted auxiliary non-destructive effect");
    CHECK (read_pixels (f.source, FALSE, actual) && !memcmp (mask, actual, BYTES), "Apply leaves the captured mask source unchanged");
    NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "Variable Blur Apply undoes once");
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES), "Undo restores the original target byte-for-byte");
    NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "Variable Blur Apply redoes once");
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (committed, actual, BYTES), "Redo restores the committed target byte-for-byte");
cleanup:
    if (filter) api->filter_abort (engine, filter);
    clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
blur_snapshot_independence (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 original[BYTES], mask[BYTES], oracle[BYTES], preview[BYTES], actual[BYTES];
  const BlurSettings settings = { 6.25, TRUE, TRUE, 9, 1.75 };
  GWeakRef source_weak; gboolean weak_initialized = FALSE;
  NEED (fixture_open (engine, &f, FALSE), "snapshot-independence Variable Blur fixture opens");
  write_blur_fixture (&f);
  NEED (read_pixels (f.target, FALSE, original) && read_pixels (f.source, FALSE, mask), "snapshot oracle captures original buffers");
  NEED (raw_blur_oracle (original, mask, gimp_drawable_get_format (GIMP_DRAWABLE (f.target)),
                        gimp_drawable_get_format (GIMP_DRAWABLE (f.source)), &settings, oracle),
        "snapshot-independence oracle owns unrelated input and mask storage");
  NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), VARIABLE_BLUR,
                                      item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        set_blur_settings (engine, filter, &settings) && read_pixels (f.target, TRUE, preview),
        "snapshot-independence preview starts through the facade");
  CHECK (pixels_near (preview, oracle), "captured preview matches the independent pre-edit mask oracle");
  g_weak_ref_init (&source_weak, G_OBJECT (f.source)); weak_initialized = TRUE;
  write_pixels (f.source, FALSE, FALSE); /* Bypass the public active-preview gate deliberately. */
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES),
         "editing the live mask after Begin cannot change the captured preview");
  gimp_image_remove_layer (f.image, f.source, FALSE, NULL); f.source = NULL;
  gimp_image_undo_free (f.image);
  GObject *probe = g_weak_ref_get (&source_weak);
  CHECK (probe == NULL, "deleted source finalizes after its history is purged"); g_clear_object (&probe);
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES),
         "the preview survives full source deletion with exact captured output");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "source-independent preview cancels"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES), "source-independent Cancel preserves raw target pixels");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (weak_initialized) g_weak_ref_clear (&source_weak);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
blur_refusal_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}, other = {0};
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &other, FALSE), "Variable Blur refusal fixtures open");
  GlimsItemID target = item_id (f.target), source = item_id (f.source);
  refuses (&f, f.id, 0, VARIABLE_BLUR, source, GLIMS_STATUS_INVALID_ARGUMENT, "Variable Blur refuses implicit target");
  refuses (&f, f.id, target, VARIABLE_BLUR, 0, GLIMS_STATUS_INVALID_ARGUMENT, "Variable Blur refuses implicit source");
  refuses (&f, INT_MAX, target, VARIABLE_BLUR, source, GLIMS_STATUS_NOT_FOUND, "Variable Blur refuses stale image");
  refuses (&f, f.id, INT_MAX, VARIABLE_BLUR, source, GLIMS_STATUS_NOT_FOUND, "Variable Blur refuses stale target");
  refuses (&f, f.id, target, VARIABLE_BLUR, INT_MAX, GLIMS_STATUS_NOT_FOUND, "Variable Blur refuses stale source");
  refuses (&f, f.id, target, VARIABLE_BLUR, item_id (other.source), GLIMS_STATUS_NOT_FOUND, "Variable Blur refuses cross-image source");
  refuses (&f, f.id, item_id (other.target), VARIABLE_BLUR, source, GLIMS_STATUS_NOT_FOUND, "Variable Blur refuses cross-image target");
  GimpLayer *stale = add_layer (f.image, "Removed mask source", FALSE, FALSE);
  NEED (stale != NULL, "Variable Blur stale-source fixture attaches");
  GlimsItemID stale_id = item_id (stale);
  gimp_image_remove_layer (f.image, stale, TRUE, NULL);
  refuses (&f, f.id, target, VARIABLE_BLUR, stale_id, GLIMS_STATUS_NOT_FOUND, "Variable Blur refuses detached Undo-retained source");
  GimpLayer *group = gimp_group_layer_new (f.image);
  NEED (gimp_image_add_layer (f.image, group, NULL, 0, FALSE), "Variable Blur group target fixture attaches");
  refuses (&f, f.id, item_id (group), VARIABLE_BLUR, source, GLIMS_STATUS_UNSUPPORTED, "Variable Blur refuses group merge target");
  refuses (&f, f.id, item_id (gimp_image_get_mask (f.image)), VARIABLE_BLUR, source, GLIMS_STATUS_UNSUPPORTED,
           "Variable Blur refuses a nonlayer target");
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "T", "font",
                                 gimp_context_get_font (gimp_get_user_context (engine->gimp)),
                                 "font-size", 8.0, NULL);
  GimpLayer *editable = gimp_text_layer_new (f.image, text); g_object_unref (text);
  NEED (editable && gimp_image_add_layer (f.image, editable, NULL, 0, FALSE),
        "Variable Blur genuine editable-text target fixture attaches");
  refuses (&f, f.id, item_id (editable), VARIABLE_BLUR, source, GLIMS_STATUS_UNSUPPORTED,
           "Variable Blur refuses editable text without implicit rasterization");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), TRUE, FALSE);
  refuses (&f, f.id, target, VARIABLE_BLUR, source, GLIMS_STATUS_LOCKED, "Variable Blur refuses locked target pixels");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), FALSE, FALSE);
  engine->busy++;
  refuses (&f, f.id, target, VARIABLE_BLUR, source, GLIMS_STATUS_BUSY, "Variable Blur refuses global exclusive work");
  engine->busy--;
cleanup:
  fixture_close (&other); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  gchar *user = g_build_filename (argv[1], "user", NULL), *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof (GlimsEngineAPI) || !api->filter_begin_with_source) return 2;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "engine startup failed"); clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, blur_catalog, NULL) == GLIMS_STATUS_OK, "Variable Blur catalog suite executes on engine thread");
  CHECK (glims_engine_call (engine, blur_oracle_and_history, NULL) == GLIMS_STATUS_OK, "Variable Blur independent oracle/history suite executes on engine thread");
  CHECK (glims_engine_call (engine, blur_snapshot_independence, NULL) == GLIMS_STATUS_OK, "Variable Blur snapshot suite executes on engine thread");
  CHECK (glims_engine_call (engine, blur_refusal_cases, NULL) == GLIMS_STATUS_OK, "Variable Blur refusal suite executes on engine thread");
  CHECK (glims_engine_call (engine, flat_and_commit, NULL) == GLIMS_STATUS_OK, "existing Bump Map flat/ramp/Apply/Undo behavior remains covered");
  PublicFixture public = {0};
  if (glims_engine_call (engine, public_setup, &public) == GLIMS_STATUS_OK) {
    GlimsLayerInfo rows[4] = {{0}}; int32_t count = 0; GlimsFilterID filter = 0;
    CHECK (api->image_layers (engine, public.fixture.id, rows, 4, &count) == GLIMS_STATUS_OK && count == 3,
           "host-thread fixture exposes exact target/source/background order");
    if (count == 3) {
      CHECK (api->filter_begin_with_source (engine, public.fixture.id, rows[0].id, VARIABLE_BLUR, rows[1].id,
                                          &filter, &error) == GLIMS_STATUS_OK && filter > 0,
             "public facade marshals Variable Blur Begin from the host thread");
      if (filter) CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "public Variable Blur preview aborts through the host-thread facade");
      clear_error (&error);
    }
  } else CHECK (FALSE, "Variable Blur host-thread fixture setup succeeds");
  glims_engine_call (engine, public_cleanup, &public);
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}
