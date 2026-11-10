/* ONE optional contrast-reference input; independent authentic GEGL oracle.
 * Existing fixture helpers are shared without changing or executing their suite. */
#define main selective_existing_input_main
#include "filter-input-tests.c"
#undef main
#undef CHECK
static int selective_checks;
#define CHECK(c, text) do { gboolean ok_ = (c); selective_checks++; printf ("%s selective source: %s\n", ok_ ? "ok  " : "FAIL", text); if (!ok_) failures++; fflush (stdout); } while (0)

#define SELECTIVE "gegl:gaussian-blur-selective"
static gboolean selective_installed, selective_admitted;

typedef struct { gdouble radius, delta; gint offset_x, offset_y; } SelectiveSettings;

static void
selective_pixels (Fixture *f)
{
  guint8 target[BYTES], reference[BYTES];
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    target[i] = ((x / 2 + y / 3) & 1) ? 229 : 21;
    target[i + 1] = (x * 29 + y * 13) % 256;
    target[i + 2] = (x * 7 + y * 47) % 256;
    target[i + 3] = 48 + (x * 11 + y * 17) % 208;
    reference[i] = x < 13 ? 20 + x * 2 + y : 190 + (x + y) % 47;
    reference[i + 1] = y < 19 ? 40 + y * 2 + x : 199 + x % 37;
    reference[i + 2] = (x * 5 + y * 3) % 230;
    reference[i + 3] = 64 + (x * 7 + y * 19) % 192;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->target)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"), target, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->target), 0, 0, SIDE, SIDE);
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->source)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"), reference, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->source), 0, 0, SIDE, SIDE);
}

/* Fresh buffers and raw graph only: no production snapshot helper, filter
 * session layout, captured aux node, or native preview node is inspected. */
static gboolean
selective_oracle (const guint8 target[BYTES], const guint8 reference[BYTES],
                  const Babl *target_format, const Babl *reference_format,
                  const SelectiveSettings *settings, gboolean connect_reference, guint8 out[BYTES])
{
  GeglBuffer *input = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), target_format);
  GeglBuffer *aux = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), reference_format);
  GeglNode *graph = gegl_node_new ();
  gboolean ok = FALSE;
  if (!input || !aux || !graph) goto cleanup;
  gegl_buffer_set (input, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"), target, GEGL_AUTO_ROWSTRIDE);
  gegl_buffer_set (aux, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"), reference, GEGL_AUTO_ROWSTRIDE);
  GeglNode *source = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", input, NULL);
  GeglNode *contrast = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", aux, NULL);
  GeglNode *blur = gegl_node_new_child (graph, "operation", SELECTIVE,
                                      "blur-radius", settings->radius, "max-delta", settings->delta, NULL);
  if (!source || !contrast || !blur || !gegl_node_connect_to (source, "output", blur, "input")) goto cleanup;
  if (connect_reference && !gegl_node_connect_to (contrast, "output", blur, "aux")) goto cleanup;
  gegl_node_blit (blur, 1, GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"),
                  out, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  ok = TRUE;
cleanup:
  g_clear_object (&graph); g_clear_object (&aux); g_clear_object (&input);
  return ok;
}

static gboolean
selective_near (const guint8 a[BYTES], const guint8 b[BYTES])
{
  for (guint i = 0; i < BYTES; i++) if (ABS ((int) a[i] - (int) b[i]) > 1) return FALSE;
  return TRUE;
}

static gboolean
selective_settings (GlimsEngine *engine, GlimsFilterID filter, const SelectiveSettings *settings)
{
  GlimsFilterValue radius = { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = settings->radius };
  GlimsFilterValue delta = { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = settings->delta };
  return api->filter_set_property (engine, filter, "blur-radius", &radius) == GLIMS_STATUS_OK &&
         api->filter_set_property (engine, filter, "max-delta", &delta) == GLIMS_STATUS_OK;
}

static GlimsStatus
selective_catalog (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  gint32 count = 0;
  GlimsOperationInfo *operations = NULL;
  GlimsFilterProperty *properties = NULL;
  GeglNode *graph = NULL;
  gboolean found = FALSE, radius = FALSE, delta = FALSE;
  NEED (api->filter_operations (engine, NULL, 0, &count) == GLIMS_STATUS_OK && count > 0,
        "installed operation catalog is queried through the facade");
  operations = g_new0 (GlimsOperationInfo, count);
  NEED (api->filter_operations (engine, operations, count, &count) == GLIMS_STATUS_OK,
        "installed operation rows are returned");
  for (gint i = 0; i < count; i++) if (!strcmp (operations[i].name, SELECTIVE)) {
    found = operations[i].support == GLIMS_FILTER_OP_AUX_INPUT;
    printf ("OBS installed %s support=%u categories=%s\n", operations[i].name, operations[i].support, operations[i].categories);
  }
  CHECK (found && gegl_has_operation (SELECTIVE), "Selective Gaussian Blur is actually installed and classified with aux input");
  NEED (api->filter_operation_properties (engine, SELECTIVE, NULL, 0, &count) == GLIMS_STATUS_OK && count > 0,
        "installed Selective Gaussian properties are queried explicitly");
  properties = g_new0 (GlimsFilterProperty, count);
  NEED (api->filter_operation_properties (engine, SELECTIVE, properties, count, &count) == GLIMS_STATUS_OK,
        "installed property rows are returned");
  for (gint i = 0; i < count; i++) {
    if (!strcmp (properties[i].name, "blur-radius")) radius = properties[i].kind == GLIMS_FILTER_VALUE_NUMBER;
    if (!strcmp (properties[i].name, "max-delta")) delta = properties[i].kind == GLIMS_FILTER_VALUE_NUMBER;
    printf ("OBS property %s kind=%u\n", properties[i].name, properties[i].kind);
  }
  CHECK (radius && delta, "blur-radius and max-delta are real installed numeric properties");
  graph = gegl_node_new ();
  GeglNode *probe = gegl_node_new_child (graph, "operation", SELECTIVE, NULL);
  CHECK (probe && gegl_node_has_pad (probe, "input") && gegl_node_has_pad (probe, "aux") &&
         !gegl_node_has_pad (probe, "aux1") && !gegl_node_has_pad (probe, "aux2"),
         "the operation exposes one contrast-reference aux role, not multiple roles");
  selective_installed = found && radius && delta && probe != NULL;
cleanup:
  g_clear_object (&graph); g_free (properties); g_free (operations);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
selective_admission (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  NEED (fixture_open (engine, &f, FALSE), "baseline admission fixture opens");
  GlimsStatus status = api->filter_begin_with_source (engine, f.id, item_id (f.target), SELECTIVE,
                                                    item_id (f.source), &filter, &error);
  selective_admitted = status == GLIMS_STATUS_OK && filter > 0;
  printf ("OBS selective snapshot Begin status=%d filter=%d\n", status, filter);
  CHECK (selective_admitted, "snapshot facade admits the named Selective Gaussian contrast reference (baseline RED)");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
selective_oracles_and_history (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  static const SelectiveSettings cases[] = { {3.75, 0.18, 0, 0}, {6.25, 0.31, 7, -3}, {4.5, 0.12, -5, 9} };
  for (guint mode = 0; mode < G_N_ELEMENTS (cases); mode++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
    guint8 target[BYTES], reference[BYTES], expected[BYTES], implicit[BYTES], preview[BYTES], actual[BYTES], committed[BYTES];
    GlimsUndoInfo before = {0}, after = {0};
    NEED (fixture_open (engine, &f, FALSE), "asymmetric RGBA/contrast fixture opens");
    selective_pixels (&f);
    gimp_item_set_offset (GIMP_ITEM (f.source), cases[mode].offset_x, cases[mode].offset_y);
    NEED (read_pixels (f.target, FALSE, target) && read_pixels (f.source, FALSE, reference) &&
          api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK, "independent raw buffers and exact history are captured");
    CHECK (target[3] > 0 && target[3] < 255 && reference[3] > 0 && reference[3] < 255 && reference[0] != reference[80],
           "target and contrast reference are asymmetric and contain partial alpha");
    const Babl *target_format = gimp_drawable_get_format (GIMP_DRAWABLE (f.target));
    const Babl *reference_format = gimp_drawable_get_format (GIMP_DRAWABLE (f.source));
    NEED (selective_oracle (target, reference, target_format, reference_format, &cases[mode], TRUE, expected) &&
          selective_oracle (target, reference, target_format, reference_format, &cases[mode], FALSE, implicit),
          "independent authentic GEGL graphs render explicit and implicit contrast inputs");
    CHECK (!selective_near (target, expected), "the configured oracle really blurs the target");
    CHECK (!selective_near (implicit, expected), "chosen contrast reference differs from native target-as-contrast behavior");
    CHECK (alpha_same (target, expected), "authentic Selective Gaussian preserves every target alpha byte");
    if (!selective_admitted) { printf ("OBS dependent facade lifecycle skipped until admission is implemented\n"); goto cleanup; }
    gimp_item_set_lock_content (GIMP_ITEM (f.source), TRUE, FALSE);
    NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), SELECTIVE, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
          filter > 0 && selective_settings (engine, filter, &cases[mode]), "facade admits a locked read-only contrast reference and settings");
    NEED (read_pixels (f.target, TRUE, preview), "native preview pixels render");
    CHECK (selective_near (preview, expected) && alpha_same (target, preview), "preview RGBA matches the independent graph within one level with exact alpha");
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES) &&
           read_pixels (f.source, FALSE, actual) && !memcmp (reference, actual, BYTES) && undo_equal (engine, f.id, &before),
           "preview changes no stored target/reference byte or native history");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "preview Cancel succeeds"); filter = 0;
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES) && undo_equal (engine, f.id, &before),
           "Cancel restores every raw target byte and exact history");
    NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), SELECTIVE, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
          selective_settings (engine, filter, &cases[mode]), "fresh configured preview starts for Apply");
    NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "Apply merges the selective result into target pixels"); filter = 0;
    NEED (read_pixels (f.target, FALSE, committed), "merged target bytes are readable");
    CHECK (selective_near (committed, expected) && alpha_same (target, committed), "Apply matches the authentic contrast-reference graph and exact alpha");
    CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
           "Apply adds exactly one native Undo step");
    gint32 effects = -1;
    CHECK (api->drawable_effects (engine, f.id, item_id (f.target), NULL, 0, &effects) == GLIMS_STATUS_OK && effects == 0,
           "no auxiliary graph is persisted as a layer effect");
    CHECK (read_pixels (f.source, FALSE, actual) && !memcmp (reference, actual, BYTES), "Apply preserves the source's raw RGBA bytes");
    NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "one Undo is accepted");
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES), "Undo restores the target byte for byte");
    NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "one Redo is accepted");
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (committed, actual, BYTES), "Redo restores committed target bytes exactly");
cleanup:
    if (filter) api->filter_abort (engine, filter);
    clear_error (&error); fixture_close (&f);
  }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
selective_snapshot_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 target[BYTES], reference[BYTES], expected[BYTES], preview[BYTES], actual[BYTES];
  const SelectiveSettings settings = {5.25, 0.24, 0, 0};
  GWeakRef weak; gboolean weak_ready = FALSE;
  NEED (fixture_open (engine, &f, FALSE), "snapshot-lifetime fixture opens");
  selective_pixels (&f);
  NEED (read_pixels (f.target, FALSE, target) && read_pixels (f.source, FALSE, reference) &&
        selective_oracle (target, reference, gimp_drawable_get_format (GIMP_DRAWABLE (f.target)),
                          gimp_drawable_get_format (GIMP_DRAWABLE (f.source)), &settings, TRUE, expected),
        "lifetime oracle owns unrelated target/reference storage");
  NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), SELECTIVE, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        selective_settings (engine, filter, &settings) && read_pixels (f.target, TRUE, preview), "captured-reference preview starts for lifetime checks");
  CHECK (selective_near (preview, expected), "lifetime preview matches pre-edit contrast pixels");
  g_weak_ref_init (&weak, G_OBJECT (f.source)); weak_ready = TRUE;
  write_pixels (f.source, FALSE, FALSE); /* Deliberately bypass active-preview edit admission. */
  SelectiveSettings alternate = settings; alternate.radius += 1;
  NEED (selective_settings (engine, filter, &alternate) && selective_settings (engine, filter, &settings),
        "parameter changes force a fresh graph evaluation after live source mutation");
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "live source edits cannot alter the detached contrast reference");
  gimp_image_remove_layer (f.image, f.source, FALSE, NULL); f.source = NULL;
  gimp_image_undo_free (f.image);
  GObject *probe = g_weak_ref_get (&weak);
  CHECK (probe == NULL, "source object finalizes after deletion and history purge"); g_clear_object (&probe);
  NEED (selective_settings (engine, filter, &alternate) && selective_settings (engine, filter, &settings),
        "deleted-source preview is invalidated and re-evaluated independently");
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "preview survives complete source destruction with exact captured output");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "source-independent preview cancels"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES), "lifetime Cancel preserves every target byte");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (weak_ready) g_weak_ref_clear (&weak);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static void
selective_refuses (Fixture *f, GlimsImageID image, GlimsItemID target, const char *operation,
                   GlimsItemID source, GlimsStatus expected, const char *label)
{
  char *error = NULL; GlimsFilterID filter = INT_MAX;
  gchar *before = fingerprint (f);
  guint sessions = g_hash_table_size (f->engine->filters);
  GlimsStatus status = api->filter_begin_with_source (f->engine, image, target, operation, source, &filter, &error);
  gchar *after = fingerprint (f);
  CHECK (status == expected && filter == 0, label);
  CHECK (before && after && !strcmp (before, after) && sessions == g_hash_table_size (f->engine->filters),
         "refusal preserves stored pixels/image/history and creates no session");
  if (filter && status == GLIMS_STATUS_OK) api->filter_abort (f->engine, filter);
  clear_error (&error); g_free (before); g_free (after);
}

static GlimsStatus
selective_gates (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}, other = {0}; char *error = NULL; gboolean history_disabled = FALSE;
  GlimsFilterID filter = 0;
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &other, FALSE), "refusal fixtures open");
  GlimsItemID target = item_id (f.target), source = item_id (f.source);
  selective_refuses (&f, f.id, 0, SELECTIVE, source, GLIMS_STATUS_INVALID_ARGUMENT, "implicit target refuses");
  selective_refuses (&f, f.id, target, SELECTIVE, 0, GLIMS_STATUS_INVALID_ARGUMENT, "implicit reference refuses");
  selective_refuses (&f, INT_MAX, target, SELECTIVE, source, GLIMS_STATUS_NOT_FOUND, "stale image refuses");
  selective_refuses (&f, f.id, INT_MAX, SELECTIVE, source, GLIMS_STATUS_NOT_FOUND, "stale target refuses");
  selective_refuses (&f, f.id, target, SELECTIVE, INT_MAX, GLIMS_STATUS_NOT_FOUND, "stale reference refuses");
  selective_refuses (&f, f.id, target, SELECTIVE, item_id (other.source), GLIMS_STATUS_NOT_FOUND, "cross-image reference refuses");
  selective_refuses (&f, f.id, target, "gegl:displace", source, GLIMS_STATUS_UNSUPPORTED, "unrelated multi-role operations remain outside the allowlist");
  GimpLayer *group = gimp_group_layer_new (f.image);
  NEED (gimp_image_add_layer (f.image, group, NULL, 0, FALSE), "group fixture attaches");
  selective_refuses (&f, f.id, item_id (group), SELECTIVE, source, GLIMS_STATUS_UNSUPPORTED, "group merge target refuses");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), TRUE, FALSE);
  selective_refuses (&f, f.id, target, SELECTIVE, source, GLIMS_STATUS_LOCKED, "locked target pixels refuse");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), FALSE, FALSE);
  engine->busy++;
  selective_refuses (&f, f.id, target, SELECTIVE, source, GLIMS_STATUS_BUSY, "global exclusive work refuses");
  engine->busy--;
  gimp_image_undo_disable (f.image); history_disabled = TRUE;
  selective_refuses (&f, f.id, target, SELECTIVE, source, GLIMS_STATUS_BUSY, "disabled Undo refuses Begin");
  gimp_image_undo_enable (f.image); history_disabled = FALSE;
  NEED (api->filter_begin_with_source (engine, f.id, target, SELECTIVE, source, &filter, &error) == GLIMS_STATUS_OK,
        "preview begins before testing Commit readiness");
  guint8 before[BYTES], actual[BYTES];
  NEED (read_pixels (f.target, FALSE, before), "Commit guard captures stored target pixels");
  gimp_image_undo_disable (f.image); history_disabled = TRUE;
  CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY &&
         read_pixels (f.target, FALSE, actual) && !memcmp (before, actual, BYTES), "disabled Undo refuses Commit before target mutation");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "refused Commit remains cancellable"); filter = 0;
  gimp_image_undo_enable (f.image); history_disabled = FALSE;
  clear_error (&error);
  GlimsSelectOptions selection = { .struct_size = sizeof selection, .operation = GLIMS_SELECT_REPLACE };
  GlimsPoint corners[] = {{0, 0}, {8, 8}}; GlimsItemID floating = 0;
  NEED (api->layer_select (engine, f.id, target) == GLIMS_STATUS_OK &&
        api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &selection) == GLIMS_STATUS_OK &&
        api->selection_float (engine, f.id, target, GLIMS_FLOAT_COPY, &floating, &error) == GLIMS_STATUS_OK,
        "real floating selection attaches for refusal");
  selective_refuses (&f, f.id, target, SELECTIVE, source, GLIMS_STATUS_BUSY, "unresolved floating selection refuses");
cleanup:
  if (history_disabled) gimp_image_undo_enable (f.image);
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&other); fixture_close (&f);
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
  CHECK (glims_engine_call (engine, selective_catalog, NULL) == GLIMS_STATUS_OK, "installed catalog/property query executes on engine thread");
  if (selective_installed) {
    CHECK (glims_engine_call (engine, selective_admission, NULL) == GLIMS_STATUS_OK, "baseline admission probe executes on engine thread");
    CHECK (glims_engine_call (engine, selective_oracles_and_history, NULL) == GLIMS_STATUS_OK, "independent oracle and lifecycle cases execute on engine thread");
    if (selective_admitted) {
      CHECK (glims_engine_call (engine, selective_snapshot_lifetime, NULL) == GLIMS_STATUS_OK, "detached-reference lifetime checks execute on engine thread");
      CHECK (glims_engine_call (engine, selective_gates, NULL) == GLIMS_STATUS_OK, "representative refusal gates execute on engine thread");
    } else printf ("OBS lifetime and refusal suites wait for the baseline admission fix\n");
  }
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d selective checks, %d failures\n", failures ? "FAILED" : "PASSED", selective_checks, failures);
  return failures != 0;
}
