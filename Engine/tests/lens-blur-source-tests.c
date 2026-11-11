/* Independent native oracle for the missing Lens Blur input route (slot147).
 *
 * Builds real GEGL reference graphs over a small asymmetric textured RGBA
 * target and validates expected outputs are distinct/nontrivial. Baseline on
 * current engines: slot147 admission for gegl:lens-blur is expected to fail
 * (explicit 0 None and positive mask source); report that naturally (RED),
 * never as skip/pass. Eventual-support checks (preview/Apply/Cancel/Undo/Redo)
 * run only after admission succeeds. Production preparation is never used as
 * oracle data. */
#define main lens_blur_original_main
#include "filter-input-tests.c"
#undef main
#undef CHECK
#undef NEED

#define LENS_BLUR "gegl:lens-blur"

static int lens_checks;
static gboolean lens_admitted;
#define CHECK(c, text) do { \
  gboolean ok_ = (c); lens_checks++; \
  printf ("%s lens blur: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); \
} while (0)
#define NEED(c, text) do { \
  gboolean need_ok_ = (c); CHECK (need_ok_, text); \
  if (!need_ok_) goto cleanup; \
} while (0)

typedef struct {
  gdouble radius;
  gdouble highlight_factor;
  gdouble highlight_low;
  gdouble highlight_high;
  gboolean clip;
  gboolean linear_mask;
} LensSettings;

static const LensSettings lens_defaults = {
  .radius = 2.0,
  .highlight_factor = 0.0,
  .highlight_low = 0.0,
  .highlight_high = 1.0,
  .clip = TRUE,
  .linear_mask = FALSE
};

static void
write_lens_target (Fixture *f, guint8 target[BYTES])
{
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    /* Small asymmetric textured RGBA with partial alpha, not uniform. */
    target[i + 0] = (guint8) (18 + x * 7 + (y & 3) * 13);
    target[i + 1] = (guint8) (41 + y * 5 + (x & 7) * 9);
    target[i + 2] = (guint8) (73 + x * 3 + y * 11);
    target[i + 3] = (guint8) (60 + (x * 11 + y * 17) % 176);
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (f->target)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"),
                   target, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (f->target), 0, 0, SIDE, SIDE);
}

static void
write_y_mask (GimpLayer *layer, gboolean ramp)
{
  guint8 pixels[BYTES];
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    guint8 v = ramp ? (guint8) (x * 255 / (SIDE - 1)) : 0;
    pixels[i] = pixels[i + 1] = pixels[i + 2] = v;
    pixels[i + 3] = 255;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"),
                   pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, SIDE, SIDE);
}

static gboolean
bytes_differ (const guint8 *a, const guint8 *b)
{
  return memcmp (a, b, BYTES) != 0;
}

static gboolean
pixels_near (const guint8 *actual, const guint8 *expected)
{
  for (guint i = 0; i < BYTES; i++)
    if (ABS ((int) actual[i] - (int) expected[i]) > 1) return FALSE;
  return TRUE;
}

/* Independent raw GEGL oracle: fresh buffers/graph only, never production
 * snapshot/preparation. aux=NULL means disconnected (uniform/None). */
static gboolean
raw_lens_oracle (const guint8 target[BYTES], const guint8 *mask, gboolean ramp_mask,
                 const LensSettings *s, guint8 output[BYTES])
{
  (void) ramp_mask;
  GeglBuffer *input = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"));
  GeglBuffer *aux = mask ? gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE),
                                            babl_format (s->linear_mask ? "Y float" : "Y' float"))
                         : NULL;
  GeglNode *graph = gegl_node_new ();
  GeglNode *in_node = NULL, *aux_node = NULL, *op = NULL;
  gboolean ok = FALSE;
  if (!input || (mask && !aux) || !graph) goto cleanup;

  gegl_buffer_set (input, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                   babl_format ("R'G'B'A u8"), target, GEGL_AUTO_ROWSTRIDE);
  if (mask)
    gegl_buffer_set (aux, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                     babl_format ("R'G'B'A u8"), mask, GEGL_AUTO_ROWSTRIDE);

  in_node = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", input, NULL);
  op = gegl_node_new_child (graph, "operation", LENS_BLUR,
                            "radius", s->radius,
                            "highlight-factor", s->highlight_factor,
                            "highlight-threshold-low", s->highlight_low,
                            "highlight-threshold-high", s->highlight_high,
                            "clip", s->clip,
                            "linear-mask", s->linear_mask, NULL);
  if (!in_node || !op) goto cleanup;
  if (!gegl_node_connect (in_node, "output", op, "input")) goto cleanup;
  if (aux) {
    aux_node = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", aux, NULL);
    if (!aux_node || !gegl_node_connect (aux_node, "output", op, "aux")) goto cleanup;
  }

  gegl_node_blit (op, 1.0, GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"),
                  output, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  ok = TRUE;
cleanup:
  /* The graph owns its child nodes. */
  g_clear_object (&graph);
  g_clear_object (&aux); g_clear_object (&input);
  return ok;
}

static GlimsStatus
lens_installed_and_oracle (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  guint8 target[BYTES], zero[BYTES], ramp[BYTES];
  guint8 out_none[BYTES], out_zero[BYTES], out_ramp[BYTES];
  Fixture f = {0};

  CHECK (gegl_has_operation (LENS_BLUR), "installed GEGL provides gegl:lens-blur");
  CHECK (gegl_operation_find_property (LENS_BLUR, "radius") != NULL, "lens-blur exposes radius");
  CHECK (gegl_operation_find_property (LENS_BLUR, "highlight-factor") != NULL, "lens-blur exposes highlight-factor");
  CHECK (gegl_operation_find_property (LENS_BLUR, "highlight-threshold-low") != NULL, "lens-blur exposes highlight-threshold-low");
  CHECK (gegl_operation_find_property (LENS_BLUR, "highlight-threshold-high") != NULL, "lens-blur exposes highlight-threshold-high");
  CHECK (gegl_operation_find_property (LENS_BLUR, "clip") != NULL, "lens-blur exposes clip");
  CHECK (gegl_operation_find_property (LENS_BLUR, "linear-mask") != NULL, "lens-blur exposes linear-mask");

  NEED (fixture_open (engine, &f, FALSE), "oracle fixture opens");
  write_lens_target (&f, target);
  /* Zero and ramp masks in drawable storage (RGBA u8), oracle converts via format. */
  write_y_mask (f.source, FALSE); NEED (read_pixels (f.source, FALSE, zero), "zero mask captured");
  write_y_mask (f.source, TRUE);  NEED (read_pixels (f.source, FALSE, ramp), "ramp mask captured");

  NEED (raw_lens_oracle (target, NULL, FALSE, &lens_defaults, out_none), "raw GEGL oracle: None/disconnected aux");
  NEED (raw_lens_oracle (target, zero, FALSE, &lens_defaults, out_zero), "raw GEGL oracle: zero mask");
  NEED (raw_lens_oracle (target, ramp, TRUE,  &lens_defaults, out_ramp), "raw GEGL oracle: ramp mask");

  CHECK (bytes_differ (target, out_none), "None (uniform) oracle is nontrivial vs target");
  CHECK (bytes_differ (out_none, out_ramp), "None and ramp-mask oracles are distinct");
  CHECK (bytes_differ (out_zero, out_ramp), "zero-mask and ramp-mask oracles are distinct");
  /* With safe radius2 and default highlights, zero mask vs none may coincide
   * for this op's semantics; require the set to be meaningfully exercised. */
  CHECK (bytes_differ (target, out_zero) || bytes_differ (out_none, out_zero),
         "zero-mask oracle exercises mask path (nontrivial or distinct from None)");

cleanup:
  fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
lens_admission_baseline (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; char *error = NULL; GlimsFilterID filter = 123;
  gboolean mask_admitted = FALSE;
  guint8 before[BYTES];
  GlimsUndoInfo undo = {0};

  NEED (fixture_open (engine, &f, FALSE), "admission baseline fixture opens");
  guint8 target[BYTES]; write_lens_target (&f, target);
  write_y_mask (f.source, TRUE);
  NEED (read_pixels (f.target, FALSE, before) && api->image_undo_info (engine, f.id, &undo) == GLIMS_STATUS_OK,
        "admission baseline captures target/history");

  /* explicit 0 None: current slot147 requires source>0. */
  GlimsStatus s0 = glims_filter_begin_with_source (f.engine, f.id, item_id (f.target), LENS_BLUR, 0, &filter, &error);
  gboolean none_admitted = s0 == GLIMS_STATUS_OK && filter > 0;
  CHECK (none_admitted, "slot147 admits Lens Blur with explicit None");
  if (s0 == GLIMS_STATUS_OK && filter) { api->filter_abort (engine, filter); filter = 0; }

  clear_error (&error); filter = 123;
  GlimsStatus s1 = glims_filter_begin_with_source (f.engine, f.id, item_id (f.target), LENS_BLUR,
                                                   item_id (f.source), &filter, &error);
  if (s1 != GLIMS_STATUS_OK)
    fprintf (stderr, "Lens mask admission status=%u: %s\n", s1, error ? error : "no detail");
  mask_admitted = s1 == GLIMS_STATUS_OK && filter > 0;
  /* Baseline RED on 173/current: missing support must be reported naturally. */
  CHECK (mask_admitted, "slot147 admits Lens Blur with a positive mask source");

  if (!mask_admitted) {
    CHECK (s1 == GLIMS_STATUS_UNSUPPORTED || s1 == GLIMS_STATUS_INVALID_ARGUMENT || s1 == GLIMS_STATUS_FAILED,
           "baseline admission failure reports a non-success status");
    guint8 after[BYTES]; GlimsUndoInfo undo_after = {0};
    CHECK (read_pixels (f.target, FALSE, after) && !memcmp (before, after, BYTES) &&
           api->image_undo_info (engine, f.id, &undo_after) == GLIMS_STATUS_OK && !memcmp (&undo, &undo_after, sizeof undo),
           "failed admission leaves stored target bytes and history unchanged");
  } else {
    /* Eventual support: cancel path keeps preview session cancellable. */
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "admitted preview cancels"); filter = 0;
  }
  if (!mask_admitted) filter = 0;
  lens_admitted = none_admitted && mask_admitted;

cleanup:
  if (filter && mask_admitted) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static gboolean
begin_lens (Fixture *f, GlimsItemID source, GlimsFilterID *out, char **error)
{
  GlimsStatus status = glims_filter_begin_with_source (f->engine, f->id, item_id (f->target), LENS_BLUR, source, out, error);
  if (status != GLIMS_STATUS_OK) return FALSE;
  GlimsFilterValue v = { .kind = GLIMS_FILTER_VALUE_NUMBER, .number = lens_defaults.radius };
  if (api->filter_set_property (f->engine, *out, "radius", &v) != GLIMS_STATUS_OK) return FALSE;
  v.kind = GLIMS_FILTER_VALUE_BOOL; v.boolean = lens_defaults.clip;
  if (api->filter_set_property (f->engine, *out, "clip", &v) != GLIMS_STATUS_OK) return FALSE;
  v.boolean = lens_defaults.linear_mask;
  if (api->filter_set_property (f->engine, *out, "linear-mask", &v) != GLIMS_STATUS_OK) return FALSE;
  v.kind = GLIMS_FILTER_VALUE_NUMBER; v.number = lens_defaults.highlight_factor;
  if (api->filter_set_property (f->engine, *out, "highlight-factor", &v) != GLIMS_STATUS_OK) return FALSE;
  v.number = lens_defaults.highlight_low;
  if (api->filter_set_property (f->engine, *out, "highlight-threshold-low", &v) != GLIMS_STATUS_OK) return FALSE;
  v.number = lens_defaults.highlight_high;
  if (api->filter_set_property (f->engine, *out, "highlight-threshold-high", &v) != GLIMS_STATUS_OK) return FALSE;
  return TRUE;
}

static GlimsStatus
lens_eventual_support (GlimsEngine *engine, gpointer unused)
{
  gint mode = GPOINTER_TO_INT (unused); /* None, zero mask, ramp mask. */
  if (!lens_admitted) {
    printf ("Lens Blur dependent pixel checks not executed: admission failed above.\n");
    fflush (stdout);
    return GLIMS_STATUS_OK;
  }
  Fixture f = {0}; GlimsFilterID filter = 0; char *error = NULL;
  guint8 target[BYTES], mask[BYTES], expected[BYTES], original[BYTES], preview[BYTES], actual[BYTES], committed[BYTES];
  GlimsUndoInfo before = {0}, after = {0};

  NEED (fixture_open (engine, &f, FALSE), "eventual-support fixture opens");
  write_lens_target (&f, target);
  write_y_mask (f.source, mode == 2);
  NEED (read_pixels (f.source, FALSE, mask), "native mask captured for the selected input case");
  NEED (read_pixels (f.target, FALSE, original) && api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK,
        "eventual-support baseline captured");
  NEED (raw_lens_oracle (target, mode == 0 ? NULL : mask, mode == 2, &lens_defaults, expected),
        "independent oracle for the selected input case");
  CHECK (mode == 1 ? pixels_near (original, expected) : bytes_differ (original, expected),
         "zero map is an identity control; None and ramp produce nontrivial blur");

  GlimsItemID source = mode == 0 ? 0 : item_id (f.source);
  NEED (begin_lens (&f, source, &filter, &error) && read_pixels (f.target, TRUE, preview),
        "eventual-support preview begins and renders");
  CHECK (pixels_near (preview, expected), "preview pixels match independent raw oracle within tolerance");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) && undo_equal (engine, f.id, &before),
        "preview keeps stored target bytes and history unchanged");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Cancel aborts preview"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES) && undo_equal (engine, f.id, &before),
        "Cancel leaves stored pixels and history unchanged");

  NEED (begin_lens (&f, source, &filter, &error), "fresh preview for Apply");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "Apply commits"); filter = 0;
  NEED (read_pixels (f.target, FALSE, committed), "committed pixels readable");
  CHECK (pixels_near (committed, expected), "Apply/merged pixels match independent raw oracle within tolerance");
  CHECK (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK && after.undo_count == before.undo_count + 1,
        "Apply creates exactly one Undo step");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "one Undo");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (original, actual, BYTES), "Undo restores original target bytes exactly");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "exact Redo");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (committed, actual, BYTES), "Redo restores committed target bytes exactly");

cleanup:
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

#include "lens-blur-owned-guards.h"

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
    fprintf (stderr, "%s\n", error ? error : "engine startup failed");
    clear_error (&error); g_free (user); g_free (cache); return 2;
  }

  CHECK (glims_engine_call (engine, lens_installed_and_oracle, NULL) == GLIMS_STATUS_OK,
         "independent GEGL oracle suite executes on engine thread");
  CHECK (glims_engine_call (engine, lens_admission_baseline, NULL) == GLIMS_STATUS_OK,
         "slot147 admission baseline suite executes on engine thread");
  for (gint mode = 0; mode < 3; mode++) {
    printf ("Lens Blur case: %s\n", mode == 0 ? "None" : mode == 1 ? "zero mask" : "ramp mask");
    CHECK (glims_engine_call (engine, lens_eventual_support, GINT_TO_POINTER (mode)) == GLIMS_STATUS_OK,
           "selected input pixel/history suite executes on engine thread");
  }
  CHECK (glims_engine_call (engine, lens_copy_bounds, NULL) == GLIMS_STATUS_OK,
         "snapshot metadata boundary checks execute without copying boundary buffers");
  CHECK (glims_engine_call (engine, lens_owned_guards, NULL) == GLIMS_STATUS_OK,
         "owned Lens setter and invalid-map guards execute on engine thread");
  CHECK (glims_engine_call (engine, lens_lifetime, NULL) == GLIMS_STATUS_OK,
         "owned Lens detached-source lifetime executes on engine thread");

  api->stop (engine); g_free (user); g_free (cache);
  printf ("%s: %d lens checks, %d failures (admitted=%s)\n",
          failures ? "FAILED" : "PASSED", lens_checks, failures, lens_admitted ? "yes" : "no");
  return failures != 0;
}
