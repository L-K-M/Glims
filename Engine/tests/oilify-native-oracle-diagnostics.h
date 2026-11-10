/* Included by the test translation unit after its native fixture helpers. */
#include "core/gimpfilter.h"
#include "core/gimpprojection.h"
#include "gegl/gimpapplicator.h"

static gint oilify_diagnostic_checks, oilify_diagnostic_failures;
#define PROBE(c, text) do { \
  gboolean ok_ = (c); oilify_diagnostic_checks++; \
  printf ("%s Oilify diagnostic: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) oilify_diagnostic_failures++; fflush (stdout); \
} while (0)
#define PROBE_NEED(c, text) do { \
  gboolean need_ok_ = (c); PROBE (need_ok_, text); \
  if (!need_ok_) goto cleanup; \
} while (0)

enum {
  DIAG_MAPS           = 1 << 0,
  DIAG_EARLY_FREEZE   = 1 << 1,
  DIAG_SKIP_FREEZE    = 1 << 2,
  DIAG_EMPTY_SELECT   = 1 << 3,
  DIAG_DRAWABLE_AREA  = 1 << 4,
  DIAG_CACHE_OFF      = 1 << 5,
  DIAG_SELECTION_READ = 1 << 6,
  DIAG_DRAWABLE_READ  = 1 << 7,
  DIAG_FREEZE_READ    = 1 << 8,
  DIAG_RESYNC_REGION  = 1 << 9
};

typedef struct {
  const gchar *name;
  guint flags;
} OilifyDiagnostic;

typedef struct {
  guint8 raw[BYTES];
  guint8 drawable[BYTES];
  guint8 projection[BYTES];
} OilifyDiagnosticFrame;

static gboolean
diagnostic_pixels (const gchar *name, const gchar *stage, const gchar *kind,
                   const guint8 *pixels, gsize bytes)
{
  gchar *file = g_strdup_printf ("diag-%s-%s-%s.rgba-u8", name, stage, kind);
  gboolean ok = save_pixels (file, pixels, bytes);
  g_free (file);
  return ok;
}

static void
diagnostic_delta (const gchar *name, const gchar *comparison,
                  const guint8 *before, const guint8 *after, guint width, guint height)
{
  guint changed = 0, maximum[4] = {0};
  guint min_x = width, min_y = height, max_x = 0, max_y = 0;
  for (guint y = 0; y < height; y++) for (guint x = 0; x < width; x++) {
    guint i = 4 * (y * width + x);
    if (memcmp (before + i, after + i, 4) == 0) continue;
    changed++;
    min_x = MIN (min_x, x); min_y = MIN (min_y, y);
    max_x = MAX (max_x, x); max_y = MAX (max_y, y);
    for (guint c = 0; c < 4; c++)
      maximum[c] = MAX (maximum[c], (guint) abs ((gint) before[i + c] - after[i + c]));
  }
  printf ("OBS Oilify diagnostic %s %s changed=%u max=%u,%u,%u,%u",
          name, comparison, changed, maximum[0], maximum[1], maximum[2], maximum[3]);
  if (changed) printf (" bbox=%u,%u..%u,%u", min_x, min_y, max_x, max_y);
  putchar ('\n');
}

static gboolean
diagnostic_render (Fixture *f, GlimsRect area, guint8 *pixels)
{
  return api->image_render (f->engine, f->id, 1.0, area, pixels, (gsize) area.width * 4) == GLIMS_STATUS_OK;
}

static gboolean
diagnostic_frame (Fixture *f, const OilifyDiagnostic *test, const gchar *stage,
                  gboolean read_projection, gboolean selection_first, OilifyDiagnosticFrame *frame)
{
  if (!read_pixels (f->target, FALSE, frame->raw) || !read_pixels (f->target, TRUE, frame->drawable) ||
      !diagnostic_pixels (test->name, stage, "raw", frame->raw, BYTES) ||
      !diagnostic_pixels (test->name, stage, "drawable", frame->drawable, BYTES)) return FALSE;
  if (!read_projection) return TRUE;

  const GlimsRect canvas = {0, 0, SIDE, SIDE};
  const GlimsRect selection = {9, 11, 14, 15};
  guint8 small[14 * 15 * 4];
  if (selection_first && !diagnostic_render (f, selection, small)) return FALSE;
  if (!diagnostic_render (f, canvas, frame->projection) ||
      !diagnostic_pixels (test->name, stage, "projection-premul", frame->projection, BYTES)) return FALSE;
  if (selection_first) {
    guint8 extracted[sizeof small];
    for (gint y = 0; y < selection.height; y++)
      memcpy (extracted + y * selection.width * 4,
              frame->projection + ((selection.y + y) * SIDE + selection.x) * 4, selection.width * 4);
    diagnostic_delta (test->name, "selection-read-vs-full-subrect", small, extracted, 14, 15);
    if (!diagnostic_pixels (test->name, stage, "selection-projection-premul", small, sizeof small)) return FALSE;
  }
  return TRUE;
}

static gboolean
diagnostic_graph (Fixture *f, const gchar *name, const gchar *stage, GeglNode *op, GimpDrawableFilter *filter)
{
  GeglNode *producer = gegl_node_get_producer (op, "input", NULL);
  GimpApplicator *applicator = gimp_filter_get_applicator (GIMP_FILTER (filter));
  if (!producer || !applicator) return FALSE;
  GeglRectangle input = gegl_node_get_bounding_box (producer);
  GeglRectangle output = gegl_node_get_bounding_box (op);
  GeglRectangle intersection = {0};
  gboolean intersects = gimp_item_mask_intersect (GIMP_ITEM (f->target), &intersection.x, &intersection.y,
                                                   &intersection.width, &intersection.height);
  GeglRectangle *valid = NULL;
  gint valid_count = 0;
  GeglBuffer *cache = gimp_applicator_get_cache_buffer (applicator, &valid, &valid_count);
  const Babl *format = gimp_applicator_get_output_format (applicator);
  const gchar *input_operation = gegl_node_get_operation (producer);
  printf ("OBS Oilify diagnostic %s %s input-op=%s input=%d,%d,%d,%d output=%d,%d,%d,%d "
          "mask-intersects=%d selection-local=%d,%d,%d,%d frozen=%d region=%d clip=%d "
          "cache-enabled=%d cache-present=%d valid-rects=%d format=%s\n",
          name, stage, input_operation ? input_operation : "none", input.x, input.y, input.width, input.height,
          output.x, output.y, output.width, output.height, intersects,
          intersection.x, intersection.y, intersection.width, intersection.height,
          gimp_drawable_filter_get_mask (filter) != NULL, gimp_drawable_filter_get_region (filter),
          gimp_drawable_filter_get_clip (filter), gimp_applicator_get_cache (applicator), cache != NULL,
          valid_count, format ? babl_get_name (format) : "none");
  for (gint i = 0; cache && i < valid_count; i++)
    printf ("OBS Oilify diagnostic %s %s cache-rect=%d,%d,%d,%d\n", name, stage,
            valid[i].x, valid[i].y, valid[i].width, valid[i].height);
  g_clear_object (&cache);
  g_free (valid);
  return TRUE;
}

static gboolean
diagnostic_refresh_projection (Fixture *f, const gchar *name, const OilifyDiagnosticFrame *frozen)
{
  const GlimsRect area = {0, 0, SIDE, SIDE};
  guint8 refreshed[BYTES], eager[BYTES];
  gimp_drawable_update (GIMP_DRAWABLE (f->target), 0, 0, SIDE, SIDE);
  gimp_image_flush (f->image);
  if (!diagnostic_render (f, area, refreshed) ||
      !diagnostic_pixels (name, "frozen", "refreshed-projection-premul", refreshed, BYTES)) return FALSE;

  gimp_drawable_update (GIMP_DRAWABLE (f->target), 0, 0, SIDE, SIDE);
  gimp_image_flush (f->image);
  GimpProjection *projection = gimp_image_get_projection (f->image);
  gimp_projection_stop_rendering (projection);
  gimp_projection_flush_now (projection, TRUE);
  GeglBuffer *buffer = gimp_pickable_get_buffer (GIMP_PICKABLE (projection)); /* borrowed */
  if (!buffer) return FALSE;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1.0, babl_format ("R'aG'aB'aA u8"),
                   eager, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  diagnostic_delta (name, "frozen-lazy-vs-refreshed-projection", frozen->projection, refreshed, SIDE, SIDE);
  diagnostic_delta (name, "frozen-refreshed-adapter-vs-eager-core", refreshed, eager, SIDE, SIDE);
  return diagnostic_pixels (name, "frozen", "eager-core-projection-premul", eager, BYTES);
}

static void
diagnostic_case (GlimsEngine *engine, const OilifyDiagnostic *test)
{
  Fixture f = {0};
  GeglNode *op = NULL, *radius = NULL, *exponent = NULL;
  GeglBuffer *rmap = NULL, *emap = NULL;
  GimpDrawableFilter *filter = NULL;
  gboolean attached = FALSE;
  const gboolean preview_projection = !(test->flags & DIAG_DRAWABLE_READ);
  OilifyDiagnosticFrame before, preview, frozen, applied;
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  printf ("OBS Oilify diagnostic case=%s\n", test->name);
  PROBE_NEED (fixture_open (engine, &f, FALSE), "isolated native target opens");
  /* The template has an opaque white background. Hide the other layers so
   * the image projection can expose the target's alpha changes. */
  GimpContainer *layers = gimp_image_get_layers (f.image);
  for (gint i = 0; i < gimp_container_get_n_children (layers); i++) {
    GimpObject *item = gimp_container_get_child_by_index (layers, i);
    if (item && item != GIMP_OBJECT (f.target)) gimp_item_set_visible (GIMP_ITEM (item), FALSE, FALSE);
  }
  gimp_item_set_offset (GIMP_ITEM (f.target), 3, 4);
  gimp_item_set_offset (GIMP_ITEM (f.source), -5, 7);
  if (!(test->flags & DIAG_EMPTY_SELECT)) {
    const GlimsPoint corners[] = {{9, 11}, {23, 26}};
    GlimsSelectOptions options = {.struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE};
    PROBE_NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK,
                "literal nonzero selection is installed");
  }
  gimp_image_flush (f.image);
  PROBE_NEED (diagnostic_frame (&f, test, "before", preview_projection, FALSE, &before) &&
              api->image_undo_info (engine, f.id, &undo_before) == GLIMS_STATUS_OK, "baseline bytes and history captured");
  if (preview_projection) {
    guint origin = (4 * SIDE + 3) * 4;
    PROBE (before.projection[3] == 0 && before.projection[origin + 3] == before.raw[3],
           "actual projection retains target alpha at the item offset");
  }
  op = oilify_node (NULL, 6, 8, 16, TRUE);
  PROBE_NEED (op != NULL, "direct Oilify graph opens");
  if (test->flags & DIAG_MAPS) {
    guint8 source[BYTES];
    const gfloat black = 0.f;
    PROBE_NEED (read_pixels (f.source, TRUE, source), "mapped control reads the same native source seed");
    rmap = oilify_buffer (GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"), source);
    emap = oilify_buffer (GEGL_RECTANGLE (-2, 3, 1, 1), babl_format ("Y float"), &black);
    PROBE_NEED (rmap && emap, "mapped control owns both small buffers");
    radius = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", rmap, NULL);
    exponent = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", emap, NULL);
    PROBE_NEED (radius && exponent && oilify_connect (radius, op, "aux") && oilify_connect (exponent, op, "aux2"),
                "mapped control attaches both roles");
  }
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (f.target), "Oilify diagnostic", op, NULL);
  PROBE_NEED (filter != NULL, "Core filter opens");
  g_object_set (filter, "to-be-merged", TRUE, NULL);
  gimp_drawable_filter_set_temporary (filter, TRUE);
  if (test->flags & DIAG_DRAWABLE_AREA) gimp_drawable_filter_set_region (filter, GIMP_FILTER_REGION_DRAWABLE);
  gimp_drawable_filter_apply (filter, NULL); attached = TRUE;
  gimp_drawable_filter_set_preview (filter, TRUE);
  if (test->flags & DIAG_CACHE_OFF) {
    GimpApplicator *applicator = gimp_filter_get_applicator (GIMP_FILTER (filter));
    PROBE_NEED (applicator != NULL, "cache control has an applicator");
    gimp_applicator_set_cache (applicator, FALSE);
  }
  PROBE_NEED (diagnostic_graph (&f, test->name, "attached", op, filter), "attached graph facts captured");
  if (test->flags & DIAG_RESYNC_REGION) {
    gimp_drawable_filter_set_region (filter, GIMP_FILTER_REGION_DRAWABLE);
    gimp_drawable_filter_set_region (filter, GIMP_FILTER_REGION_SELECTION);
  }
  if (test->flags & DIAG_EARLY_FREEZE) gimp_drawable_filter_layer_mask_freeze (filter);
  gimp_image_flush (f.image);
  PROBE_NEED (diagnostic_frame (&f, test, "preview", preview_projection,
                               test->flags & DIAG_SELECTION_READ, &preview), "live preview bytes captured");
  PROBE (!memcmp (before.raw, preview.raw, BYTES) && undo_equal (engine, f.id, &undo_before) &&
         memcmp (before.drawable, preview.drawable, BYTES) != 0,
         "preview is visible and retains stored bytes and history");
  PROBE_NEED (diagnostic_graph (&f, test->name, "pre-freeze", op, filter), "warmed graph and cache facts captured");
  if (!(test->flags & (DIAG_EARLY_FREEZE | DIAG_SKIP_FREEZE))) gimp_drawable_filter_layer_mask_freeze (filter);
  PROBE_NEED (diagnostic_graph (&f, test->name, "pre-commit", op, filter), "pre-commit graph facts captured");
  if (test->flags & DIAG_FREEZE_READ) {
    gimp_image_flush (f.image);
    PROBE_NEED (diagnostic_frame (&f, test, "frozen", TRUE, FALSE, &frozen) &&
                diagnostic_refresh_projection (&f, test->name, &frozen), "post-freeze and forced-refresh bytes captured");
    diagnostic_delta (test->name, "preview-vs-frozen-drawable", preview.drawable, frozen.drawable, SIDE, SIDE);
    diagnostic_delta (test->name, "preview-vs-frozen-projection", preview.projection, frozen.projection, SIDE, SIDE);
  }
  PROBE_NEED (gimp_drawable_filter_commit (filter, FALSE, NULL, FALSE), "Core Apply completes");
  attached = FALSE;
  gimp_image_flush (f.image);
  PROBE_NEED (diagnostic_frame (&f, test, "apply", TRUE, FALSE, &applied) &&
              api->image_undo_info (engine, f.id, &undo_after) == GLIMS_STATUS_OK, "merged bytes and history captured");
  PROBE (undo_after.undo_count == undo_before.undo_count + 1, "Apply adds one native Undo");
  diagnostic_delta (test->name, "before-vs-apply-raw", before.raw, applied.raw, SIDE, SIDE);
  diagnostic_delta (test->name, "preview-drawable-vs-apply-raw", preview.drawable, applied.raw, SIDE, SIDE);
  if (preview_projection)
    diagnostic_delta (test->name, "preview-vs-apply-projection", preview.projection, applied.projection, SIDE, SIDE);
  if (test->flags & DIAG_FREEZE_READ)
    diagnostic_delta (test->name, "frozen-drawable-vs-apply-raw", frozen.drawable, applied.raw, SIDE, SIDE);
cleanup:
  if (attached) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter); g_clear_object (&op);
  g_clear_object (&radius); g_clear_object (&exponent);
  g_clear_object (&rmap); g_clear_object (&emap);
  if (f.id) PROBE (api->image_close (engine, f.id) == GLIMS_STATUS_OK, "diagnostic image closes");
}

static GlimsStatus
run_oilify_diagnostics (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  const OilifyDiagnostic cases[] = {
    {"plain-late", 0},
    {"plain-no-freeze", DIAG_SKIP_FREEZE},
    {"plain-early", DIAG_EARLY_FREEZE},
    {"plain-empty-selection", DIAG_EMPTY_SELECT},
    {"plain-drawable-region", DIAG_DRAWABLE_AREA},
    {"plain-resynced-unfrozen", DIAG_RESYNC_REGION | DIAG_SKIP_FREEZE},
    {"plain-cache-off", DIAG_CACHE_OFF},
    {"plain-selection-read", DIAG_SELECTION_READ},
    {"plain-drawable-only", DIAG_DRAWABLE_READ},
    {"plain-freeze-probe", DIAG_FREEZE_READ},
    {"mapped-late", DIAG_MAPS},
    {"mapped-early", DIAG_MAPS | DIAG_EARLY_FREEZE}
  };
  for (guint i = 0; i < G_N_ELEMENTS (cases); i++) diagnostic_case (engine, &cases[i]);
  return GLIMS_STATUS_OK;
}
