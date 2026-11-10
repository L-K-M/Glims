/* Independent dual-source facade harness for slot169
 * filter_begin_displace_with_sources. Source-only; never executed by this task.
 *
 * No new private filter fields are read anywhere. All semantic cases build fresh
 * GEGL buffers/graphs and compare against the public facade; original included
 * fixture suites are renamed away and never run. */
#define main displace_existing_input_main
#include "filter-input-tests.c"
#undef main
#undef CHECK

#include <stddef.h>
#include "gegl-operations-util.h"

static int displace_checks;
#define CHECK(c, text) do { \
  gboolean ok_ = (c); displace_checks++; \
  printf ("%s displace source: %s\n", ok_ ? "ok  " : "FAIL", text); \
  if (!ok_) failures++; fflush (stdout); \
} while (0)

#define DISPLACE_OP "gegl:displace"

/* Guard169: admit old168 producers; read the function pointer only after the
 * struct extends past the slot. */
static gboolean
has_displace_sources (const GlimsEngineAPI *a)
{
  return a &&
         a->struct_size >= offsetof (GlimsEngineAPI, filter_begin_displace_with_sources) +
                           sizeof (a->filter_begin_displace_with_sources) &&
         a->filter_begin_displace_with_sources != NULL;
}

static gboolean displace_admitted;

typedef struct {
  gdouble amount_x, amount_y, center_x, center_y;
  const gchar *displace_mode; /* nick for GEGL/facade enum choice */
  const gchar *sampler_type;
  const gchar *abyss_policy;
  gboolean do_center;
} DisplaceSettings;

static const DisplaceSettings cartesian_default = {
  .amount_x = 6.0, .amount_y = 4.0, .center_x = 0.5, .center_y = 0.5,
  .displace_mode = "cartesian", .sampler_type = "linear", .abyss_policy = "clamp",
  .do_center = FALSE
};

static gboolean
set_displace (GlimsEngine *engine, GlimsFilterID filter, const DisplaceSettings *s)
{
  GlimsFilterValue v;
  v.kind = GLIMS_FILTER_VALUE_NUMBER; v.number = s->amount_x;
  if (api->filter_set_property (engine, filter, "amount-x", &v) != GLIMS_STATUS_OK) return FALSE;
  v.number = s->amount_y;
  if (api->filter_set_property (engine, filter, "amount-y", &v) != GLIMS_STATUS_OK) return FALSE;
  v.kind = GLIMS_FILTER_VALUE_ENUM; v.string = s->displace_mode;
  if (api->filter_set_property (engine, filter, "displace-mode", &v) != GLIMS_STATUS_OK) return FALSE;
  v.string = s->sampler_type;
  if (api->filter_set_property (engine, filter, "sampler-type", &v) != GLIMS_STATUS_OK) return FALSE;
  v.string = s->abyss_policy;
  if (api->filter_set_property (engine, filter, "abyss-policy", &v) != GLIMS_STATUS_OK) return FALSE;
  v.kind = GLIMS_FILTER_VALUE_BOOL; v.boolean = s->do_center;
  if (api->filter_set_property (engine, filter, "center", &v) != GLIMS_STATUS_OK) return FALSE;
  v.kind = GLIMS_FILTER_VALUE_NUMBER; v.number = s->center_x;
  if (api->filter_set_property (engine, filter, "center-x", &v) != GLIMS_STATUS_OK) return FALSE;
  v.number = s->center_y;
  if (api->filter_set_property (engine, filter, "center-y", &v) != GLIMS_STATUS_OK) return FALSE;
  return TRUE;
}

static void
write_layer_bytes (GimpLayer *layer, const guint8 pixels[BYTES])
{
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)),
                   GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0, babl_format ("R'G'B'A u8"),
                   pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, SIDE, SIDE);
}

static void
fill_displace_fixture (Fixture *f,
                       guint8 target[BYTES], guint8 xmap[BYTES], guint8 ymap[BYTES],
                       gboolean target_partial_alpha, gboolean x_partial_alpha, gboolean y_partial_alpha)
{
  for (guint y = 0; y < SIDE; y++) for (guint x = 0; x < SIDE; x++) {
    guint i = (y * SIDE + x) * 4;
    target[i + 0] = (guint8) (17 + x * 5 + (y & 3) * 11);
    target[i + 1] = (guint8) (23 + y * 4 + (x & 7) * 7);
    target[i + 2] = (guint8) (41 + x * 3 + y * 2);
    target[i + 3] = target_partial_alpha ? (guint8) (40 + (x * 13 + y * 9) % 216) : 255;

    /* Distinct asymmetric X/Y maps in target input space (Y' float conversion
     * is performed by GEGL in the graph/input space). */
    xmap[i + 0] = (guint8) (10 + x * 7);
    xmap[i + 1] = (guint8) (200 - y * 3);
    xmap[i + 2] = (guint8) (x * 29 + y * 5);
    xmap[i + 3] = x_partial_alpha ? (guint8) ((x + y * 3) % 256) : 255;

    ymap[i + 0] = (guint8) (240 - x * 4);
    ymap[i + 1] = (guint8) (5 + y * 6);
    ymap[i + 2] = (guint8) (180 - (x * 3 + y * 11));
    ymap[i + 3] = y_partial_alpha ? (guint8) (255 - (x * 17 + y) % 256) : 255;
  }
  write_layer_bytes (f->target, target);
  write_layer_bytes (f->source, xmap);
  /* A distinct second source layer is used as Y map in per-case setup. */
  (void) ymap;
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

static GeglBuffer *
fresh_buffer_u8 (const guint8 pixels[BYTES], const Babl *format)
{
  GeglBuffer *buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, SIDE, SIDE), format);
  if (buffer) gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, SIDE, SIDE), 0,
                               babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  return buffer;
}

/* Resolve native enum nicks through official operation metadata; enum values
 * stay inside this native-only oracle, never cross the facade. */
static gboolean
configure_node (GeglNode *op, const DisplaceSettings *s)
{
  const gchar *properties[] = {"displace-mode", "sampler-type", "abyss-policy"};
  const gchar *nicks[] = {s->displace_mode, s->sampler_type, s->abyss_policy};
  for (guint i = 0; i < G_N_ELEMENTS (properties); i++) {
    GParamSpec *spec = gegl_operation_find_property (DISPLACE_OP, properties[i]);
    if (!spec || !G_IS_PARAM_SPEC_ENUM (spec)) return FALSE;
    GEnumClass *klass = g_type_class_ref (G_PARAM_SPEC_VALUE_TYPE (spec));
    GEnumValue *value = g_enum_get_value_by_nick (klass, nicks[i]);
    gboolean found = value != NULL;
    if (found) gegl_node_set (op, properties[i], value->value, NULL);
    g_type_class_unref (klass);
    if (!found) return FALSE;
  }
  gegl_node_set (op, "amount-x", s->amount_x, "amount-y", s->amount_y,
                 "center", s->do_center, "center-x", s->center_x,
                 "center-y", s->center_y, NULL);
  return TRUE;
}

/* Fresh direct GEGL graph oracle: input/aux(x)/aux2(y) connected explicitly.
 * Never uses glims_filter_input_snapshot, never inspects target/session/native
 * preview nodes, and never reads facade output to construct expected pixels. */
static gboolean
displace_oracle (const guint8 target[BYTES], const guint8 xmap[BYTES], const guint8 ymap[BYTES],
                 const Babl *target_format, const Babl *x_format, const Babl *y_format,
                 const DisplaceSettings *s, guint8 out[BYTES])
{
  GeglBuffer *inb = fresh_buffer_u8 (target, target_format);
  GeglBuffer *xb = fresh_buffer_u8 (xmap, x_format);
  GeglBuffer *yb = fresh_buffer_u8 (ymap, y_format);
  GeglNode *graph = gegl_node_new ();
  gboolean ok = FALSE;
  if (!inb || !xb || !yb || !graph) goto cleanup;
  GeglNode *in = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", inb, NULL);
  GeglNode *xs = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", xb, NULL);
  GeglNode *ys = gegl_node_new_child (graph, "operation", "gegl:buffer-source", "buffer", yb, NULL);
  GeglNode *op = gegl_node_new_child (graph, "operation", DISPLACE_OP, NULL);
  if (!in || !xs || !ys || !op || !configure_node (op, s)) goto cleanup;
  if (!connect_pad (in, op, "input") || !connect_pad (xs, op, "aux") || !connect_pad (ys, op, "aux2")) goto cleanup;
  gegl_node_blit (op, 1, GEGL_RECTANGLE (0, 0, SIDE, SIDE), babl_format ("R'G'B'A u8"),
                  out, GEGL_AUTO_ROWSTRIDE, GEGL_BLIT_DEFAULT);
  ok = TRUE;
cleanup:
  g_clear_object (&graph);
  g_clear_object (&yb);
  g_clear_object (&xb);
  g_clear_object (&inb);
  return ok;
}

static GlimsStatus
begin_maps (Fixture *f, GlimsItemID x, GlimsItemID y, GlimsFilterID *out, char **error)
{
  if (out) *out = 0;
  if (!has_displace_sources (api)) return GLIMS_STATUS_UNSUPPORTED;
  return api->filter_begin_displace_with_sources (f->engine, f->id,
           item_id (f->target), x, y, out, error);
}

/* Copy all native-format effect pixels into newly allocated storage. This
 * expected-input path does not use the adapter's snapshot helper or nodes. */
static GeglBuffer *
reference_buffer (GimpLayer *layer)
{
  GeglBuffer *live = NULL, *fresh = NULL;
  gimp_pickable_flush (GIMP_PICKABLE (layer));
  live = gimp_drawable_get_buffer_with_effects (GIMP_DRAWABLE (layer));
  if (!live) return NULL;
  const GeglRectangle *rect = gegl_buffer_get_extent (live);
  const Babl *format = gegl_buffer_get_format (live);
  gsize bytes = (gsize) rect->width * rect->height * babl_format_get_bytes_per_pixel (format);
  if (rect->width > 0 && rect->height > 0 && bytes <= 1024 * 1024) {
    gpointer data = g_malloc (bytes);
    gegl_buffer_get (live, rect, 1, format, data, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    fresh = gegl_buffer_new (rect, format);
    if (fresh) gegl_buffer_set (fresh, rect, 0, format, data, GEGL_AUTO_ROWSTRIDE);
    g_free (data);
  }
  g_object_unref (live);
  return fresh;
}

static gboolean
native_brightness (GimpLayer *layer, gdouble brightness)
{
  GeglNode *op = gegl_node_new_child (NULL, "operation", "gegl:brightness-contrast",
                                    "brightness", brightness, NULL);
  GimpDrawableFilter *fx = op ? gimp_drawable_filter_new (GIMP_DRAWABLE (layer), "Map fixture effect", op, NULL) : NULL;
  gboolean ok = FALSE;
  if (fx) {
    gimp_drawable_filter_apply (fx, NULL);
    ok = gimp_drawable_filter_commit (fx, TRUE, NULL, FALSE);
    if (ok) gimp_drawable_filter_set_temporary (fx, FALSE);
    else gimp_drawable_filter_abort (fx);
  }
  g_clear_object (&fx); g_clear_object (&op);
  return ok;
}

/* Independent Core compositing/merge oracle on a separately seeded image.
 * Maps are fresh fixture buffers; no adapter filter session is inspected. */
static gboolean
native_oracle (Fixture *reference, GeglBuffer *x, GeglBuffer *y,
               const DisplaceSettings *settings, guint8 preview[BYTES], guint8 merged[BYTES])
{
  GeglNode *op = gegl_node_new_child (NULL, "operation", DISPLACE_OP, NULL);
  GeglNode *xn = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", x, NULL);
  GeglNode *yn = gegl_node_new_child (NULL, "operation", "gegl:buffer-source", "buffer", y, NULL);
  GimpDrawableFilter *fx = NULL;
  gboolean ok = FALSE, attached = FALSE;
  if (!op || !xn || !yn || !configure_node (op, settings) ||
      !connect_pad (xn, op, "aux") || !connect_pad (yn, op, "aux2")) goto cleanup;
  fx = gimp_drawable_filter_new (GIMP_DRAWABLE (reference->target), "Independent Displace", op, NULL);
  if (!fx) goto cleanup;
  g_object_set (fx, "to-be-merged", TRUE, NULL);
  gimp_drawable_filter_set_temporary (fx, TRUE);
  gimp_drawable_filter_apply (fx, NULL); attached = TRUE;
  gimp_drawable_filter_set_preview (fx, TRUE);
  gimp_image_flush (reference->image);
  if (!read_pixels (reference->target, TRUE, preview)) goto cleanup;
  gimp_drawable_filter_layer_mask_freeze (fx);
  if (!gimp_drawable_filter_commit (fx, FALSE, NULL, FALSE)) goto cleanup;
  attached = FALSE;
  gimp_image_flush (reference->image);
  ok = read_pixels (reference->target, FALSE, merged);
cleanup:
  if (attached) gimp_drawable_filter_abort (fx);
  g_clear_object (&fx); g_clear_object (&op); g_clear_object (&xn); g_clear_object (&yn);
  return ok;
}

static GlimsStatus
setup_oracle (GlimsEngine *engine, gpointer unused)
{
  (void) engine; (void) unused;
  guint8 target[BYTES], x[BYTES], y[BYTES], expected[BYTES], actual[BYTES], xonly[BYTES], yonly[BYTES], swapped[BYTES];
  for (guint row = 0; row < SIDE; row++) for (guint col = 0; col < SIDE; col++) {
    guint i = (row * SIDE + col) * 4;
    target[i] = col * 7; target[i+1] = row * 7; target[i+2] = col ^ row; target[i+3] = 255;
    x[i] = x[i+1] = x[i+2] = 255; x[i+3] = 255;
    y[i] = y[i+1] = y[i+2] = 0; y[i+3] = 255;
    guint sx = MIN (col + 1, SIDE - 1), sy = row ? row - 1 : 0;
    expected[i] = sx * 7; expected[i+1] = sy * 7; expected[i+2] = sx ^ sy; expected[i+3] = 255;
  }
  DisplaceSettings settings = cartesian_default;
  settings.amount_x = settings.amount_y = 1; settings.sampler_type = "nearest";
  const Babl *fmt = babl_format ("R'G'B'A u8");
  NEED (displace_oracle (target, x, y, fmt, fmt, fmt, &settings, actual), "fresh direct GEGL oracle renders independently of slot169");
  CHECK (!memcmp (actual, expected, BYTES), "literal nearest X+1/Y-1 translation and clamped edges match every RGBA byte");
  settings.amount_y = 0;
  NEED (displace_oracle (target, x, y, fmt, fmt, fmt, &settings, xonly), "direct X-only oracle renders");
  settings.amount_x = 0; settings.amount_y = 1;
  NEED (displace_oracle (target, x, y, fmt, fmt, fmt, &settings, yonly), "direct Y-only oracle renders");
  CHECK (memcmp (actual, xonly, BYTES) && memcmp (actual, yonly, BYTES) && memcmp (xonly, yonly, BYTES), "both map roles independently affect the literal grid");
  settings.amount_x = 1;
  NEED (displace_oracle (target, y, x, fmt, fmt, fmt, &settings, swapped), "swapped-map oracle renders");
  CHECK (memcmp (actual, swapped, BYTES), "swapping the two roles changes output");
  for (guint i = 3; i < BYTES; i += 4) x[i] = y[i] = 0;
  NEED (displace_oracle (target, x, y, fmt, fmt, fmt, &settings, actual), "zero-map-alpha oracle renders");
  CHECK (!memcmp (target, actual, BYTES), "zero map alpha suppresses both displacements exactly");
cleanup:
  return GLIMS_STATUS_OK;
}

static GlimsStatus
admission (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; char *error = NULL; GlimsFilterID filter = 123;
  gchar *before = NULL, *after = NULL;
  NEED (fixture_open (engine, &f, FALSE), "slot169 admission fixture opens");
  before = fingerprint (&f);
  GlimsStatus status = begin_maps (&f, item_id (f.source), item_id (f.source), &filter, &error);
  displace_admitted = status == GLIMS_STATUS_OK && filter > 0;
  CHECK (displace_admitted, "missing169: appended Displace dual-source begin is admitted (baseline RED)");
  if (displace_admitted) {
    NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "admission preview aborts"); filter = 0;
  } else {
    CHECK (status == GLIMS_STATUS_UNSUPPORTED && filter == 0 && !has_displace_sources (api), "old168 capability refusal is explicit and never reads the missing slot");
  }
  after = fingerprint (&f);
  CHECK (before && after && !strcmp (before, after) && g_hash_table_size (engine->filters) == 0, "admission probe leaves exact stored image/history and no session");
cleanup:
  if (filter > 0 && displace_admitted) api->filter_abort (engine, filter);
  g_free (before); g_free (after); clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static gboolean
resize_map (GimpLayer *layer, gint width, gint height)
{
  const Babl *format = gimp_drawable_get_format (GIMP_DRAWABLE (layer));
  GeglBuffer *buffer = gegl_buffer_new (GEGL_RECTANGLE (0, 0, width, height), format);
  if (!buffer) return FALSE;
  guint8 *pixels = g_malloc (width * height * 4);
  for (gint row = 0; row < height; row++) for (gint col = 0; col < width; col++) {
    guint i = (row * width + col) * 4;
    pixels[i] = col * 17; pixels[i+1] = row * 13; pixels[i+2] = (col + row) * 7; pixels[i+3] = (col + row) & 1 ? 127 : 255;
  }
  gegl_buffer_set (buffer, GEGL_RECTANGLE (0, 0, width, height), 0, babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_set_buffer (GIMP_DRAWABLE (layer), FALSE, NULL, buffer);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, width, height);
  g_free (pixels); g_object_unref (buffer);
  return TRUE;
}

/* Five fixtures: opaque Cartesian, partial-alpha Cartesian, centered Polar
 * with unequal map extents and item offsets, both maps with effects, same ID
 * in both roles with target-as-source. Expected uses independent native Core. */
static GlimsStatus
pixel_case (GlimsEngine *engine, gpointer data)
{
  gint mode = GPOINTER_TO_INT (data);
  Fixture f = {0}, reference = {0}; GimpLayer *ysrc = NULL;
  GeglBuffer *xb = NULL, *yb = NULL; GlimsFilterID filter = 0;
  char *error = NULL; gchar *before_facts = NULL, *after_facts = NULL;
  guint8 target[BYTES], x[BYTES], y[BYTES], baseline[BYTES], expected_preview[BYTES], expected_merged[BYTES], actual[BYTES], y_before[BYTES];
  GlimsUndoInfo before = {0}, after = {0};
  NEED (fixture_open (engine, &f, FALSE) && fixture_open (engine, &reference, FALSE), "facade and independent Core fixtures open");
  ysrc = add_layer (f.image, "Vertical map", FALSE, FALSE);
  NEED (ysrc != NULL, "distinct Y source attaches");
  gimp_item_set_visible (GIMP_ITEM (ysrc), FALSE, FALSE);
  fill_displace_fixture (&f, target, x, y, mode != 0, TRUE, TRUE);
  write_layer_bytes (ysrc, y); write_layer_bytes (reference.target, target);
  DisplaceSettings settings = cartesian_default;
  if (mode == 2) {
    NEED (resize_map (f.source, 11, 23) && resize_map (ysrc, 23, 13), "maps have genuinely unequal native buffer extents");
    gimp_item_set_offset (GIMP_ITEM (f.source), 5, -7); gimp_item_set_offset (GIMP_ITEM (ysrc), -3, 4);
    settings.displace_mode = "polar"; settings.do_center = TRUE;
    settings.center_x = .25; settings.center_y = .75;
    settings.amount_x = -7; settings.amount_y = 37;
  }
  if (mode == 3) {
    NEED (native_brightness (f.source, .2) && native_brightness (ysrc, -.15), "both source maps have independent committed native effects");
  }
  GimpLayer *xl = mode == 4 ? f.target : f.source;
  GimpLayer *yl = mode == 4 ? f.target : ysrc;
  xb = reference_buffer (xl); yb = reference_buffer (yl);
  NEED (xb && yb && read_pixels (f.target, FALSE, baseline) && read_pixels (ysrc, FALSE, y_before), "fresh native-format source references and raw target are captured before Begin");
  if (mode == 3) {
    guint8 effected[BYTES];
    NEED (read_pixels (f.source, TRUE, effected), "effected X map is independently readable");
    CHECK (memcmp (effected, x, BYTES), "source effect genuinely changes map pixels");
  }
  NEED (native_oracle (&reference, xb, yb, &settings, expected_preview, expected_merged), "fresh Core filter establishes preview and merge compositing without adapter snapshots");
  NEED (api->layer_select (engine, f.id, item_id (f.target)) == GLIMS_STATUS_OK && api->image_undo_info (engine, f.id, &before) == GLIMS_STATUS_OK, "original target selection and history are captured");
  gimp_item_set_lock_content (GIMP_ITEM (f.source), TRUE, FALSE);
  gimp_item_set_lock_content (GIMP_ITEM (ysrc), TRUE, FALSE);
  before_facts = fingerprint (&f);
  NEED (begin_maps (&f, item_id (xl), item_id (yl), &filter, &error) == GLIMS_STATUS_OK && set_displace (engine, filter, &settings), "two explicit maps begin and scalar/owned enum properties update");
  NEED (read_pixels (f.target, TRUE, actual), "facade preview is readable");
  CHECK (!memcmp (actual, expected_preview, BYTES), "preview matches independent Core RGBA byte for byte, including sampled alpha");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "Cancel succeeds"); filter = 0;
  after_facts = fingerprint (&f);
  CHECK (before_facts && after_facts && !strcmp (before_facts, after_facts) && read_pixels (ysrc, FALSE, actual) && !memcmp (actual, y_before, BYTES), "Cancel preserves every stored target/source byte and exact image/history facts");
  NEED (begin_maps (&f, item_id (xl), item_id (yl), &filter, &error) == GLIMS_STATUS_OK && set_displace (engine, filter, &settings), "Apply preview begins from the same captured source facts");
  NEED (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_OK, "Apply commits"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (actual, expected_merged, BYTES), "merged target matches independent Core output exactly");
  NEED (api->image_undo_info (engine, f.id, &after) == GLIMS_STATUS_OK, "post-commit history is readable");
  CHECK (after.undo_count == before.undo_count + 1, "Apply adds one native Undo");
  gint32 effects = -1;
  CHECK (api->drawable_effects (engine, f.id, item_id (f.target), NULL, 0, &effects) == GLIMS_STATUS_OK && effects == 0, "no auxiliary graph is persisted as a target effect");
  GlimsItemID selected[2] = {0}; gint32 count = 0;
  CHECK (api->image_selected_layers (engine, f.id, selected, 2, &count) == GLIMS_STATUS_OK && count == 1 && selected[0] == item_id (f.target), "explicit target selection is unchanged");
  CHECK (read_pixels (ysrc, FALSE, actual) && !memcmp (actual, y_before, BYTES), "Apply preserves the other source's raw bytes");
  NEED (api->image_undo (engine, f.id) == GLIMS_STATUS_OK, "Undo is accepted");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (actual, baseline, BYTES), "Undo restores every original target byte");
  NEED (api->image_redo (engine, f.id) == GLIMS_STATUS_OK, "Redo is accepted");
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (actual, expected_merged, BYTES), "Redo restores every independently expected merged byte");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  g_clear_object (&xb); g_clear_object (&yb); g_free (before_facts); g_free (after_facts);
  clear_error (&error); fixture_close (&reference); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

/* Each source is separately mutated and destroyed; re-evaluation must not retain
 * a live map graph. No facade-owned snapshot node or new private field is read. */
static GlimsStatus
lifetime_case (GlimsEngine *engine, gpointer data)
{
  gboolean y_role = GPOINTER_TO_INT (data);
  Fixture f = {0}; GimpLayer *ysrc = NULL; GlimsFilterID filter = 0;
  GWeakRef weak; gboolean weak_ready = FALSE; char *error = NULL;
  guint8 target[BYTES], x[BYTES], y[BYTES], preview[BYTES], actual[BYTES];
  NEED (fixture_open (engine, &f, FALSE), "source lifetime fixture opens");
  ysrc = add_layer (f.image, "Y lifetime map", FALSE, FALSE);
  NEED (ysrc != NULL, "Y lifetime map attaches");
  fill_displace_fixture (&f, target, x, y, TRUE, TRUE, TRUE); write_layer_bytes (ysrc, y);
  DisplaceSettings settings = cartesian_default;
  NEED (begin_maps (&f, item_id (f.source), item_id (ysrc), &filter, &error) == GLIMS_STATUS_OK && set_displace (engine, filter, &settings) && read_pixels (f.target, TRUE, preview), "captured dual-map preview renders before source destruction");
  GimpLayer *victim = y_role ? ysrc : f.source;
  g_weak_ref_init (&weak, G_OBJECT (victim)); weak_ready = TRUE;
  write_pixels (victim, FALSE, FALSE);
  settings.amount_x += 1;
  NEED (set_displace (engine, filter, &settings), "intervening parameter change invalidates the preview");
  settings.amount_x -= 1;
  NEED (set_displace (engine, filter, &settings), "original settings force a fresh graph evaluation");
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "mutating the live role cannot change captured output");
  gimp_image_remove_layer (f.image, victim, FALSE, NULL);
  if (y_role) ysrc = NULL; else f.source = NULL;
  gimp_image_undo_free (f.image);
  GObject *probe = g_weak_ref_get (&weak);
  CHECK (probe == NULL, "removed source finalizes after history purge while the preview survives"); g_clear_object (&probe);
  settings.amount_y += 1; NEED (set_displace (engine, filter, &settings), "deleted-source preview invalidates");
  settings.amount_y -= 1; NEED (set_displace (engine, filter, &settings), "deleted-source preview reevaluates with original settings");
  CHECK (read_pixels (f.target, TRUE, actual) && !memcmp (preview, actual, BYTES), "source destruction cannot change captured role output");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "source-independent preview cancels"); filter = 0;
  CHECK (read_pixels (f.target, FALSE, actual) && !memcmp (target, actual, BYTES), "lifetime Cancel preserves original target bytes");
cleanup:
  if (filter) api->filter_abort (engine, filter);
  if (weak_ready) g_weak_ref_clear (&weak);
  clear_error (&error); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static void
refuse_pair (Fixture *f, GlimsImageID image, GlimsItemID target, GlimsItemID x,
             GlimsItemID y, GlimsStatus expected, const char *label)
{
  gchar *before = fingerprint (f), *after = NULL; char *error = NULL;
  GlimsFilterID filter = 123; guint sessions = g_hash_table_size (f->engine->filters);
  GlimsStatus status = api->filter_begin_displace_with_sources (f->engine, image, target, x, y, &filter, &error);
  CHECK (status == expected && filter == 0, label);
  after = fingerprint (f);
  CHECK (before && after && !strcmp (before, after) && sessions == g_hash_table_size (f->engine->filters), "refusal preserves stored pixels/image/history and creates no session");
  if (status == GLIMS_STATUS_OK && filter) api->filter_abort (f->engine, filter);
  g_free (before); g_free (after); clear_error (&error);
}

static GlimsStatus
refusal_cases (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}, other = {0}; char *error = NULL; GlimsFilterID filter = 0;
  GlimsStrokeID stroke = 0;
  GlimsImageID indexed_id = 0; gboolean blocked = FALSE; gint block_mode = 0;
  NEED (fixture_open (engine, &f, TRUE) && fixture_open (engine, &other, FALSE), "refusal fixtures open");
  GlimsItemID target = item_id (f.target), source = item_id (f.source);
  refuse_pair (&f, f.id, 0, source, source, GLIMS_STATUS_INVALID_ARGUMENT, "implicit target refuses");
  refuse_pair (&f, f.id, target, 0, source, GLIMS_STATUS_INVALID_ARGUMENT, "missing X map refuses");
  refuse_pair (&f, f.id, target, source, 0, GLIMS_STATUS_INVALID_ARGUMENT, "missing Y map refuses");
  refuse_pair (&f, INT_MAX, target, source, source, GLIMS_STATUS_NOT_FOUND, "stale image refuses");
  refuse_pair (&f, f.id, INT_MAX, source, source, GLIMS_STATUS_NOT_FOUND, "stale target refuses");
  refuse_pair (&f, f.id, target, INT_MAX, source, GLIMS_STATUS_NOT_FOUND, "stale first map refuses");
  refuse_pair (&f, f.id, target, source, INT_MAX, GLIMS_STATUS_NOT_FOUND, "valid first map and stale second map refuse atomically");
  refuse_pair (&f, f.id, target, source, item_id (other.source), GLIMS_STATUS_NOT_FOUND, "foreign second map refuses atomically");
  GimpLayer *group = gimp_group_layer_new (f.image);
  NEED (group && gimp_image_add_layer (f.image, group, NULL, 0, FALSE), "group target fixture attaches");
  refuse_pair (&f, f.id, item_id (group), source, source, GLIMS_STATUS_UNSUPPORTED, "group target refuses");
  GimpText *text = g_object_new (GIMP_TYPE_TEXT, "text", "T", "font", gimp_context_get_font (gimp_get_user_context (engine->gimp)), "font-size", 8.0, NULL);
  GimpLayer *editable = gimp_text_layer_new (f.image, text); g_object_unref (text);
  NEED (editable && gimp_image_add_layer (f.image, editable, NULL, 0, FALSE), "real editable text target attaches");
  refuse_pair (&f, f.id, item_id (editable), source, source, GLIMS_STATUS_UNSUPPORTED, "editable target refuses without implicit rasterization");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), TRUE, FALSE);
  refuse_pair (&f, f.id, target, source, source, GLIMS_STATUS_LOCKED, "locked target refuses");
  gimp_item_set_lock_content (GIMP_ITEM (f.target), FALSE, FALSE);
  engine->busy++; refuse_pair (&f, f.id, target, source, source, GLIMS_STATUS_BUSY, "engine exclusive work refuses"); engine->busy--;
  GlimsBrushSettings brush = {.struct_size = sizeof brush, .tool = GLIMS_PAINT_PAINTBRUSH, .size = 4, .opacity = 1, .hardness = -1, .rate = -1, .flow = -1, .exposure = -1};
  GlimsStrokePoint point = {2,2,1,0,0,0};
  NEED (api->stroke_begin (engine, f.id, target, &brush, &point, &stroke, &error) == GLIMS_STATUS_OK, "real stroke starts before refusal");
  refuse_pair (&f, f.id, target, source, source, GLIMS_STATUS_BUSY, "active stroke refuses");
  NEED (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "refusal fixture stroke ends"); stroke = 0;
  NEED (api->filter_begin (engine, f.id, target, "gegl:gaussian-blur", &filter, &error) == GLIMS_STATUS_OK, "ordinary filter preview starts before refusal");
  refuse_pair (&f, f.id, target, source, source, GLIMS_STATUS_BUSY, "existing preview refuses");
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "ordinary preview aborts"); filter = 0;
  for (block_mode = 0; block_mode < 3; block_mode++) {
    if (block_mode == 0) { gimp_image_undo_disable (f.image); blocked = TRUE; }
    else if (block_mode == 1) { gimp_image_undo_freeze (f.image); blocked = TRUE; }
    else { blocked = gimp_image_undo_group_start (f.image, GIMP_UNDO_GROUP_IMAGE_ITEM_REMOVE, "Displace history fixture"); NEED (blocked, "native outer Undo group opens"); }
    refuse_pair (&f, f.id, target, source, source, GLIMS_STATUS_BUSY, "disabled/frozen/grouped Undo refuses Begin");
    if (block_mode == 0) gimp_image_undo_enable (f.image);
    else if (block_mode == 1) gimp_image_undo_thaw (f.image);
    else gimp_image_undo_group_end (f.image);
    blocked = FALSE;
  }
  NEED (begin_maps (&f, source, source, &filter, &error) == GLIMS_STATUS_OK, "preview begins before Commit history refusal");
  gimp_image_undo_freeze (f.image); blocked = TRUE; block_mode = 1;
  gchar *before = fingerprint (&f), *after = NULL;
  CHECK (api->filter_commit (engine, filter, &error) == GLIMS_STATUS_BUSY, "frozen Undo refuses Commit");
  after = fingerprint (&f);
  CHECK (before && after && !strcmp (before, after), "refused Commit preserves raw pixels and history"); g_free (before); g_free (after); clear_error (&error);
  NEED (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "refused Commit remains cancelable"); filter = 0;
  gimp_image_undo_thaw (f.image); blocked = FALSE;
  GlimsSelectOptions options = {.struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE};
  GlimsPoint corners[] = {{0,0},{8,8}}; GlimsItemID floating = 0;
  NEED (api->select_shape (engine, f.id, GLIMS_SHAPE_RECTANGLE, corners, 2, &options) == GLIMS_STATUS_OK && api->selection_float (engine, f.id, target, GLIMS_FLOAT_COPY, &floating, &error) == GLIMS_STATUS_OK, "real floating selection attaches");
  refuse_pair (&f, f.id, target, source, source, GLIMS_STATUS_BUSY, "floating selection refuses");
  GimpImage *indexed = gimp_create_image (engine->gimp, SIDE, SIDE, GIMP_INDEXED, GIMP_PRECISION_U8_NON_LINEAR, FALSE);
  NEED (indexed && glims_adopt_image (engine, indexed, &indexed_id) == GLIMS_STATUS_OK, "indexed image fixture is adopted");
  refuse_pair (&f, indexed_id, target, source, source, GLIMS_STATUS_UNSUPPORTED, "indexed image refuses before map snapshot");
cleanup:
  if (blocked) { if (block_mode == 0) gimp_image_undo_enable (f.image); else if (block_mode == 1) gimp_image_undo_thaw (f.image); else gimp_image_undo_group_end (f.image); }
  if (filter) api->filter_abort (engine, filter);
  if (stroke) api->stroke_end (engine, stroke);
  if (indexed_id) api->image_close (engine, indexed_id);
  clear_error (&error); fixture_close (&other); fixture_close (&f);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
budget_and_close (GlimsEngine *engine, gpointer unused)
{
  (void) unused;
  Fixture f = {0}; GimpLayer *maps[2] = {NULL,NULL}; GeglTileHandler *guards[2] = {NULL,NULL};
  GeglBuffer *buffers[2] = {NULL,NULL}; gboolean attached[2] = {FALSE,FALSE}, guarded[2] = {FALSE,FALSE};
  GlimsFilterID filter = 0; char *error = NULL;
  NEED (fixture_open (engine, &f, FALSE), "aggregate budget fixture opens tiny target");
  for (guint i = 0; i < 2; i++) {
    maps[i] = gimp_layer_new (f.image, 16384, 4097, gimp_image_get_layer_format (f.image, TRUE), "Sparse under-budget map", 1, GIMP_LAYER_MODE_NORMAL);
    NEED (maps[i] != NULL, "sparse map constructs without filling pixels");
    buffers[i] = gimp_drawable_get_buffer (GIMP_DRAWABLE (maps[i]));
    guards[i] = g_object_new (GEGL_TYPE_TILE_HANDLER, NULL); GEGL_TILE_SOURCE (guards[i])->command = forbid_sparse_pixels;
    gegl_buffer_add_handler (buffers[i], guards[i]); guarded[i] = TRUE;
    gimp_item_set_visible (GIMP_ITEM (maps[i]), FALSE, FALSE);
    attached[i] = gimp_image_add_layer (f.image, maps[i], NULL, 0, FALSE);
    NEED (attached[i], "hidden sparse map attaches without pixel access");
  }
  uint64_t bytes[2];
  for (guint i = 0; i < 2; i++) {
    const GeglRectangle *r = gegl_buffer_get_extent (buffers[i]);
    bytes[i] = (uint64_t) r->width * r->height * babl_format_get_bytes_per_pixel (gegl_buffer_get_format (buffers[i]));
  }
  CHECK (bytes[0] <= GLIMS_MAX_PIXEL_BUFFER_BYTES && bytes[1] <= GLIMS_MAX_PIXEL_BUFFER_BYTES && bytes[0] + bytes[1] > GLIMS_MAX_PIXEL_BUFFER_BYTES, "each real native map fits the single-source limit while the pair exceeds it");
  refuse_pair (&f, f.id, item_id (f.target), item_id (maps[0]), item_id (maps[1]), GLIMS_STATUS_FAILED, "aggregate budget refuses before any guarded sparse pixel materialization");
cleanup:
  for (guint i = 0; i < 2; i++) {
    if (guarded[i]) gegl_buffer_remove_handler (buffers[i], guards[i]);
    g_clear_object (&guards[i]); if (maps[i] && !attached[i]) g_object_unref (maps[i]);
  }
  clear_error (&error); fixture_close (&f);
  /* A separate small fixture verifies image-close teardown, not budget data. */
  if (!fixture_open (engine, &f, FALSE)) { CHECK (FALSE, "close fixture opens"); return GLIMS_STATUS_OK; }
  CHECK (begin_maps (&f, item_id (f.source), item_id (f.source), &filter, &error) == GLIMS_STATUS_OK && filter > 0, "dual-source preview begins before close");
  GlimsFilterID old = filter;
  CHECK (api->image_close (engine, f.id) == GLIMS_STATUS_OK, "image closes with accepted preview"); f.id = 0;
  CHECK (g_hash_table_size (engine->filters) == 0 && api->filter_abort (engine, old) == GLIMS_STATUS_NOT_FOUND, "close removes the dual-source session and repeated Abort reports finished");
  clear_error (&error);
  return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  if (argc != 2) return 2;
  work_dir = argv[1];
  gchar *user = g_build_filename (work_dir, "user", NULL), *cache = g_build_filename (work_dir, "cache", NULL);
  GlimsEngineConfig config = {.struct_size = sizeof config, .user_directory = user, .cache_directory = cache};
  GlimsEngine *engine = NULL; char *error = NULL;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  /* Old168's complete prefix ends exactly where new169 starts. */
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, filter_begin_displace_with_sources)) return 2;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) {
    fprintf (stderr, "%s\n", error ? error : "startup failed"); clear_error (&error); g_free (user); g_free (cache); return 2;
  }
  CHECK (glims_engine_call (engine, setup_oracle, NULL) == GLIMS_STATUS_OK, "literal direct-graph controls execute on the engine thread");
  CHECK (glims_engine_call (engine, admission, NULL) == GLIMS_STATUS_OK, "baseline admission probe executes on the engine thread");
  if (displace_admitted) {
    for (gint mode = 0; mode < 5; mode++) CHECK (glims_engine_call (engine, pixel_case, GINT_TO_POINTER (mode)) == GLIMS_STATUS_OK, "independent native pixel and history case executes");
    for (gint role = 0; role < 2; role++) CHECK (glims_engine_call (engine, lifetime_case, GINT_TO_POINTER (role)) == GLIMS_STATUS_OK, "each captured-map lifetime case executes");
    CHECK (glims_engine_call (engine, refusal_cases, NULL) == GLIMS_STATUS_OK, "ordinary refusal and retained-preview suite executes");
    CHECK (glims_engine_call (engine, budget_and_close, NULL) == GLIMS_STATUS_OK, "aggregate-budget and close suite executes");
  } else printf ("OBS slot169-dependent suites NOT RUN after the explicit baseline RED\n");
  api->stop (engine);
  if (has_displace_sources (api)) {
    GlimsFilterID stopped = 123;
    CHECK (api->filter_begin_displace_with_sources (NULL, 1, 1, 1, 1, &stopped, NULL) == GLIMS_STATUS_NOT_RUNNING && stopped == 0, "public stopped-engine dispatch clears output without touching native inputs");
  }
  g_free (user); g_free (cache);
  printf ("%s: %d Displace checks, %d failures\n", failures ? "FAILED" : "PASSED", displace_checks, failures);
  return failures != 0;
}
