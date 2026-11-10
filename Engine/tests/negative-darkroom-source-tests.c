/* Independent captured RGB dodge/burn oracle. negative-darkroom.c::prepare
 * declares input/output CIE XYZ float (no alpha), aux R~G~B~ float; process
 * applies a separate exposure multiplier for each aux channel. Consequently
 * this fixture does not borrow another operation's alpha-preservation claim.
 * Fresh GEGL buffers establish the RGB operation; a separate direct native
 * Core drawable-filter establishes preview/merged RGBA, including alpha.
 * No production session, captured aux node, or snapshot helper supplies expected
 * pixels. The renamed fixture main and its original suites are never run. */
#define main negative_existing_input_main
#include "filter-input-tests.c"
#undef main
#undef CHECK
static int darkroom_checks;
#define CHECK(c, text) do { gboolean ok_ = (c); darkroom_checks++; \
  printf ("%s negative-darkroom source: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); } while (0)

#define DARKROOM "gegl:negative-darkroom"
static gboolean darkroom_installed, darkroom_admitted;
typedef struct {
  gdouble dodge, exposure, expC, expM, expY;
  gint curve;
} DarkroomSettings;
static const DarkroomSettings settings = {1.3, 0.35, 85, 55, 75, 1};

static void
darkroom_pixels (Fixture *f, gboolean opaque)
{
  guint8 target[BYTES], map[BYTES];
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    target[i] = 17 + (x * 19 + y * 7) % 211;
    target[i + 1] = 31 + (x * 11 + y * 23) % 197;
    target[i + 2] = 43 + (x * 29 + y * 5) % 181;
    target[i + 3] = opaque ? 255 : 36 + (x * 13 + y * 17) % 219;
    map[i] = x < SIDE / 2 ? 20 + x * 4 : 240 - x * 3;
    map[i + 1] = y < SIDE / 2 ? 30 + y * 4 : 210 - y * 2;
    map[i + 2] = 10 + (x * 17 + y * 29) % 245;
    map[i + 3] = 50 + (x * 7 + y * 11) % 205;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->target)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"), target, GEGL_AUTO_ROWSTRIDE);
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->source)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"), map, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->target), 0, 0, SIDE, SIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->source), 0, 0, SIDE, SIDE);
}

static gboolean
near_bytes (const guint8 a[BYTES], const guint8 b[BYTES])
{
  for (guint i = 0; i < BYTES; i++) if (ABS ((int) a[i] - (int) b[i]) > 2) return FALSE;
  return TRUE;
}

static gboolean
near_rgb (const guint8 a[BYTES], const guint8 b[BYTES])
{
  for (guint i = 0; i < BYTES; i += 4) for (guint c = 0; c < 3; c++)
    if (ABS ((int) a[i + c] - (int) b[i + c]) > 2) return FALSE;
  return TRUE;
}

static gboolean
opaque_bytes (const guint8 pixels[BYTES])
{
  for (guint i = 3; i < BYTES; i += 4) if (pixels[i] != 255) return FALSE;
  return TRUE;
}

static void
configure_node (GeglNode *op, const DarkroomSettings *s)
{
  gegl_node_set (op, "dodge", s->dodge, "exposure", s->exposure,
                 "expC", s->expC, "expM", s->expM, "expY", s->expY,
                 "curve", s->curve, "clip", TRUE, NULL);
}

static gboolean
set_darkroom (GlimsEngine *engine, GlimsFilterID filter, const DarkroomSettings *s)
{
  const char *names[] = {"dodge", "exposure", "expC", "expM", "expY"};
  const gdouble values[] = {s->dodge, s->exposure, s->expC, s->expM, s->expY};
  for (guint i = 0; i < G_N_ELEMENTS (names); i++) {
    GlimsFilterValue value = {.kind = GLIMS_FILTER_VALUE_NUMBER, .number = values[i]};
    if (api->filter_set_property (engine, filter, names[i], &value) != GLIMS_STATUS_OK) return FALSE;
  }
  /* Native curve value 1 is independently named by GEGL's installed enum. */
  GlimsFilterValue curve = {.kind = GLIMS_FILTER_VALUE_ENUM, .string = "kodakportra"};
  GlimsFilterValue clip = {.kind = GLIMS_FILTER_VALUE_BOOL, .boolean = TRUE};
  return s->curve == 1 && api->filter_set_property (engine, filter, "curve", &curve) == GLIMS_STATUS_OK &&
         api->filter_set_property (engine, filter, "clip", &clip) == GLIMS_STATUS_OK;
}

static GeglBuffer *
fresh_buffer (const guint8 pixels[BYTES], const Babl *format)
{
  GeglBuffer *buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), format);
  if (buffer) gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                              babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  return buffer;
}

static gboolean
connect_pad (GeglNode *source, GeglNode *operation, const gchar *pad)
{
  gboolean connected;
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  connected = gegl_node_connect_to (source, "output", operation, pad);
  G_GNUC_END_IGNORE_DEPRECATIONS
  return connected;
}

static gboolean
direct_oracle (const guint8 target[BYTES], GeglBuffer *map,
               const Babl *target_format,
               const DarkroomSettings *s, gboolean with_aux, guint8 out[BYTES])
{
  GeglBuffer *input = fresh_buffer (target, target_format), *aux = gegl_buffer_dup (map);
  GeglNode *graph = gegl_node_new ();
  gboolean ok = FALSE;
  if (!input || !aux || !graph) goto cleanup;
  GeglNode *in = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", input, NULL);
  GeglNode *source = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", aux, NULL);
  GeglNode *op = gegl_node_new_child (graph, "operation", DARKROOM, NULL);
  if (!in || !source || !op) goto cleanup;
  configure_node (op, s);
  if (!connect_pad (in, op, "input") || (with_aux && !connect_pad (source, op, "aux"))) goto cleanup;
  gegl_node_blit (op, 1, GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"),
                  out, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  ok = TRUE;
cleanup:
  g_clear_object (&graph); g_clear_object (&aux); g_clear_object (&input);
  return ok;
}

/* Fixture-only native committed effect, without facade filter admission. */
static gboolean
native_brightness (GimpLayer *layer)
{
  GeglNode *op = gegl_node_new_child (NULL, "operation", "gegl:brightness-contrast", "brightness", 0.125, NULL);
  GimpDrawableFilter *filter = op ? gimp_drawable_filter_new (GIMP_DRAWABLE (layer), "Independent brightness", op, NULL) : NULL;
  gboolean ok = FALSE;
  if (filter) {
    gimp_drawable_filter_apply (filter, NULL);
    ok = gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
    if (ok) gimp_drawable_filter_set_temporary (filter, FALSE);
    else gimp_drawable_filter_abort (filter);
  }
  g_clear_object (&filter); g_clear_object (&op);
  return ok;
}

/* A different image/target is seeded independently by the caller. Native Core
 * establishes merge-format/compositing semantics for this alpha-less XYZ op.
 * Source storage is fresh, never a facade-owned captured snapshot. Reorder the
 * direct filter below committed effects using official Core APIs. */
static gboolean
native_oracle (Fixture *independent, GeglBuffer *map,
               const DarkroomSettings *s, guint8 preview[BYTES], guint8 merged[BYTES])
{
  GeglBuffer *buffer = gegl_buffer_dup (map);
  GeglNode *op = gegl_node_new_child (NULL, "operation", DARKROOM, NULL);
  GeglNode *source = buffer ? gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", buffer, NULL) : NULL;
  GimpDrawableFilter *filter = NULL;
  gboolean ok = FALSE, applied = FALSE;
  if (!buffer || !op || !source) goto cleanup;
  configure_node (op, s);
  if (!connect_pad (source, op, "aux")) goto cleanup;
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (independent->target), "Independent negative", op, NULL);
  if (!filter) goto cleanup;
  g_object_set (filter, "to-be-merged", TRUE, NULL);
  gimp_drawable_filter_set_temporary (filter, TRUE);
  gimp_drawable_filter_apply (filter, NULL); applied = TRUE;
  gimp_drawable_filter_set_preview (filter, TRUE);
  GimpContainer *filters = gimp_drawable_get_filters (GIMP_DRAWABLE (independent->target));
  gint count = gimp_container_get_n_children (filters);
  if (count > 1) gimp_container_reorder (filters, GIMP_OBJECT (filter), count - 1);
  gimp_image_flush (independent->image);
  if (!read_pixels (independent->target, TRUE, preview)) goto cleanup;
  gimp_drawable_filter_layer_mask_freeze (filter);
  if (!gimp_drawable_filter_commit (filter, FALSE, NULL, FALSE)) goto cleanup;
  applied = FALSE;
  gimp_image_flush (independent->image);
  ok = read_pixels (independent->target, FALSE, merged);
cleanup:
  if (applied) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter); g_clear_object (&source); g_clear_object (&op); g_clear_object (&buffer);
  return ok;
}

static GlimsStatus
darkroom_catalog (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  GlimsOperationInfo *operations = NULL; GlimsFilterProperty *properties = NULL;
  GeglNode *graph = NULL; gint32 count = 0; gboolean found = FALSE;
  const char *names[] = {"dodge", "exposure", "expC", "expM", "expY", "curve", "clip"};
  guint mask = 0;
  NEED (api->filter_operations (engine, NULL, 0, &count) == GLIMS_STATUS_OK && count > 0, "installed operation count is queried");
  operations = g_new0 (GlimsOperationInfo, count);
  NEED (api->filter_operations (engine, operations, count, &count) == GLIMS_STATUS_OK, "installed operation rows are returned");
  for (gint i = 0; i < count; i++) if (!strcmp (operations[i].name, DARKROOM)) found = operations[i].support == GLIMS_FILTER_OP_AUX_INPUT;
  CHECK (found && gegl_has_operation (DARKROOM), "Negative Darkroom is installed and classified as auxiliary input");
  NEED (api->filter_operation_properties (engine, DARKROOM, NULL, 0, &count) == GLIMS_STATUS_OK && count > 0, "installed property count is queried");
  properties = g_new0 (GlimsFilterProperty, count);
  NEED (api->filter_operation_properties (engine, DARKROOM, properties, count, &count) == GLIMS_STATUS_OK, "installed properties are returned");
  for (gint i = 0; i < count; i++) for (guint j = 0; j < G_N_ELEMENTS (names); j++)
    if (!strcmp (properties[i].name, names[j])) {
      guint32 kind = j < 5 ? GLIMS_FILTER_VALUE_NUMBER : j == 5 ? GLIMS_FILTER_VALUE_ENUM : GLIMS_FILTER_VALUE_BOOL;
      if (properties[i].kind == kind) mask |= 1u << j;
    }
  CHECK (mask == (1u << G_N_ELEMENTS (names)) - 1, "all literal numeric, curve and clip properties exist with expected kinds");
  graph = gegl_node_new ();
  GeglNode *node = gegl_node_new_child (graph, "operation", DARKROOM, NULL);
  CHECK (node && gegl_node_has_pad (node, "input") && gegl_node_has_pad (node, "aux") &&
         !gegl_node_has_pad (node, "aux1") && !gegl_node_has_pad (node, "aux2"), "the native operation has exactly one auxiliary role");
  darkroom_installed = found && mask == (1u << G_N_ELEMENTS (names)) - 1 && node != NULL;
cleanup:
  g_clear_object (&graph); g_free (properties); g_free (operations);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
darkroom_admission (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  NEED (fixture_open (engine, &f, FALSE), "admission fixture opens");
  GlimsStatus status = api->filter_begin_with_source (engine, f.id, item_id (f.target), DARKROOM, item_id (f.source), &filter, &error);
  darkroom_admitted = status == GLIMS_STATUS_OK && filter > 0;
  printf ("OBS Negative Darkroom admission status=%d filter=%d\n", status, filter);
  CHECK (darkroom_admitted, "named captured dodge/burn map is admitted (old producer RED)");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
darkroom_case (GlimsEngine *engine, gpointer data)
{
  gint mode = GPOINTER_TO_INT (data);
  gboolean opaque = mode == 0 || mode == 3, source_effect = mode >= 2, target_effect = mode == 3;
  const gint offset_x[] = {0, 7, -5, 4}, offset_y[] = {0, -3, 9, 6};
  Fixture f = {0}, independent = {0}; GlimsFilterID filter = 0; char *error = NULL;
  GimpLayer *unrelated = NULL; GeglBuffer *reference_buffer = NULL, *swapped_buffer = NULL;
  guint8 target[BYTES], map[BYTES], raw_map[BYTES], other[BYTES], direct[BYTES], implicit[BYTES], nododge[BYTES];
  guint8 swapped[BYTES], swapped_out[BYTES], expected_preview[BYTES], expected_merged[BYTES], actual[BYTES], committed[BYTES];
  GlimsUndoInfo before = {0}, after = {0}; GlimsEffectInfo effect_before = {0}, effect_after = {0}; gint32 effect_count = -1;
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &independent, FALSE), "independent target/map fixtures open");
  darkroom_pixels (&f, opaque); darkroom_pixels (&independent, opaque);
  unrelated = add_layer (f.image, "Unrelated preserved pixels", TRUE, FALSE);
  NEED (unrelated != NULL, "unrelated layer attaches");
  gimp_item_set_offset (GIMP_ITEM (f.source), offset_x[mode], offset_y[mode]);
  if (source_effect) NEED (native_brightness (f.source) && native_brightness (independent.source), "sources have independently constructed identical native effects");
  if (target_effect) NEED (native_brightness (f.target) && native_brightness (independent.target), "both targets have independent identical existing effects");
  NEED (read_pixels (f.target, FALSE, target) && read_pixels (f.source, TRUE, map) &&
        read_pixels (f.source, FALSE, raw_map) && read_pixels (unrelated, FALSE, other) &&
        api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK, "raw target, rendered RGB map, unrelated pixels and history are captured");
  CHECK (opaque ? opaque_bytes (target) : !opaque_bytes (target), "fixture establishes opaque or partial-alpha target input");
  CHECK (map[0] != map[1] && map[1] != map[2], "map has distinct per-channel RGB dodge/burn values");
  if (source_effect) CHECK (memcmp (map, raw_map, BYTES) != 0, "committed source effect genuinely changes the sampled RGB map");
  const Babl *target_format = gimp_drawable_get_format (GIMP_DRAWABLE (f.target));
  /* Official Core owns this rendered buffer. The oracle clones its native
   * format/extent, preserving committed-effect precision instead of quantizing
   * expected source pixels through our u8 diagnostic array. No Glims snapshot. */
  gimp_pickable_flush (GIMP_PICKABLE (independent.source));
  reference_buffer = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (independent.source));
  NEED (reference_buffer != NULL, "independent source exposes owned native-precision effect output");
  DarkroomSettings zero_dodge = settings; zero_dodge.dodge = 0;
  NEED (direct_oracle (target, reference_buffer, target_format, &settings, TRUE, direct) &&
        direct_oracle (target, reference_buffer, target_format, &settings, FALSE, implicit) &&
        direct_oracle (target, reference_buffer, target_format, &zero_dodge, TRUE, nododge), "fresh direct GEGL graphs render explicit, implicit and zero-dodge cases");
  CHECK (!near_rgb (target, direct), "literal darkroom settings genuinely change colors");
  CHECK (!near_bytes (direct, implicit) && !near_bytes (direct, nododge), "RGB map changes output compared with no map and dodge zero");
  memcpy (swapped, map, BYTES);
  for (guint i = 0; i < BYTES; i += 4) { guint8 red = swapped[i]; swapped[i] = swapped[i + 1]; swapped[i + 1] = red; }
  swapped_buffer = fresh_buffer (swapped, gimp_drawable_get_format (GIMP_DRAWABLE (f.source)));
  NEED (swapped_buffer && direct_oracle (target, swapped_buffer, target_format, &settings, TRUE, swapped_out), "channel-swapped fresh oracle renders");
  CHECK (!near_bytes (direct, swapped_out), "swapping red/green map channels changes native output");
  CHECK (opaque_bytes (direct), "alpha-less XYZ operation converts to opaque raw GEGL RGBA output");
  NEED (native_oracle (&independent, reference_buffer, &settings, expected_preview, expected_merged), "separate native Core filter establishes preview and merged RGBA");
  printf ("OBS mode=%d opaque=%d source_effect=%d target_effect=%d offset=%d,%d native_preview_alpha=%u merged_alpha=%u raw_alpha=%u\n",
          mode, opaque, source_effect, target_effect, offset_x[mode], offset_y[mode], expected_preview[3], expected_merged[3], target[3]);
  /* Opaque input has no alpha compositing ambiguity. Partial-alpha results are
   * compared only to the separate Core reference, never an invented invariant. */
  if (opaque) CHECK (near_bytes (direct, expected_merged), "opaque native merged result matches fresh direct GEGL RGBA");
  CHECK (!near_rgb (target, expected_merged), "independent native merged colors are nontrivial");
  if (!darkroom_admitted) { printf ("OBS facade lifecycle skipped after explicit admission failure; independent native oracles ran\n"); goto cleanup; }
  gimp_item_set_lock_content (GIMP_ITEM (f.source), TRUE, FALSE);
  NEED (api->drawable_effects (engine, f.id, item_id (f.target), &effect_before, 1, &effect_count) == GLIMS_STATUS_OK &&
        effect_count == (target_effect ? 1 : 0), "target's original committed effect identity is captured");
  NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), DARKROOM, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        set_darkroom (engine, filter, &settings), "locked read-only RGB source and literal settings are admitted");
  NEED (read_pixels (f.target, TRUE, actual), "facade preview renders");
  CHECK (near_bytes (actual, expected_preview) && alpha_same (actual, expected_preview), "preview matches independent native Core RGBA with exact native alpha");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES) &&
         read_pixels (f.source, FALSE, actual) && !memcmp (raw_map, actual, BYTES) &&
         read_pixels (unrelated, FALSE, actual) && !memcmp (other, actual, BYTES) && undo_equal (engine, f.id, &before), "preview preserves every stored target/source/unrelated byte and full history");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Cancel succeeds"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES) &&
         read_pixels (f.source, FALSE, actual) && !memcmp (raw_map, actual, BYTES) &&
         read_pixels (unrelated, FALSE, actual) && !memcmp (other, actual, BYTES) && undo_equal (engine, f.id, &before), "Cancel preserves exact target/source/unrelated pixels and full history");
  NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), DARKROOM, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        set_darkroom (engine, filter, &settings), "fresh captured-source preview begins for Apply");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "Apply merges the captured result"); filter = 0;
  NEED (read_pixels (f.target, FALSE, committed), "merged stored target pixels read");
  CHECK (near_bytes (committed, expected_merged) && alpha_same (committed, expected_merged), "Apply matches independent native merged RGBA with exact native alpha");
  CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1 && after.redo_count == 0, "Apply adds exactly one native Undo and no Redo");
  CHECK (api->drawable_effects (engine, f.id, item_id (f.target), &effect_after, 1, &effect_count) == GLIMS_STATUS_OK &&
         effect_count == (target_effect ? 1 : 0) && (!target_effect || !memcmp (&effect_before, &effect_after, sizeof effect_before)), "no auxiliary effect persists and the original target effect is unchanged");
  CHECK (read_pixels (f.source, FALSE, actual) && !memcmp (raw_map, actual, BYTES) &&
         read_pixels (unrelated, FALSE, actual) && !memcmp (other, actual, BYTES), "Apply preserves every source and unrelated stored byte");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "one Undo is accepted");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES), "Undo restores all original target bytes exactly");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "one Redo is accepted");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (committed, actual, BYTES), "Redo restores all merged bytes exactly");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  g_clear_object (&reference_buffer); g_clear_object (&swapped_buffer);
  clear_error (&error); fixture_close (&independent); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
darkroom_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}, independent = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 target[BYTES], map[BYTES], expected[BYTES], merged[BYTES], preview[BYTES], actual[BYTES];
  GWeakRef weak; gboolean weak_ready = FALSE; GeglBuffer *reference_buffer = NULL;
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &independent, FALSE), "lifetime fixtures open");
  darkroom_pixels (&f, FALSE); darkroom_pixels (&independent, FALSE);
  gimp_pickable_flush (GIMP_PICKABLE (independent.source));
  reference_buffer = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (independent.source));
  NEED (reference_buffer && read_pixels (f.target, FALSE, target) && read_pixels (f.source, FALSE, map) &&
        native_oracle (&independent, reference_buffer, &settings, expected, merged), "lifetime reference owns independent source storage");
  NEED (api->filter_begin_with_source (engine, f.id, item_id (f.target), DARKROOM, item_id (f.source), &filter, &error) == GLIMS_STATUS_OK &&
        set_darkroom (engine, filter, &settings) && read_pixels (f.target, TRUE, preview), "captured-map preview starts for lifetime checks");
  CHECK (near_bytes (preview, expected) && alpha_same (preview, expected), "lifetime preview matches pre-mutation native reference");
  g_weak_ref_init (&weak, G_OBJECT (f.source)); weak_ready = TRUE;
  write_pixels (f.source, FALSE, FALSE); /* Deliberately bypass preview admission. */
  DarkroomSettings alternate = settings; alternate.dodge += 0.4;
  NEED (set_darkroom (engine, filter, &alternate) && set_darkroom (engine, filter, &settings), "settings force reevaluation after live map mutation");
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "source mutation cannot change any captured preview byte");
  gimp_image_remove_layer (f.image, f.source, FALSE, NULL); f.source = NULL;
  gimp_image_undo_free (f.image);
  GObject *probe = g_weak_ref_get (&weak);
  CHECK (probe == NULL, "source object really finalizes after deletion and history purge"); g_clear_object (&probe);
  NEED (set_darkroom (engine, filter, &alternate) && set_darkroom (engine, filter, &settings), "settings force reevaluation after source destruction");
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "preview survives complete map destruction with exact captured output");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "destroyed-source preview remains cancellable"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES), "lifetime Cancel preserves every original target byte");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (weak_ready) g_weak_ref_clear (&weak);
  g_clear_object (&reference_buffer);
  clear_error (&error); fixture_close (&independent); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static void
darkroom_refuses (Fixture *f, GlimsImageID image, GlimsItemID target, const char *operation,
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
darkroom_gates (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}, other = {0}; char *error = NULL; gboolean history_disabled = FALSE;
  GlimsFilterID filter = 0;
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &other, FALSE), "refusal fixtures open");
  GlimsItemID target = item_id (f.target), source = item_id (f.source);
  darkroom_refuses (&f, f.id, 0, DARKROOM, source, GLIMS_STATUS_INVALID_ARGUMENT, "implicit target refuses");
  darkroom_refuses (&f, f.id, target, DARKROOM, 0, GLIMS_STATUS_INVALID_ARGUMENT, "implicit map refuses");
  darkroom_refuses (&f, INT_MAX, target, DARKROOM, source, GLIMS_STATUS_NOT_FOUND, "stale image refuses");
  darkroom_refuses (&f, f.id, INT_MAX, DARKROOM, source, GLIMS_STATUS_NOT_FOUND, "stale target refuses");
  darkroom_refuses (&f, f.id, target, DARKROOM, INT_MAX, GLIMS_STATUS_NOT_FOUND, "stale map refuses");
  darkroom_refuses (&f, f.id, target, DARKROOM, item_id (other.source), GLIMS_STATUS_NOT_FOUND, "cross-image map refuses");
  darkroom_refuses (&f, f.id, target, "gegl:displace", source, GLIMS_STATUS_UNSUPPORTED, "unrelated multi-role operations remain outside the allowlist");
  GimpLayer *group = gimp_group_layer_new (f.image);
  NEED (gimp_image_add_layer (f.image, group, NULL, 0, FALSE), "group fixture attaches");
  darkroom_refuses (&f, f.id, item_id (group), DARKROOM, source, GLIMS_STATUS_UNSUPPORTED, "group merge target refuses");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), TRUE, FALSE);
  darkroom_refuses (&f, f.id, target, DARKROOM, source, GLIMS_STATUS_LOCKED, "locked target pixels refuse");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), FALSE, FALSE);
  engine->busy++;
  darkroom_refuses (&f, f.id, target, DARKROOM, source, GLIMS_STATUS_BUSY, "global exclusive work refuses");
  engine->busy--;
  gimp_image_undo_disable (f.image); history_disabled = TRUE;
  darkroom_refuses (&f, f.id, target, DARKROOM, source, GLIMS_STATUS_BUSY, "disabled Undo refuses Begin");
  gimp_image_undo_enable (f.image); history_disabled = FALSE;
  NEED (api->filter_begin_with_source (engine, f.id, target, DARKROOM, source, &filter, &error) == GLIMS_STATUS_OK,
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
  darkroom_refuses (&f, f.id, target, DARKROOM, source, GLIMS_STATUS_BUSY, "unresolved floating selection refuses");
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
  CHECK (glims_engine_call (engine, darkroom_catalog, NULL) == GLIMS_STATUS_OK, "installed catalog/property query executes on engine thread");
  if (darkroom_installed) {
    CHECK (glims_engine_call (engine, darkroom_admission, NULL) == GLIMS_STATUS_OK, "baseline admission probe executes on engine thread");
    for (gint mode = 0; mode < 4; mode++)
      CHECK (glims_engine_call (engine, darkroom_case, GINT_TO_POINTER (mode)) == GLIMS_STATUS_OK, "independent opaque/partial-alpha operation and history case executes");
    if (darkroom_admitted) {
      CHECK (glims_engine_call (engine, darkroom_lifetime, NULL) == GLIMS_STATUS_OK, "detached RGB map lifetime suite executes on engine thread");
      CHECK (glims_engine_call (engine, darkroom_gates, NULL) == GLIMS_STATUS_OK, "representative refusal suite executes on engine thread");
    } else printf ("OBS lifetime and refusal suites wait for the explicitly failed baseline admission\n");
  }
  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d negative-darkroom checks, %d failures\n", failures ? "FAILED" : "PASSED", darkroom_checks, failures);
  return failures != 0;
}
