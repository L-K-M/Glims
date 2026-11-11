/* Slot170 against independently constructed native Oilify graphs. */
#define main oilify_existing_input_main
#include "filter-input-tests.c"
#undef main
#undef CHECK
#undef NEED
#include "core/gimpfilter.h"
#include <glib/gstdio.h>
#include <stddef.h>

static gint oilify_source_checks;
#define CHECK(c, text) do { \
  gboolean ok_ = (c); oilify_source_checks++; \
  printf ("%s Oilify source: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); \
} while (0)
#define NEED(c, text) do { \
  gboolean need_ok_ = (c); CHECK (need_ok_, text); \
  if (!need_ok_) goto cleanup; \
} while (0)

typedef enum { OILIFY_PLAIN, OILIFY_RADIUS, OILIFY_EXPONENT, OILIFY_BOTH, OILIFY_SAME_MAP, OILIFY_TARGET_MAP } OilifyRole;
typedef struct { Fixture f; GimpLayer *radius, *exponent; } OilifyCase;
typedef struct { guint8 drawable[BYTES], projection[BYTES]; } OilifyFrame;
/* In the cropped 14x15 input, a radius of six times the dark linear
 * luminance can stay below one and sample only the center. */
enum { OILIFY_FIXTURE_RADIUS = 32 };

static gboolean
has_oilify_sources (void)
{
  return api->struct_size >= offsetof (GlimsEngineAPI, filter_begin_oilify_with_sources) +
                             sizeof (api->filter_begin_oilify_with_sources) &&
         api->filter_begin_oilify_with_sources != NULL;
}

static gboolean
native_brightness (GimpLayer *layer, gdouble value)
{
  GeglNode *op = gegl_node_new_child (NULL, "operation", "gegl:brightness-contrast", "brightness", value, NULL);
  GimpDrawableFilter *filter = op ? gimp_drawable_filter_new (GIMP_DRAWABLE (layer), "Oracle brightness", op, NULL) : NULL;
  gboolean ok = FALSE;
  if (filter) {
    gimp_drawable_filter_apply (filter, NULL);
    gimp_drawable_filter_layer_mask_freeze (filter);
    ok = gimp_drawable_filter_commit (filter, TRUE, NULL, FALSE);
    if (!ok) gimp_drawable_filter_abort (filter);
  }
  g_clear_object (&filter); g_clear_object (&op);
  return ok;
}

static gboolean
setup_oilify_case (GlimsEngine *engine, OilifyCase *c, OilifyRole role)
{
  if (!fixture_open (engine, &c->f, TRUE)) return FALSE;
  GimpImage *image = c->f.image;
  GimpLayer *target = c->f.target;
  GimpContainer *layers = gimp_image_get_layers (image);
  for (gint i = 0; i < gimp_container_get_n_children (layers); i++) {
    GimpObject *item = gimp_container_get_child_by_index (layers, i);
    if (item != GIMP_OBJECT (target)) gimp_item_set_visible (GIMP_ITEM (item), FALSE, FALSE);
  }
  gimp_item_set_offset (GIMP_ITEM (target), 3, 4);
  gimp_item_set_offset (GIMP_ITEM (c->f.source), -5, 7);
  if (role == OILIFY_RADIUS || role == OILIFY_BOTH || role == OILIFY_SAME_MAP) c->radius = c->f.source;
  if (role == OILIFY_TARGET_MAP) c->radius = target;
  if (role == OILIFY_SAME_MAP) c->exponent = c->radius;
  if (role == OILIFY_EXPONENT || role == OILIFY_BOTH) {
    c->exponent = add_layer (image, "Exponent map", FALSE, FALSE);
    if (!c->exponent) return FALSE;
    gimp_item_set_visible (GIMP_ITEM (c->exponent), FALSE, FALSE);
    gimp_item_set_offset (GIMP_ITEM (c->exponent), 8, -3);
  }
  /* Independent map effects and a downstream target effect. The paired
   * oracle checks that raw pixels merge below the latter, once. */
  if (role == OILIFY_BOTH && (!native_brightness (c->f.source, 0.2) || !native_brightness (target, -0.15))) return FALSE;
  const GlimsPoint points[] = {{9, 11}, {23, 26}};
  GlimsSelectOptions options = {.struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE};
  if (api->select_shape (engine, c->f.id, GLIMS_SHAPE_RECTANGLE, points, 2, &options) != GLIMS_STATUS_OK) return FALSE;
  if (role == OILIFY_BOTH) {
    guint8 stored[BYTES], rendered[BYTES];
    const guint sample = (4 * SIDE + 4) * 4;
    return read_pixels (c->f.source, FALSE, stored) && read_pixels (c->f.source, TRUE, rendered) &&
           memcmp (stored + sample, rendered + sample, 4) != 0;
  }
  return TRUE;
}

static gboolean
capture_oilify_frame (Fixture *f, OilifyFrame *frame)
{
  gimp_image_flush (f->image);
  return read_pixels (f->target, TRUE, frame->drawable) &&
         api->image_render (f->engine, f->id, 1.0, (GlimsRect) {0, 0, SIDE, SIDE},
                            frame->projection, SIDE * 4) == GLIMS_STATUS_OK;
}

static GeglBuffer *
reference_map (GimpLayer *source)
{
  guint8 pixels[BYTES];
  if (!read_pixels (source, TRUE, pixels)) return NULL;
  const Babl *format = babl_format ("R'G'B'A u8");
  GeglBuffer *buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), format);
  if (buffer) gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, format, pixels, GEGL_AUTO_ROWSTRIDE);
  return buffer;
}

static gboolean
reference_oilify (OilifyCase *c, OilifyFrame *preview, OilifyFrame *applied, guint8 raw[BYTES])
{
  GeglNode *op = gegl_node_new_child (NULL, "operation", "gegl:oilify", "mask-radius", OILIFY_FIXTURE_RADIUS,
                                    "exponent", 8, "intensities", 16, "use-inten", TRUE, NULL);
  GeglBuffer *buffers[2] = {NULL, NULL};
  GeglNode *nodes[2] = {NULL, NULL};
  GimpLayer *sources[] = {c->radius, c->exponent};
  const gchar *pads[] = {"aux", "aux2"};
  GimpDrawableFilter *filter = NULL;
  gboolean ok = FALSE, attached = FALSE;
  if (!op) goto cleanup;
  for (guint i = 0; i < 2; i++) {
    if (!sources[i]) continue;
    buffers[i] = reference_map (sources[i]);
    if (!buffers[i]) goto cleanup;
    nodes[i] = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", buffers[i], NULL);
    if (!nodes[i]) goto cleanup;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gboolean connected = gegl_node_connect_to (nodes[i], "output", op, pads[i]);
    G_GNUC_END_IGNORE_DEPRECATIONS
    if (!connected) goto cleanup;
  }
  filter = gimp_drawable_filter_new (GIMP_DRAWABLE (c->f.target), "Direct Oilify reference", op, NULL);
  if (!filter) goto cleanup;
  g_object_set (filter, "to-be-merged", TRUE, NULL);
  gimp_drawable_filter_set_temporary (filter, TRUE);
  gimp_drawable_filter_apply (filter, NULL); attached = TRUE;
  GimpContainer *stack = gimp_drawable_get_filters (GIMP_DRAWABLE (c->f.target));
  gimp_container_reorder (stack, GIMP_OBJECT (filter), gimp_container_get_n_children (stack) - 1);
  gimp_drawable_filter_layer_mask_freeze (filter);
  gimp_drawable_update (GIMP_DRAWABLE (c->f.target), 0, 0, -1, -1);
  if (!capture_oilify_frame (&c->f, preview) || !gimp_drawable_filter_commit (filter, FALSE, NULL, FALSE)) goto cleanup;
  attached = FALSE;
  gimp_drawable_update (GIMP_DRAWABLE (c->f.target), 0, 0, -1, -1);
  ok = capture_oilify_frame (&c->f, applied) && read_pixels (c->f.target, FALSE, raw);
cleanup:
  if (attached) gimp_drawable_filter_abort (filter);
  g_clear_object (&filter); g_clear_object (&op);
  for (guint i = 0; i < 2; i++) { g_clear_object (&nodes[i]); g_clear_object (&buffers[i]); }
  return ok;
}

static gboolean
set_oilify_settings (GlimsEngine *engine, GlimsFilterID filter)
{
  GlimsFilterValue v = {.kind = GLIMS_FILTER_VALUE_INTEGER, .integer = OILIFY_FIXTURE_RADIUS};
  if (api->filter_set_property (engine, filter, "mask-radius", &v) != GLIMS_STATUS_OK) return FALSE;
  v.integer = 8;
  if (api->filter_set_property (engine, filter, "exponent", &v) != GLIMS_STATUS_OK) return FALSE;
  v.integer = 16;
  if (api->filter_set_property (engine, filter, "intensities", &v) != GLIMS_STATUS_OK) return FALSE;
  v.kind = GLIMS_FILTER_VALUE_BOOL; v.boolean = TRUE;
  return api->filter_set_property (engine, filter, "use-inten", &v) == GLIMS_STATUS_OK;
}

typedef struct { Fixture *f; guint adds; gboolean inactive; GlimsStatus close_status; } OilifyAttach;
static void
check_oilify_attachment (GimpContainer *stack, GimpObject *item, OilifyAttach *observed)
{
  (void) stack;
  observed->adds++;
  observed->inactive = !gimp_filter_get_active (GIMP_FILTER (item));
  /* If the fence is missing, record that failure without destroying a
   * drawable inside Core's attachment callback. */
  observed->close_status = observed->f->engine->busy > 0
    ? api->image_close (observed->f->engine, observed->f->id) : GLIMS_STATUS_OK;
}

static void
oilify_pixel_case (GlimsEngine *engine, OilifyRole role, gboolean admitted)
{
  OilifyCase ref = {0}, c = {0};
  OilifyFrame expected_preview, expected_applied, before, after;
  guint8 ref_before[BYTES], expected_raw[BYTES], raw_before[BYTES], raw[BYTES], source_before[BYTES];
  GlimsUndoInfo undo = {0}, merged = {0};
  GlimsFilterID filter = 0;
  char *error = NULL;
  gboolean undo_frozen = FALSE;
  printf ("OBS Oilify role %d\n", role);
  NEED (setup_oilify_case (engine, &ref, role) && read_pixels (ref.f.target, FALSE, ref_before), "separate native reference scene opens");
  NEED (reference_oilify (&ref, &expected_preview, &expected_applied, expected_raw), "direct early-freeze Core graph produces preview and merge");
  CHECK (memcmp (ref_before, expected_raw, BYTES) != 0, "independent native result is a nontrivial pixel change");
  if (!admitted) goto cleanup;
  NEED (setup_oilify_case (engine, &c, role) && capture_oilify_frame (&c.f, &before) &&
        read_pixels (c.f.target, FALSE, raw_before) && api->image_undo_info (engine, c.f.id, &undo) == GLIMS_STATUS_OK,
        "facade scene captures original stored bytes, projection and history");
  GimpContainer *stack = gimp_drawable_get_filters (GIMP_DRAWABLE (c.f.target));
  gint effects_before = gimp_container_get_n_children (stack);
  GlimsItemID radius = c.radius ? item_id (c.radius) : 0, exponent = c.exponent ? item_id (c.exponent) : 0;
  NEED (read_pixels (c.f.source, TRUE, source_before), "source appearance is captured independently");
  for (guint apply = 0; apply < 2; apply++) {
    OilifyAttach observed = {.f = &c.f};
    gulong hook = g_signal_connect (stack, "add", G_CALLBACK (check_oilify_attachment), &observed);
    GlimsStatus status = api->filter_begin_oilify_with_sources (engine, c.f.id, item_id (c.f.target),
                                                              radius, exponent, &filter, &error);
    g_signal_handler_disconnect (stack, hook);
    NEED (status == GLIMS_STATUS_OK && filter > 0 && set_oilify_settings (engine, filter), "facade begins with the requested optional maps and scalar settings");
    printf ("OBS Oilify attachment adds=%u inactive=%d close-status=%d\n",
            observed.adds, observed.inactive, (gint) observed.close_status);
    CHECK (observed.adds == 1 && observed.inactive, "native attachment adds one inactive stack item");
    CHECK (observed.close_status == GLIMS_STATUS_BUSY, "native attachment refuses reentrant image close");
    GlimsFilterValue v = {.kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 101};
    CHECK (api->filter_set_property (engine, filter, "mask-radius", &v) == GLIMS_STATUS_INVALID_ARGUMENT &&
           api->filter_get_property (engine, filter, "mask-radius", &v) == GLIMS_STATUS_OK && v.integer == OILIFY_FIXTURE_RADIUS,
           "ordinary scalar validation retains the accepted radius");
    NEED (capture_oilify_frame (&c.f, &after) && !memcmp (&after, &expected_preview, sizeof after),
          "drawable and image projection match the independent native preview exactly");
    CHECK (read_pixels (c.f.target, FALSE, raw) && !memcmp (raw, raw_before, BYTES) && undo_equal (engine, c.f.id, &undo),
           "preview keeps raw pixels and native history intact");
    if (!apply) {
      NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Cancel releases the owned preview"); filter = 0;
      CHECK (capture_oilify_frame (&c.f, &after) && !memcmp (&after, &before, sizeof after) &&
             read_pixels (c.f.target, FALSE, raw) && !memcmp (raw, raw_before, BYTES) && undo_equal (engine, c.f.id, &undo),
             "Cancel restores exact raw and rendered bytes with no Undo");
    } else {
      CHECK (read_pixels (c.f.source, TRUE, raw) && !memcmp (raw, source_before, BYTES), "capturing and previewing leave source pixels unchanged");
      if (role == OILIFY_BOTH) {
        write_pixels (c.f.source, FALSE, FALSE);
        g_object_ref (c.exponent);
        gimp_image_remove_layer (c.f.image, c.exponent, FALSE, NULL);
        gboolean detached = !gimp_item_is_attached (GIMP_ITEM (c.exponent));
        g_object_unref (c.exponent);
        c.exponent = NULL;
        NEED (detached && read_pixels (c.f.source, TRUE, raw) && memcmp (raw, source_before, BYTES) != 0,
              "source lifetime control changes one map and detaches the other");
        GlimsFilterValue changed_radius = {.kind = GLIMS_FILTER_VALUE_INTEGER, .integer = 5};
        NEED (api->filter_set_property (engine, filter, "mask-radius", &changed_radius) == GLIMS_STATUS_OK &&
              set_oilify_settings (engine, filter), "changed settings force reevaluation of the captured maps");
        CHECK (capture_oilify_frame (&c.f, &after) && !memcmp (&after, &expected_preview, sizeof after),
               "captured maps survive native source edit and removal during the owned preview");
      }
      if (role == OILIFY_PLAIN) {
        gimp_image_undo_freeze (c.f.image); undo_frozen = TRUE;
        CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY,
               "plain Oilify also refuses Apply while Undo is frozen");
        clear_error (&error);
        gimp_image_undo_thaw (c.f.image); undo_frozen = FALSE;
        CHECK (capture_oilify_frame (&c.f, &after) && !memcmp (&after, &expected_preview, sizeof after),
               "refused plain Apply retains its live preview");
      }
      NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "Apply merges the owned Oilify graph"); filter = 0;
      CHECK (read_pixels (c.f.target, FALSE, raw) && !memcmp (raw, expected_raw, BYTES) &&
             capture_oilify_frame (&c.f, &after) && !memcmp (&after, &expected_applied, sizeof after),
             "stored pixels and projection match the independently merged result exactly");
      CHECK (api->image_undo_info (engine, c.f.id, &merged) == GLIMS_STATUS_OK && merged.undo_count == undo.undo_count + 1 &&
             gimp_container_get_n_children (stack) == effects_before,
             "Apply adds one native Undo and retains exactly the pre-existing target effects");
      CHECK (api->image_undo (engine, c.f.id) == GLIMS_STATUS_OK && read_pixels (c.f.target, FALSE, raw) &&
             !memcmp (raw, raw_before, BYTES), "one Undo restores all raw target bytes");
      CHECK (api->image_redo (engine, c.f.id) == GLIMS_STATUS_OK && read_pixels (c.f.target, FALSE, raw) &&
             !memcmp (raw, expected_raw, BYTES), "one Redo restores the exact merged bytes");
    }
  }
cleanup:
  if (undo_frozen) gimp_image_undo_thaw (c.f.image);
  if (filter) api->filter_abort (engine, filter);
  clear_error (&error);
  fixture_close (&c.f); fixture_close (&ref.f);
}

static void
refuse_oilify (Fixture *f, GlimsItemID target, GlimsItemID r, GlimsItemID e,
              GlimsStatus expected, const gchar *reason, const gchar *message)
{
  GlimsUndoInfo undo = {0};
  GimpContainer *stack = gimp_drawable_get_filters (GIMP_DRAWABLE (f->target));
  gint count = gimp_container_get_n_children (stack);
  gboolean ready = api->image_undo_info (f->engine, f->id, &undo) == GLIMS_STATUS_OK;
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->target));
  const Babl *format = babl_format_with_space ("RGBA float", gegl_buffer_get_format (buffer));
  gfloat before[BYTES], after[BYTES];
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1, format, before, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  GlimsFilterID filter = 123;
  char *error = NULL;
  OilifyAttach observed = {.f = f};
  gulong hook = g_signal_connect (stack, "add", G_CALLBACK (check_oilify_attachment), &observed);
  GlimsStatus status = api->filter_begin_oilify_with_sources (f->engine, f->id, target, r, e, &filter, &error);
  g_signal_handler_disconnect (stack, hook);
  buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (f->target));
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 1, format, after, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  CHECK (ready && status == expected && filter == 0 && (!reason || (error && strstr (error, reason))) &&
         observed.adds == 0 && !memcmp (before, after, sizeof before) &&
         gimp_container_get_n_children (stack) == count && undo_equal (f->engine, f->id, &undo), message);
  if (status == GLIMS_STATUS_OK && filter) api->filter_abort (f->engine, filter);
  clear_error (&error);
}

static void
oilify_aggregate_budget (Fixture *f)
{
  GimpLayer *sources[2] = {NULL, NULL};
  GeglBuffer *buffers[2] = {NULL, NULL};
  GeglTileHandler *guards[2] = {NULL, NULL};
  gboolean attached[2] = {FALSE, FALSE};
  uint64_t bytes[2] = {0};
  for (guint i = 0; i < 2; i++) {
    sources[i] = gimp_layer_new (f->image, 16384, 4097, gimp_image_get_layer_format (f->image, TRUE),
                                 "Sparse Oilify map", 1, GIMP_LAYER_MODE_NORMAL);
    NEED (sources[i] != NULL, "sparse budget map is constructed");
    gimp_item_set_visible (GIMP_ITEM (sources[i]), FALSE, FALSE);
    buffers[i] = gimp_drawable_get_buffer (GIMP_DRAWABLE (sources[i]));
    guards[i] = g_object_new (GEGL_TYPE_TILE_HANDLER, NULL);
    GEGL_TILE_SOURCE (guards[i])->command = forbid_sparse_pixels;
    gegl_buffer_add_handler (buffers[i], guards[i]);
    attached[i] = gimp_image_add_layer (f->image, sources[i], NULL, 0, FALSE);
    NEED (attached[i], "sparse budget map attaches without tile reads");
    const GeglRectangle *r = gegl_buffer_get_extent (buffers[i]);
    bytes[i] = (uint64_t) r->width * r->height * babl_format_get_bytes_per_pixel (gegl_buffer_get_format (buffers[i]));
  }
  CHECK (bytes[0] <= GLIMS_MAX_PIXEL_BUFFER_BYTES && bytes[1] <= GLIMS_MAX_PIXEL_BUFFER_BYTES &&
         bytes[0] + bytes[1] > GLIMS_MAX_PIXEL_BUFFER_BYTES, "only the combined native map payload exceeds the snapshot budget");
  refuse_oilify (f, item_id (f->target), item_id (sources[0]), item_id (sources[1]), GLIMS_STATUS_FAILED,
                 "512 MiB", "aggregate budget refuses before either guarded map is copied");
cleanup:
  for (guint i = 0; i < 2; i++) {
    if (guards[i]) gegl_buffer_remove_handler (buffers[i], guards[i]);
    g_clear_object (&guards[i]);
    if (sources[i] && !attached[i]) g_object_unref (sources[i]);
  }
}

static void
oilify_refusals (GlimsEngine *engine)
{
  Fixture f = {0}, other = {0}, floating = {.engine = engine};
  GimpLayer *wide = NULL, *tall = NULL;
  GlimsFilterID filter = 0;
  char *error = NULL;
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &other, FALSE), "role refusal images open");
  GlimsItemID target = item_id (f.target), source = item_id (f.source);
  refuse_oilify (&f, target, -1, 0, GLIMS_STATUS_INVALID_ARGUMENT, NULL, "negative radius role refuses");
  refuse_oilify (&f, target, source, -1, GLIMS_STATUS_INVALID_ARGUMENT, NULL, "negative exponent role refuses");
  refuse_oilify (&f, target, source, item_id (other.source), GLIMS_STATUS_NOT_FOUND, "attached", "foreign second role refuses atomically");
  GimpLayer *stale = add_layer (f.image, "Detached map", FALSE, FALSE);
  NEED (stale != NULL, "a real same-image map is available before removal");
  GlimsItemID stale_id = item_id (stale);
  g_object_ref (stale);
  gimp_image_remove_layer (f.image, stale, FALSE, NULL);
  refuse_oilify (&f, target, source, stale_id, GLIMS_STATUS_NOT_FOUND, "attached", "retained but detached map refuses atomically");
  g_object_unref (stale);
  refuse_oilify (&f, target, source, G_MAXINT, GLIMS_STATUS_NOT_FOUND, "attached", "missing second role refuses atomically");
  /* Each skinny map fits the byte budget. Their 23170 squared union also
   * fits the unpadded four-channel gint count; the 100px halo does not. */
  wide = gimp_layer_new (f.image, 23170, 1, gimp_image_get_layer_format (f.image, TRUE), "Wide extent", 1, GIMP_LAYER_MODE_NORMAL);
  tall = gimp_layer_new (f.image, 1, 23170, gimp_image_get_layer_format (f.image, TRUE), "Tall extent", 1, GIMP_LAYER_MODE_NORMAL);
  NEED (wide && tall, "small-payload union overflow inputs are constructed");
  gimp_item_set_visible (GIMP_ITEM (wide), FALSE, FALSE);
  gimp_item_set_visible (GIMP_ITEM (tall), FALSE, FALSE);
  NEED (gimp_image_add_layer (f.image, wide, NULL, 0, FALSE) && gimp_image_add_layer (f.image, tall, NULL, 0, FALSE),
        "skinny map extents are attached without large canvas allocation");
  refuse_oilify (&f, target, item_id (wide), item_id (tall), GLIMS_STATUS_UNSUPPORTED, "native pixel arithmetic",
                 "radius-padded union refuses despite small individual map payloads");
  oilify_aggregate_budget (&f);

  GimpImage *image = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_RGB, GIMP_PRECISION_FLOAT_LINEAR, FALSE);
  NEED (image && glims_adopt_image (engine, image, &floating.id) == GLIMS_STATUS_OK, "linear float refusal image opens");
  floating.image = image;
  floating.target = add_layer (image, "Float target", TRUE, FALSE);
  floating.source = add_layer (image, "Float map", FALSE, FALSE);
  NEED (floating.target && floating.source, "actual float layer buffers are installed");
  gimp_item_set_visible (GIMP_ITEM (floating.source), FALSE, FALSE);
  GeglBuffer *target_buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (floating.target));
  GeglBuffer *map_buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (floating.source));
  const Babl *space = babl_format_get_space (gegl_buffer_get_format (target_buffer));
  const Babl *rgba = babl_format_with_space ("RGBA float", space);
  const Babl *luma = babl_format_with_space ("Y float", space);
  const GeglRectangle sample = {3, 4, 1, 1};
  gfloat point[] = {0.25f, 0.25f, 0.25f, NAN}, converted[4];
  gegl_buffer_set (target_buffer, &sample, 0, rgba, point, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (floating.target), sample.x, sample.y, 1, 1);
  gegl_buffer_get (target_buffer, &sample, 1, rgba, converted, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  NEED (!isfinite (converted[3]), "native converted target alpha really is nonfinite");
  refuse_oilify (&floating, item_id (floating.target), 0, 0, GLIMS_STATUS_UNSUPPORTED, "finite target",
                 "plain Oilify refuses a nonfinite actual target before attachment");
  point[3] = 1.f;
  gegl_buffer_set (target_buffer, &sample, 0, rgba, point, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (floating.target), sample.x, sample.y, 1, 1);
  point[0] = point[1] = point[2] = NAN;
  gegl_buffer_set (map_buffer, &sample, 0, rgba, point, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (floating.source), sample.x, sample.y, 1, 1);
  gegl_buffer_get (map_buffer, &sample, 1, luma, converted, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  NEED (!isfinite (converted[0]), "native converted map luminance really is nonfinite");
  refuse_oilify (&floating, item_id (floating.target), 0, item_id (floating.source), GLIMS_STATUS_UNSUPPORTED, "finite luminance",
                 "exponent-only Oilify refuses nonfinite captured luminance before attachment");
  point[0] = point[1] = point[2] = -0.25f;
  gegl_buffer_set (map_buffer, &sample, 0, rgba, point, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (floating.source), sample.x, sample.y, 1, 1);
  gegl_buffer_get (map_buffer, &sample, 1, luma, converted, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  NEED (isfinite (converted[0]) && converted[0] < 0, "the finite clamp control retains negative native luminance");
  NEED (api->filter_begin_oilify_with_sources (engine, floating.id, item_id (floating.target), 0,
                                             item_id (floating.source), &filter, &error) == GLIMS_STATUS_OK && filter > 0,
        "finite out-of-range luminance remains a valid native clamped input");
  GlimsFilterID old = filter;
  NEED (api->image_close (engine, floating.id) == GLIMS_STATUS_OK, "closing an owned Oilify preview releases its inputs");
  floating.id = 0; filter = 0;
  CHECK (api->filter_abort (engine, old) == GLIMS_STATUS_NOT_FOUND, "closed filter id cannot outlive its image");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (wide && !gimp_item_is_attached (GIMP_ITEM (wide))) g_object_unref (wide);
  if (tall && !gimp_item_is_attached (GIMP_ITEM (tall))) g_object_unref (tall);
  clear_error (&error); fixture_close (&floating); fixture_close (&other); fixture_close (&f);
}

static GlimsStatus
run_oilify_source_suite (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  g_object_set (gegl_config (), "use-opencl", FALSE, NULL);
  gboolean admitted = has_oilify_sources ();
  for (OilifyRole role = OILIFY_PLAIN; role <= OILIFY_TARGET_MAP; role++) oilify_pixel_case (engine, role, admitted);
  CHECK (admitted, "slot170 is available without reading beyond an old API table");
  if (admitted) oilify_refusals (engine);
  else printf ("OBS slot170-dependent cases not run on the old producer\n");
  return GLIMS_STATUS_OK;
}

static gboolean
write_ui_frame (const gchar *dir, const gchar *name, const OilifyFrame *frame)
{
  gchar *path = g_build_filename (dir, name, NULL);
  GError *error = NULL;
  gboolean ok = g_file_set_contents (path, (const gchar *) frame->projection, BYTES, &error);
  if (!ok) fprintf (stderr, "%s\n", error->message);
  g_clear_error (&error);
  g_free (path);
  return ok;
}

/* The AppKit fixture opens the same XCF as each independent Core graph.
 * No expected pixels are generated by the owned Oilify facade. */
static GlimsStatus
export_oilify_ui_fixture (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  OilifyCase c = {0};
  OilifyFrame before, preview, applied;
  guint8 raw[BYTES];
  char *error = NULL;
  gchar *dir = g_build_filename (work_dir, "artifacts", NULL);
  gchar *seed = g_build_filename (dir, "seed.xcf", NULL);
  g_object_set (gegl_config (), "use-opencl", FALSE, NULL);
  NEED (g_mkdir (dir, 0700) == 0 && setup_oilify_case (engine, &c, OILIFY_RADIUS),
        "UI oracle prepares the bounded native scene");
  c.exponent = add_layer (c.f.image, "Exponent map", FALSE, FALSE);
  NEED (c.exponent != NULL, "UI oracle attaches a distinct exponent map");
  gimp_item_set_visible (GIMP_ITEM (c.exponent), FALSE, FALSE);
  gimp_item_set_offset (GIMP_ITEM (c.exponent), 8, -3);
  NEED (api->image_save (engine, c.f.id, seed, &error) == GLIMS_STATUS_OK,
        "UI oracle retains the same seed XCF for every role");
  NEED (api->image_close (engine, c.f.id) == GLIMS_STATUS_OK, "UI oracle closes its seed image");
  c.f.id = 0;

  const gchar *previews[] = {"plain-preview.rgba", "radius-preview.rgba", "exponent-preview.rgba"};
  const gchar *applied_frames[] = {"plain-applied.rgba", "radius-applied.rgba", "exponent-applied.rgba"};
  for (guint role = OILIFY_PLAIN; role <= OILIFY_EXPONENT; role++) {
    NEED (api->image_open (engine, seed, &c.f.id, &error) == GLIMS_STATUS_OK,
          "UI oracle opens an independent seed copy");
    c.f.image = glims_lookup_image (engine, c.f.id)->image;
    c.f.target = gimp_image_get_layer_by_name (c.f.image, "RGBA target");
    c.f.source = gimp_image_get_layer_by_name (c.f.image, "Height source");
    GimpLayer *exponent = gimp_image_get_layer_by_name (c.f.image, "Exponent map");
    NEED (c.f.target && c.f.source && exponent && capture_oilify_frame (&c.f, &before),
          "UI oracle finds the same three named layer identities and original projection");
    c.radius = role == OILIFY_RADIUS ? c.f.source : NULL;
    c.exponent = role == OILIFY_EXPONENT ? exponent : NULL;
    NEED (reference_oilify (&c, &preview, &applied, raw) &&
          memcmp (preview.projection, before.projection, BYTES) != 0 &&
          memcmp (applied.projection, before.projection, BYTES) != 0,
          "UI oracle independently changes the projection in both stages");
    NEED ((role != OILIFY_PLAIN || write_ui_frame (dir, "before.rgba", &before)) &&
          write_ui_frame (dir, previews[role], &preview) && write_ui_frame (dir, applied_frames[role], &applied),
          "UI oracle retains exact 32-by-32 projection bytes");
    NEED (api->image_close (engine, c.f.id) == GLIMS_STATUS_OK, "UI oracle closes its reference image");
    c.f.id = 0;
  }
cleanup:
  if (error) fprintf (stderr, "%s\n", error);
  clear_error (&error);
  fixture_close (&c.f);
  g_free (seed);
  g_free (dir);
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

static gboolean
private_run_environment (const gchar *root)
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
  gboolean ui_fixture = argc == 3 && !strcmp (argv[2], "--ui-fixture");
  if ((argc != 2 && !ui_fixture) || !g_path_is_absolute (argv[1]) || !private_run_environment (argv[1])) return 2;
  work_dir = argv[1];
  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, filter_begin_oilify_with_sources) ||
      api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "native startup failed");
    if (api) clear_error (&error);
    g_free (user); g_free (cache);
    return 2;
  }
  if (ui_fixture)
    CHECK (glims_engine_call (engine, export_oilify_ui_fixture, NULL) == GLIMS_STATUS_OK, "UI oracle runs on the engine thread");
  else
    CHECK (glims_engine_call (engine, run_oilify_source_suite, NULL) == GLIMS_STATUS_OK, "facade suite runs on the engine thread");
  api->stop (engine);
  if (!ui_fixture && has_oilify_sources ()) {
    GlimsFilterID stopped = 123;
    CHECK (api->filter_begin_oilify_with_sources (NULL, 1, 1, 0, 0, &stopped, NULL) == GLIMS_STATUS_NOT_RUNNING && stopped == 0,
           "stopped-engine dispatch clears the output");
  }
  g_free (user); g_free (cache);
  printf ("%s: %d Oilify source checks, %d failures\n", failures ? "FAILED" : "PASSED", oilify_source_checks, failures);
  return failures != 0;
}
