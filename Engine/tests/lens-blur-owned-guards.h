/* Include after Lens helpers, before main. Root reviews/calls these suites.
 * No unsafe radius is ever passed to the independent GEGL oracle. */
#ifndef GLIMS_LENS_OWNED_GUARDS_FIXTURE_H
#define GLIMS_LENS_OWNED_GUARDS_FIXTURE_H

static GlimsStatus
lens_owned_number (GlimsEngine *engine, GlimsFilterID filter, const gchar *name,
                   gdouble number, gboolean typed)
{
  GlimsFilterValue value = {.kind = GLIMS_FILTER_VALUE_NUMBER, .number = number};
  return typed ? api->filter_set_property (engine, filter, name, &value)
               : api->filter_set_double (engine, filter, name, number);
}

static gboolean
lens_owned_number_is (GlimsEngine *engine, GlimsFilterID filter, const gchar *name, gdouble expected)
{
  GlimsFilterValue value = {0};
  return api->filter_get_property (engine, filter, name, &value) == GLIMS_STATUS_OK &&
         value.kind == GLIMS_FILTER_VALUE_NUMBER && value.number == expected;
}

static gboolean
lens_owned_history (Fixture *f, const GlimsUndoInfo *undo, const GlimsHistoryInfo *before)
{
  GlimsHistoryInfo after = {0};
  return undo_equal (f->engine, f->id, undo) &&
         api->image_history (f->engine, f->id, NULL, 0, &after) == GLIMS_STATUS_OK &&
         after.revision == before->revision && after.count == before->count &&
         after.current_position == before->current_position;
}

static void
lens_owned_added (GimpContainer *stack, GimpObject *item, guint *adds)
{
  (void) stack; (void) item; (*adds)++;
}

static GlimsStatus
lens_owned_bad_maps (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {.engine = engine}; GlimsFilterID filter = 0; char *error = NULL;
  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB, GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  NEED (image && glims_adopt_image (engine, image, &f.id) == GLIMS_STATUS_OK, "invalid-map native float image opens");
  f.image = image; f.target = add_layer (image, "Float target", TRUE, FALSE);
  f.source = add_layer (image, "Float blur map", FALSE, FALSE);
  NEED (f.target && f.source, "small native float target and blur map attach");
  gimp_item_set_visible (GIMP_ITEM (f.source), FALSE, FALSE);
  GeglBuffer *raw = gimp_drawable_get_buffer (GIMP_DRAWABLE (f.source));
  GeglBuffer *target = gimp_drawable_get_buffer (GIMP_DRAWABLE (f.target));
  const Babl *space = babl_format_get_space (gegl_buffer_get_format (raw));
  const Babl *rgba = babl_format_with_space ("RGBA float", space);
  const Babl *target_rgba = babl_format_with_space ("RGBA float", babl_format_get_space (gegl_buffer_get_format (target)));
  const Babl *y = babl_format_with_space ("Y float", space), *yp = babl_format_with_space ("Y' float", space);
  const gfloat bad[] = {NAN, INFINITY, -0.25f, 1.01f};
  const GeglRectangle point = {3, 4, 1, 1}, all = {0, 0, SIDE, SIDE};
  for (guint i = 0; i < G_N_ELEMENTS (bad); i++) {
    gfloat value[] = {bad[i], bad[i], bad[i], 1}, actual[4], linear, perceptual;
    gfloat target_before[BYTES], target_after[BYTES], map_before[BYTES], map_after[BYTES];
    GlimsUndoInfo undo = {0}; GlimsHistoryInfo history = {0};
    gegl_buffer_set (raw, &point, 0, rgba, value, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update (GIMP_DRAWABLE (f.source), point.x, point.y, 1, 1);
    gegl_buffer_get (raw, &point, 1, rgba, actual, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    gegl_buffer_get (raw, &point, 1, y, &linear, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    gegl_buffer_get (raw, &point, 1, yp, &perceptual, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    printf ("OBS Lens invalid map case=%u raw=%.9g Y=%.9g Yprime=%.9g\n", i, actual[0], linear, perceptual); fflush (stdout);
    gboolean installed = i == 0 ? isnan (actual[0]) : i == 1 ? isinf (actual[0]) : actual[0] == bad[i];
    NEED (installed && (!isfinite (linear) || linear < 0 || linear > 1.001f ||
                       !isfinite (perceptual) || perceptual < 0 || perceptual > 1.001f),
          "invalid native float and converted map luminance are genuinely installed");
    gegl_buffer_get (target, &all, 1, target_rgba, target_before, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    gegl_buffer_get (raw, &all, 1, rgba, map_before, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    NEED (api->image_undo_info (engine, f.id, &undo) == GLIMS_STATUS_OK &&
          api->image_history (engine, f.id, NULL, 0, &history) == GLIMS_STATUS_OK, "invalid-map raw history captured");
    GimpContainer *stack = gimp_drawable_get_filters (GIMP_DRAWABLE (f.target));
    gint effects = gimp_container_get_n_children (stack); guint adds = 0, sessions = g_hash_table_size (engine->filters);
    gulong hook = g_signal_connect (stack, "add", G_CALLBACK (lens_owned_added), &adds);
    filter = 777;
    GlimsStatus status = api->filter_begin_with_source (engine, f.id, item_id (f.target), LENS_BLUR,
                                                       item_id (f.source), &filter, &error);
    g_signal_handler_disconnect (stack, hook);
    gegl_buffer_get (target, &all, 1, target_rgba, target_after, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    gegl_buffer_get (raw, &all, 1, rgba, map_after, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    CHECK (status == GLIMS_STATUS_UNSUPPORTED && filter == 0 && adds == 0 &&
           gimp_container_get_n_children (stack) == effects && g_hash_table_size (engine->filters) == sessions &&
           !memcmp (target_before, target_after, sizeof target_before) && !memcmp (map_before, map_after, sizeof map_before) &&
           lens_owned_history (&f, &undo, &history), "invalid map refuses before attachment, resets output and preserves raw pixels/history");
    if (status == GLIMS_STATUS_OK && filter) api->filter_abort (engine, filter);
    filter = 0; clear_error (&error);
  }
cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); if (!f.id) g_clear_object (&image); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
lens_owned_guards (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  for (guint mapped = 0; mapped < 2; mapped++) {
    Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
    guint8 original[BYTES], preview[BYTES], actual[BYTES]; GlimsUndoInfo undo = {0}; GlimsHistoryInfo history = {0};
    printf ("Lens owned guards: %s\n", mapped ? "captured ramp" : "None");
    NEED (fixture_open (engine, &f, TRUE), "setter guard fixture opens");
    write_lens_target (&f, original); write_y_mask (f.source, TRUE);
    NEED (api->image_undo_info (engine, f.id, &undo) == GLIMS_STATUS_OK &&
          api->image_history (engine, f.id, NULL, 0, &history) == GLIMS_STATUS_OK, "setter guard history captured");
    NEED (begin_lens (&f, mapped ? item_id (f.source) : 0, &filter, &error) && read_pixels (f.target, TRUE, preview),
          "safe radius-two preview begins");
    const gdouble unsafe_radius[] = {1e20, 40000};
    for (guint typed = 0; typed < 2; typed++) for (guint i = 0; i < G_N_ELEMENTS (unsafe_radius); i++) {
      printf ("OBS Lens unsafe radius setter=%s radius=%.17g\n", typed ? "typed" : "double", unsafe_radius[i]); fflush (stdout);
      GlimsStatus status = lens_owned_number (engine, filter, "radius", unsafe_radius[i], typed);
      /* Never ask GEGL to evaluate a parameter the facade failed to reject. */
      NEED (status == GLIMS_STATUS_UNSUPPORTED && lens_owned_number_is (engine, filter, "radius", 2),
            "unsafe radius refuses through each setter before changing the accepted radius");
      CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES) &&
             read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) && lens_owned_history (&f, &undo, &history),
             "unsafe-radius refusal preserves preview, raw target and full history");
    }
    const gdouble low = 0.5, high = 0.5 + 1e-12;
    NEED (low != high && (gfloat) low == (gfloat) high &&
          lens_owned_number (engine, filter, "highlight-threshold-low", low, TRUE) == GLIMS_STATUS_OK &&
          lens_owned_number (engine, filter, "highlight-threshold-high", high, TRUE) == GLIMS_STATUS_OK &&
          lens_owned_number_is (engine, filter, "highlight-threshold-low", low) &&
          lens_owned_number_is (engine, filter, "highlight-threshold-high", high),
          "factor zero permits distinct-double thresholds that collapse to one native float");
    for (guint typed = 0; typed < 2; typed++) {
      NEED (lens_owned_number (engine, filter, "highlight-factor", 1, typed) == GLIMS_STATUS_INVALID_ARGUMENT &&
            lens_owned_number_is (engine, filter, "highlight-factor", 0), "both setters refuse enabling collapsed-float highlights");
    }
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) && lens_owned_history (&f, &undo, &history),
           "coupled highlight refusals leave stored pixels and history untouched");
    NEED (lens_owned_number (engine, filter, "highlight-threshold-high", 1, FALSE) == GLIMS_STATUS_OK &&
          lens_owned_number (engine, filter, "highlight-threshold-low", 0, TRUE) == GLIMS_STATUS_OK &&
          lens_owned_number (engine, filter, "highlight-factor", 1, FALSE) == GLIMS_STATUS_OK &&
          lens_owned_number_is (engine, filter, "highlight-factor", 1) &&
          lens_owned_number (engine, filter, "highlight-factor", 0, TRUE) == GLIMS_STATUS_OK &&
          lens_owned_number (engine, filter, "radius", 3, FALSE) == GLIMS_STATUS_OK &&
          lens_owned_number_is (engine, filter, "radius", 3) &&
          lens_owned_number (engine, filter, "radius", 2, TRUE) == GLIMS_STATUS_OK, "nominal finite settings remain accepted through both setter forms");
    CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "restored valid settings reproduce the original safe preview");
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "session remains cancellable after all refusals"); filter = 0;
    CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) && lens_owned_history (&f, &undo, &history) &&
           gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (f.target))) == 0, "guard-suite Cancel leaves no effect, pixel or history change");
cleanup:
    if (filter) api->filter_abort (engine, filter);
    clear_error (&error); fixture_close (&f);
  }
  return lens_owned_bad_maps (engine, NULL);
}

static GlimsStatus
lens_lifetime (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL; GWeakRef weak; gboolean weak_ready = FALSE;
  guint8 target[BYTES], old_map[BYTES], zero[BYTES], actual[BYTES], expected2[BYTES], expected3[BYTES], zero3[BYTES];
  GlimsUndoInfo undo = {0}; GlimsHistoryInfo history = {0}; LensSettings three = lens_defaults; three.radius = 3;
  NEED (fixture_open (engine, &f, TRUE), "lifetime fixture opens a small real target and ramp");
  write_lens_target (&f, target); write_y_mask (f.source, TRUE);
  NEED (read_pixels (f.source, FALSE, old_map), "original ramp bytes are independently captured");
  write_y_mask (f.source, FALSE);
  NEED (read_pixels (f.source, FALSE, zero) && raw_lens_oracle (target, old_map, TRUE, &lens_defaults, expected2) &&
        raw_lens_oracle (target, old_map, TRUE, &three, expected3) && raw_lens_oracle (target, zero, FALSE, &three, zero3),
        "fresh raw GEGL radius-two/three oracles use original ramp and zero controls");
  CHECK (bytes_differ (expected2, expected3) && bytes_differ (expected3, zero3), "fresh-radius and changed-map oracle controls are genuinely different");
  write_y_mask (f.source, TRUE);
  NEED (begin_lens (&f, item_id (f.source), &filter, &error) && read_pixels (f.target, TRUE, actual) && pixels_near (actual, expected2),
        "lifetime preview captures the old ramp and matches its independent oracle");
  g_weak_ref_init (&weak, G_OBJECT (f.source)); weak_ready = TRUE;
  write_y_mask (f.source, FALSE);
  NEED (read_pixels (f.source, FALSE, actual) && !memcmp (actual, zero, BYTES) && memcmp (actual, old_map, BYTES),
        "original live source readback really changes from ramp to zero");
  NEED (lens_owned_number (engine, filter, "radius", 3, TRUE) == GLIMS_STATUS_OK &&
        lens_owned_number_is (engine, filter, "radius", 3) && read_pixels (f.target, TRUE, actual) && pixels_near (actual, expected3),
        "new radius-three evaluation still uses the captured old ramp");
  NEED (lens_owned_number (engine, filter, "radius", 2, FALSE) == GLIMS_STATUS_OK &&
        read_pixels (f.target, TRUE, actual) && pixels_near (actual, expected2), "radius-two reevaluation also retains the captured ramp");
  gimp_image_remove_layer (f.image, f.source, FALSE, NULL); f.source = NULL; gimp_image_undo_free (f.image);
  GObject *probe = g_weak_ref_get (&weak);
  CHECK (probe == NULL, "removing and purging the original source proves its finalization"); g_clear_object (&probe);
  NEED (api->image_undo_info (engine, f.id, &undo) == GLIMS_STATUS_OK &&
        api->image_history (engine, f.id, NULL, 0, &history) == GLIMS_STATUS_OK, "post-purge history captured for Cancel preservation");
  NEED (lens_owned_number (engine, filter, "radius", 3, FALSE) == GLIMS_STATUS_OK &&
        read_pixels (f.target, TRUE, actual) && pixels_near (actual, expected3), "fresh radius three survives complete source destruction");
  NEED (lens_owned_number (engine, filter, "radius", 2, TRUE) == GLIMS_STATUS_OK &&
        read_pixels (f.target, TRUE, actual) && pixels_near (actual, expected2), "fresh radius two survives complete source destruction");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "detached-source preview cancels"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES) && lens_owned_history (&f, &undo, &history) &&
         gimp_container_get_n_children (gimp_drawable_get_filters (GIMP_DRAWABLE (f.target))) == 0,
         "lifetime Cancel preserves target bytes and post-purge history without an effect");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (weak_ready) g_weak_ref_clear (&weak);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}
/* Construct sparse buffer metadata only. Never copy, align, read or write
 * these boundary buffers through GEGL's native integer geometry routines. */
static GlimsStatus
lens_copy_bounds (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  static const struct { gint x, y, width, height, sx, sy; gboolean accepted; } cases[] = {
    {0, 0, 32, 32, 0, 0, TRUE},
    {-32, -32, 32, 32, 0, 0, TRUE},
    /* Each coordinate/shift is within the real GObject spec's half-gint
     * range. Their difference and subsequent tile padding are not. */
    {G_MAXINT / 2 - 40, 0, 32, 32, -G_MAXINT / 2, 0, FALSE},
    {-G_MAXINT / 2 + 40, 0, 32, 32, G_MAXINT / 2, 0, FALSE},
    {0, G_MAXINT / 2 - 40, 32, 32, 0, -G_MAXINT / 2, FALSE},
    {G_MAXINT / 2, 0, 32, 32, -G_MAXINT / 2, 0, FALSE},
    {0, -G_MAXINT / 2, 32, 32, 0, G_MAXINT / 2, FALSE},
  };
  for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
    GeglBuffer *buffer = g_object_new (GEGL_TYPE_BUFFER, "format", babl_format ("R'G'B'A u8"),
      "x", cases[i].x, "y", cases[i].y, "width", cases[i].width, "height", cases[i].height,
      "shift-x", cases[i].sx, "shift-y", cases[i].sy, "tile-width", 64, "tile-height", 64, NULL);
    CHECK (buffer && glims_filter_input_lens_map_bounds (buffer) == cases[i].accepted,
           "actual pre-copy geometry gate distinguishes safe tiles and padded native integer boundaries");
    g_clear_object (&buffer);
  }
  return GLIMS_STATUS_OK;
}
#endif
